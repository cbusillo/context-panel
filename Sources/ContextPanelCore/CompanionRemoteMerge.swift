import Foundation

public extension CompanionSyncDocument {
    func mergingForRemotePublish(existing: CompanionSyncDocument?) -> CompanionSyncDocument {
        guard let existing else { return self }

        let merger = CompanionRemoteSnapshotMerger(existing: existing.snapshot, incoming: snapshot)
        let mergedSnapshot = merger.mergedSnapshot()
        let mergedPromptCacheSummaries = CompanionRemotePromptCacheMerger(
            existing: existing.snapshot.promptCacheSummaries,
            incoming: snapshot.promptCacheSummaries
        ).mergedSummaries()
        let settingsDocument = merger.prefersIncomingSnapshot ? self : existing

        return CompanionSyncDocument(
            snapshot: CompanionSnapshot(
                generatedAt: max(existing.snapshot.generatedAt, snapshot.generatedAt),
                publishedAt: max(existing.snapshot.publishedAt, snapshot.publishedAt),
                limits: mergedSnapshot.limits,
                providerStatuses: mergedSnapshot.providerStatuses,
                promptCacheSummaries: mergedPromptCacheSummaries
            ),
            widgetDisplayPreferences: settingsDocument.widgetDisplayPreferences,
            observedBurnRates: merger.mergedObservedBurnRates(
                existing: existing.observedBurnRates,
                incoming: observedBurnRates,
                mergedSnapshot: mergedSnapshot
            ),
            fastModeForecastSettings: settingsDocument.fastModeForecastSettings
        )
    }
}

private struct CompanionRemoteSnapshotMerger {
    let existing: CompanionSnapshot
    let incoming: CompanionSnapshot

    func mergedSnapshot() -> CompanionSnapshot {
        let existingAccounts = accountData(in: existing)
        let incomingAccounts = accountData(in: incoming)
        let existingProvidersWithLimits = Set(existing.limits.map(\.provider))
        let incomingProvidersWithLimits = Set(incoming.limits.map(\.provider))
        let keys = orderedKeys(in: existing) + orderedKeys(in: incoming).filter { !existingAccounts.keys.contains($0) }

        var limits: [CompanionLimit] = []
        var providerStatuses: [CompanionProviderStatus] = []
        for key in keys {
            guard let selected = selectedAccount(
                existing: existingAccounts[key],
                incoming: incomingAccounts[key],
                existingProviderHasLimits: existingProvidersWithLimits.contains(key.provider),
                incomingProviderHasLimits: incomingProvidersWithLimits.contains(key.provider)
            ) else { continue }
            limits.append(contentsOf: selected.limits)
            if let status = selected.status {
                providerStatuses.append(status)
            }
        }

        return CompanionSnapshot(
            generatedAt: max(existing.generatedAt, incoming.generatedAt),
            publishedAt: max(existing.publishedAt, incoming.publishedAt),
            limits: limits,
            providerStatuses: providerStatuses,
            promptCacheSummaries: []
        )
    }

    func mergedObservedBurnRates(
        existing existingRates: [String: ObservedBurnRate],
        incoming incomingRates: [String: ObservedBurnRate],
        mergedSnapshot: CompanionSnapshot
    ) -> [String: ObservedBurnRate] {
        let rateIDs = Set(existingRates.keys).union(incomingRates.keys)
        var rates: [String: ObservedBurnRate] = [:]
        for rateID in rateIDs {
            let mergedPool = burnRatePool(forRateID: rateID, in: mergedSnapshot)
            guard !mergedPool.isEmpty else { continue }

            let matchesExisting = mergedPool == burnRatePool(forRateID: rateID, in: existing)
            let matchesIncoming = mergedPool == burnRatePool(forRateID: rateID, in: incoming)
            switch (matchesExisting, matchesIncoming) {
            case (true, true):
                if prefersIncomingSnapshot {
                    rates[rateID] = incomingRates[rateID] ?? existingRates[rateID]
                } else {
                    rates[rateID] = existingRates[rateID] ?? incomingRates[rateID]
                }
            case (true, false):
                rates[rateID] = existingRates[rateID]
            case (false, true):
                rates[rateID] = incomingRates[rateID]
            case (false, false):
                break
            }
        }
        return rates
    }

    var prefersIncomingSnapshot: Bool {
        if existing.generatedAt != incoming.generatedAt {
            return existing.generatedAt < incoming.generatedAt
        }
        return existing.publishedAt <= incoming.publishedAt
    }

    private func burnRatePool(forRateID rateID: String, in snapshot: CompanionSnapshot) -> Set<String> {
        let usageSnapshot = UsageSnapshot(
            generatedAt: snapshot.generatedAt,
            limits: snapshot.limits.map(\.usageLimit)
        )
        guard let summary = usageSnapshot.mainLimitSummaries.first(where: { $0.id == rateID }) else {
            return []
        }
        return Set(summary.liveLimits.map(\.id))
    }

