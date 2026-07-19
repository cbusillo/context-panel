import Foundation

public extension CompanionSyncDocument {
    func mergingForRemotePublish(existing: CompanionSyncDocument?) -> CompanionSyncDocument {
        let incomingDocument = normalizedForRemotePublish()
        guard let existing else { return incomingDocument }
        let existingDocument = existing.normalizedForRemotePublish()

        let merger = CompanionRemoteSnapshotMerger(
            existing: existingDocument.snapshot,
            incoming: incomingDocument.snapshot,
            existingDegradedAccountKeys: existing.snapshot.degradedAccountKeysForRemotePublish,
            incomingDegradedAccountKeys: snapshot.degradedAccountKeysForRemotePublish
        )
        let mergedSnapshot = merger.mergedSnapshot()
        let mergedPromptCacheSummaries = CompanionRemotePromptCacheMerger(
            existing: existingDocument.snapshot.promptCacheSummaries,
            incoming: incomingDocument.snapshot.promptCacheSummaries
        ).mergedSummaries()
        let settingsDocument = preferredSettingsDocument(
            existing: existingDocument,
            incoming: incomingDocument
        )

        return CompanionSyncDocument(
            snapshot: CompanionSnapshot(
                generatedAt: max(existingDocument.snapshot.generatedAt, incomingDocument.snapshot.generatedAt),
                publishedAt: max(existingDocument.snapshot.publishedAt, incomingDocument.snapshot.publishedAt),
                limits: mergedSnapshot.limits,
                providerStatuses: mergedSnapshot.providerStatuses,
                promptCacheSummaries: mergedPromptCacheSummaries
            ),
            widgetDisplayPreferences: settingsDocument.widgetDisplayPreferences,
            observedBurnRates: merger.mergedObservedBurnRates(
                existing: existingDocument.observedBurnRates,
                incoming: incomingDocument.observedBurnRates,
                mergedSnapshot: mergedSnapshot
            ),
            fastModeForecastSettings: settingsDocument.fastModeForecastSettings
        )
    }

    private func preferredSettingsDocument(
        existing: CompanionSyncDocument,
        incoming: CompanionSyncDocument
    ) -> CompanionSyncDocument {
        if existing.snapshot.generatedAt != incoming.snapshot.generatedAt {
            return existing.snapshot.generatedAt < incoming.snapshot.generatedAt ? incoming : existing
        }
        if existing.snapshot.publishedAt != incoming.snapshot.publishedAt {
            return existing.snapshot.publishedAt < incoming.snapshot.publishedAt ? incoming : existing
        }
        let existingData = existing.deterministicSettingsSelectionData
        let incomingData = incoming.deterministicSettingsSelectionData
        if existingData == incomingData { return existing }
        return existingData.lexicographicallyPrecedes(incomingData) ? incoming : existing
    }
}

private extension CompanionSyncDocument {
    func normalizedForRemotePublish() -> CompanionSyncDocument {
        let normalizedSnapshot = snapshot.normalizedForRemotePublish
        guard normalizedSnapshot != snapshot else { return self }
        return CompanionSyncDocument(
            snapshot: normalizedSnapshot,
            widgetDisplayPreferences: widgetDisplayPreferences,
            observedBurnRates: observedBurnRates,
            fastModeForecastSettings: fastModeForecastSettings
        )
    }

    var deterministicSettingsSelectionData: Data {
        let payload = CompanionRemoteSettingsSelection(
            widgetDisplayPreferences: widgetDisplayPreferences,
            fastModeForecastSettings: fastModeForecastSettings
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(payload)) ?? Data()
    }
}

private struct CompanionRemoteSettingsSelection: Encodable {
    let widgetDisplayPreferences: WidgetDisplayPreferences
    let fastModeForecastSettings: FastModeForecastSettings
}

private extension CompanionSnapshot {
    var degradedAccountKeysForRemotePublish: Set<CompanionRemoteAccountKey> {
        Set(providerStatuses.compactMap { status in
            status.status.isCompanionObservationStatus ? nil : CompanionRemoteAccountKey(status: status)
        })
    }

    var normalizedForRemotePublish: CompanionSnapshot {
        let accountKeysWithLimits = Set(limits.map(CompanionRemoteAccountKey.init(limit:)))
        let providersWithLimits = Set(limits.map(\.provider))
        let normalizedStatuses = providerStatuses.filter { status in
            if accountKeysWithLimits.contains(CompanionRemoteAccountKey(status: status)) {
                return status.status.isCompanionObservationStatus
            }
            return !providersWithLimits.contains(status.provider)
        }
        guard normalizedStatuses != providerStatuses else { return self }
        return CompanionSnapshot(
            generatedAt: generatedAt,
            publishedAt: publishedAt,
            limits: limits,
            providerStatuses: normalizedStatuses,
            promptCacheSummaries: promptCacheSummaries
        )
    }
}