    private func accountData(in snapshot: CompanionSnapshot) -> [CompanionRemoteAccountKey: CompanionRemoteAccountData] {
        var data: [CompanionRemoteAccountKey: CompanionRemoteAccountData] = [:]
        for limit in snapshot.limits {
            let key = CompanionRemoteAccountKey(limit: limit)
            data[key, default: CompanionRemoteAccountData(fallbackGeneratedAt: snapshot.generatedAt)].limits.append(limit)
        }
        for status in snapshot.providerStatuses {
            let key = CompanionRemoteAccountKey(status: status)
            var account = data[key, default: CompanionRemoteAccountData(fallbackGeneratedAt: snapshot.generatedAt)]
            if account.status == nil || account.status!.generatedAt <= status.generatedAt {
                account.status = status
            }
            data[key] = account
        }
        return data
    }

    private func orderedKeys(in snapshot: CompanionSnapshot) -> [CompanionRemoteAccountKey] {
        var keys: [CompanionRemoteAccountKey] = []
        var seen: Set<CompanionRemoteAccountKey> = []
        for key in snapshot.limits.map(CompanionRemoteAccountKey.init(limit:))
            + snapshot.providerStatuses.map(CompanionRemoteAccountKey.init(status:)) {
            if seen.insert(key).inserted {
                keys.append(key)
            }
        }
        return keys
    }

    private func selectedAccount(
        existing: CompanionRemoteAccountData?,
        incoming: CompanionRemoteAccountData?,
        existingProviderHasLimits: Bool,
        incomingProviderHasLimits: Bool
    ) -> CompanionRemoteAccountData? {
        guard let incoming else {
            if existing?.isDegraded == true, incomingProviderHasLimits {
                return nil
            }
            return existing
        }
        guard let existing else {
            if incoming.isDegraded, existingProviderHasLimits {
                return nil
            }
            return incoming
        }

        if existing.isDegraded != incoming.isDegraded {
            return incoming.isDegraded ? existing : incoming
        }
        if incoming.isDegraded, existing.hasLimits != incoming.hasLimits {
            return incoming.hasLimits ? incoming : existing
        }
        return newer(existing, incoming)
    }

    private func newer(
        _ existing: CompanionRemoteAccountData,
        _ incoming: CompanionRemoteAccountData
    ) -> CompanionRemoteAccountData {
        if existing.observedAt != incoming.observedAt {
            return existing.observedAt < incoming.observedAt ? incoming : existing
        }
        return incoming
    }
}

private struct CompanionRemoteAccountData {
    var limits: [CompanionLimit] = []
    var status: CompanionProviderStatus?
    let fallbackGeneratedAt: Date

    var hasLimits: Bool {
        !limits.isEmpty
    }

    var isDegraded: Bool {
        guard let status else { return false }
        return switch status.status {
        case .failure, .loading, .stale, .unknown:
            true
        case .close, .healthy, .limited:
            false
        }
    }

    var observedAt: Date {
        let limitDate = limits.compactMap(\.lastUpdatedAt).max()
        return [status?.generatedAt, limitDate].compactMap { $0 }.max() ?? fallbackGeneratedAt
    }
}

private struct CompanionRemoteAccountKey: Hashable {
    let provider: Provider
    let companionAccountID: String

    init(limit: CompanionLimit) {
        provider = limit.provider
        companionAccountID = limit.companionAccountID
    }

    init(status: CompanionProviderStatus) {
        provider = status.provider
        companionAccountID = status.companionAccountID
    }

    init(summary: CompanionPromptCacheSummary) {
        provider = summary.provider
        companionAccountID = summary.companionAccountID
    }
}

private struct CompanionRemotePromptCacheMerger {
    let existing: [CompanionPromptCacheSummary]
    let incoming: [CompanionPromptCacheSummary]

    func mergedSummaries() -> [CompanionPromptCacheSummary] {
        var summariesByAccount: [CompanionRemoteAccountKey: CompanionPromptCacheSummary] = [:]
        var orderedKeys: [CompanionRemoteAccountKey] = []
        var seen: Set<CompanionRemoteAccountKey> = []

        for summary in existing {
            let key = CompanionRemoteAccountKey(summary: summary)
            if let current = summariesByAccount[key], current.latestObservedAt > summary.latestObservedAt {
                continue
            }
            summariesByAccount[key] = summary
            if seen.insert(key).inserted {
                orderedKeys.append(key)
            }
        }

        for summary in incoming {
            let key = CompanionRemoteAccountKey(summary: summary)
            if let current = summariesByAccount[key], current.latestObservedAt > summary.latestObservedAt {
                continue
            }
            summariesByAccount[key] = summary
            if seen.insert(key).inserted {
                orderedKeys.append(key)
            }
        }

        return orderedKeys.compactMap { summariesByAccount[$0] }
    }
}