private struct CompanionRemoteSnapshotMerger {
    let existing: CompanionSnapshot
    let incoming: CompanionSnapshot
    let existingDegradedAccountKeys: Set<CompanionRemoteAccountKey>
    let incomingDegradedAccountKeys: Set<CompanionRemoteAccountKey>

    func mergedSnapshot() -> CompanionSnapshot {
        let existingAccounts = accountData(in: existing)
        let incomingAccounts = accountData(in: incoming)
        let existingProvidersWithLimits = Set(existing.limits.map(\.provider))
        let incomingProvidersWithLimits = Set(incoming.limits.map(\.provider))
        let keys = orderedAccountKeys(
            existingAccounts: existingAccounts,
            incomingAccounts: incomingAccounts
        )
        var selectedAccounts: [(CompanionRemoteAccountKey, CompanionRemoteAccountData)] = []
        for key in keys {
            guard let selected = selectedAccount(
                key: key,
                existing: existingAccounts[key],
                incoming: incomingAccounts[key],
                existingProviderHasLimits: existingProvidersWithLimits.contains(key.provider),
                incomingProviderHasLimits: incomingProvidersWithLimits.contains(key.provider)
            ) else { continue }
            selectedAccounts.append((key, selected))
        }

        var limits: [CompanionLimit] = []
        var providerStatuses: [CompanionProviderStatus] = []
        for (_, selected) in selectedAccounts {
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

            var candidates: [(rate: ObservedBurnRate, contributionCount: Int)] = []
            if let rate = existingRates[rateID],
               mergedPool == burnRatePool(forRateID: rateID, in: existing),
               burnRateAccountKeys(forRateID: rateID, in: existing)
               .isDisjoint(with: existingDegradedAccountKeys) {
                candidates.append((
                    rate,
                    selectedAccountContributionCount(
                        forRateID: rateID,
                        source: existing,
                        merged: mergedSnapshot
                    )
                ))
            }
            if let rate = incomingRates[rateID],
               mergedPool == burnRatePool(forRateID: rateID, in: incoming),
               burnRateAccountKeys(forRateID: rateID, in: incoming)
               .isDisjoint(with: incomingDegradedAccountKeys) {
                candidates.append((
                    rate,
                    selectedAccountContributionCount(
                        forRateID: rateID,
                        source: incoming,
                        merged: mergedSnapshot
                    )
                ))
            }
            guard let highestContribution = candidates.map(\.contributionCount).max() else { continue }
            let strongestCandidates = candidates
                .filter { $0.contributionCount == highestContribution }
                .map(\.rate)
            if let selectedRate = strongestCandidates.max(by: burnRateIsWeaker) {
                rates[rateID] = selectedRate
            }
        }
        return rates
    }

    private func burnRateIsWeaker(_ lhs: ObservedBurnRate, _ rhs: ObservedBurnRate) -> Bool {
        if lhs.sampleCount != rhs.sampleCount { return lhs.sampleCount < rhs.sampleCount }
        if lhs.observedDurationHours != rhs.observedDurationHours {
            return lhs.observedDurationHours < rhs.observedDurationHours
        }
        return lhs.unitsPerHour < rhs.unitsPerHour
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

    private func burnRateAccountKeys(
        forRateID rateID: String,
        in snapshot: CompanionSnapshot
    ) -> Set<CompanionRemoteAccountKey> {
        let usageSnapshot = UsageSnapshot(
            generatedAt: snapshot.generatedAt,
            limits: snapshot.limits.map(\.usageLimit)
        )
        guard let summary = usageSnapshot.mainLimitSummaries.first(where: { $0.id == rateID }) else {
            return []
        }
        return Set(summary.liveLimits.map(CompanionRemoteAccountKey.init(limit:)))
    }

    private func selectedAccountContributionCount(
        forRateID rateID: String,
        source: CompanionSnapshot,
        merged: CompanionSnapshot
    ) -> Int {
        let sourceAccounts = accountData(in: source)
        let mergedAccounts = accountData(in: merged)
        return burnRateAccountKeys(forRateID: rateID, in: merged).reduce(into: 0) { count, key in
            guard let sourceAccount = sourceAccounts[key], let mergedAccount = mergedAccounts[key] else { return }
            if sourceAccount.semanticSelectionData == mergedAccount.semanticSelectionData {
                count += 1
            }
        }
    }

    private func orderedAccountKeys(
        existingAccounts: [CompanionRemoteAccountKey: CompanionRemoteAccountData],
        incomingAccounts: [CompanionRemoteAccountKey: CompanionRemoteAccountData]
    ) -> [CompanionRemoteAccountKey] {
        let existingKeys = accountKeys(in: existing)
        let incomingKeys = accountKeys(in: incoming)
        let primaryKeys: [CompanionRemoteAccountKey]
        let secondaryKeys: [CompanionRemoteAccountKey]

        if existing.generatedAt == incoming.generatedAt,
           existing.publishedAt == incoming.publishedAt,
           existingKeys != incomingKeys {
            let existingData = accountOrderSelectionData(existingKeys)
            let incomingData = accountOrderSelectionData(incomingKeys)
            if existingData.lexicographicallyPrecedes(incomingData) {
                primaryKeys = incomingKeys
                secondaryKeys = existingKeys
            } else {
                primaryKeys = existingKeys
                secondaryKeys = incomingKeys
            }
        } else {
            primaryKeys = existingKeys
            secondaryKeys = incomingKeys
        }

        let availableKeys = Set(existingAccounts.keys).union(incomingAccounts.keys)
        var seen: Set<CompanionRemoteAccountKey> = []
        return (primaryKeys + secondaryKeys)
            .filter { availableKeys.contains($0) && seen.insert($0).inserted }
    }

    private func accountKeys(in snapshot: CompanionSnapshot) -> [CompanionRemoteAccountKey] {
        var seen: Set<CompanionRemoteAccountKey> = []
        return (
            snapshot.limits.map(CompanionRemoteAccountKey.init(limit:))
                + snapshot.providerStatuses.map(CompanionRemoteAccountKey.init(status:))
        ).filter { seen.insert($0).inserted }
    }

    private func accountOrderSelectionData(_ keys: [CompanionRemoteAccountKey]) -> Data {
        keys.map(\.selectionKey).joined(separator: "\u{1e}").data(using: .utf8) ?? Data()
    }

    private func accountData(in snapshot: CompanionSnapshot) -> [CompanionRemoteAccountKey: CompanionRemoteAccountData] {
        var data: [CompanionRemoteAccountKey: CompanionRemoteAccountData] = [:]
        for limit in snapshot.limits {
            let key = CompanionRemoteAccountKey(limit: limit)
            data[
                key,
                default: CompanionRemoteAccountData(
                    fallbackGeneratedAt: snapshot.generatedAt
                )
            ].limits.append(limit)
        }
        for status in snapshot.providerStatuses {
            let key = CompanionRemoteAccountKey(status: status)
            var account = data[
                key,
                default: CompanionRemoteAccountData(
                    fallbackGeneratedAt: snapshot.generatedAt
                )
            ]
            if account.status == nil || account.status!.generatedAt <= status.generatedAt {
                account.status = status
            }
            data[key] = account
        }
        return data
    }

    private func selectedAccount(
        key: CompanionRemoteAccountKey,
        existing: CompanionRemoteAccountData?,
        incoming: CompanionRemoteAccountData?,
        existingProviderHasLimits: Bool,
        incomingProviderHasLimits: Bool
    ) -> CompanionRemoteAccountData? {
        guard let incoming else {
            if existing?.isStatusOnlyDegraded == true, incomingProviderHasLimits {
                return nil
            }
            return existing
        }
        guard let existing else {
            if incoming.isStatusOnlyDegraded, existingProviderHasLimits {
                return nil
            }
            return incoming
        }

        if existing.hasCompleteObservation != incoming.hasCompleteObservation {
            return incoming.hasCompleteObservation ? incoming : existing
        }
        if existing.hasLimits != incoming.hasLimits {
            return incoming.hasLimits ? incoming : existing
        }
        return newer(
            existing,
            incoming,
            existingWasDegraded: existingDegradedAccountKeys.contains(key),
            incomingWasDegraded: incomingDegradedAccountKeys.contains(key)
        )
    }

    private func newer(
        _ existing: CompanionRemoteAccountData,
        _ incoming: CompanionRemoteAccountData,
        existingWasDegraded: Bool,
        incomingWasDegraded: Bool
    ) -> CompanionRemoteAccountData {
        if existing.observedAt != incoming.observedAt {
            return existing.observedAt < incoming.observedAt ? incoming : existing
        }
        if existingWasDegraded != incomingWasDegraded {
            return incomingWasDegraded ? existing : incoming
        }
        let existingKey = existing.deterministicSelectionData
        let incomingKey = incoming.deterministicSelectionData
        if existingKey == incomingKey { return existing }
        return existingKey.lexicographicallyPrecedes(incomingKey) ? incoming : existing
    }
}

private struct CompanionRemoteAccountData {
    var limits: [CompanionLimit] = []
    var status: CompanionProviderStatus?
    let fallbackGeneratedAt: Date

    var hasLimits: Bool {
        !limits.isEmpty
    }

    var accountName: String {
        limits.first?.accountName ?? status?.accountName ?? ""
    }

    var hasCompleteObservation: Bool {
        hasLimits && limits.allSatisfy { $0.status.isCompanionObservationStatus }
    }

    var isStatusOnlyDegraded: Bool {
        !hasLimits && status?.status.isCompanionObservationStatus == false
    }

    var observedAt: Date {
        let limitDate = limits.compactMap(\.lastUpdatedAt).max()
        if let limitDate { return limitDate }
        if hasLimits {
            return status?.generatedAt ?? .distantPast
        }
        return status?.generatedAt ?? fallbackGeneratedAt
    }

    var deterministicSelectionData: Data {
        encodedSelectionData(limits: limits)
    }

    var semanticSelectionData: Data {
        encodedSelectionData(limits: limits.sorted { selectionKey(for: $0) < selectionKey(for: $1) })
    }

    private func encodedSelectionData(limits: [CompanionLimit]) -> Data {
        let payload = CompanionRemoteAccountSelection(limits: limits, status: status)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return (try? encoder.encode(payload)) ?? Data()
    }

    private func selectionKey(for limit: CompanionLimit) -> String {
        [
            limit.provider.rawValue,
            limit.companionAccountID,
            limit.accountName,
            limit.label,
            limit.windowLabel ?? "",
            limit.modelLabel ?? "",
            limit.unit.rawValue,
            limit.used.map(String.init) ?? "",
            limit.limit.map(String.init) ?? "",
            limit.resetsAt.map { String($0.timeIntervalSince1970) } ?? "",
            limit.lastUpdatedAt.map { String($0.timeIntervalSince1970) } ?? "",
            limit.confidence.rawValue,
            limit.freshnessMode?.rawValue ?? "",
            limit.status.rawValue,
        ].joined(separator: "\u{1f}")
    }
}

private struct CompanionRemoteAccountSelection: Encodable {
    let limits: [CompanionLimit]
    let status: CompanionProviderStatus?
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

    init(limit: UsageLimit) {
        provider = limit.provider
        companionAccountID = limit.accountID
    }

    init(summary: CompanionPromptCacheSummary) {
        provider = summary.provider
        companionAccountID = summary.companionAccountID
    }

    var selectionKey: String {
        "\(provider.rawValue)\u{1f}\(companionAccountID)"
    }
}

private struct CompanionRemotePromptCacheMerger {
    let existing: [CompanionPromptCacheSummary]
    let incoming: [CompanionPromptCacheSummary]

    func mergedSummaries() -> [CompanionPromptCacheSummary] {
        var summariesByAccount: [CompanionRemoteAccountKey: CompanionPromptCacheSummary] = [:]

        for summary in existing {
            let key = CompanionRemoteAccountKey(summary: summary)
            if let current = summariesByAccount[key] {
                summariesByAccount[key] = newer(current, summary)
            } else {
                summariesByAccount[key] = summary
            }
        }

        for summary in incoming {
            let key = CompanionRemoteAccountKey(summary: summary)
            if let current = summariesByAccount[key] {
                summariesByAccount[key] = newer(current, summary)
            } else {
                summariesByAccount[key] = summary
            }
        }

        return summariesByAccount.values.sorted { lhs, rhs in
            if lhs.provider != rhs.provider { return lhs.provider.rawValue < rhs.provider.rawValue }
            if lhs.accountName != rhs.accountName { return lhs.accountName < rhs.accountName }
            return lhs.companionAccountID < rhs.companionAccountID
        }
    }

    private func newer(
        _ existing: CompanionPromptCacheSummary,
        _ incoming: CompanionPromptCacheSummary
    ) -> CompanionPromptCacheSummary {
        if existing.latestObservedAt != incoming.latestObservedAt {
            return existing.latestObservedAt < incoming.latestObservedAt ? incoming : existing
        }
        let existingData = deterministicSelectionData(existing)
        let incomingData = deterministicSelectionData(incoming)
        if existingData == incomingData { return existing }
        return existingData.lexicographicallyPrecedes(incomingData) ? incoming : existing
    }

    private func deterministicSelectionData(_ summary: CompanionPromptCacheSummary) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return (try? encoder.encode(summary)) ?? Data()
    }
}
