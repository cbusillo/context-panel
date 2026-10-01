import Foundation

public extension CompanionSyncDocument {
    /// Explicit tombstones outlive usage retention so an offline publisher cannot revive a removed lane.
    /// Only opaque display/configuration keys travel; provider login material remains local.
    func applyingGlobalRemovals() -> CompanionSyncDocument {
        let removed = Set(removedDisplayIDs ?? [])
        guard !removed.isEmpty else { return self }
        let removedRows = Set((accountDisplayMetadata ?? []).filter {
            removed.contains($0.id) || removed.contains($0.configurationID)
        }.map(\.id)).union(removed)
        func isRemoved(_ provider: Provider, _ id: String) -> Bool {
            removedRows.contains(AccountDisplayMetadata.safeID(provider, id))
        }
        let filtered = CompanionSnapshot(generatedAt: snapshot.generatedAt, publishedAt: snapshot.publishedAt,
            limits: snapshot.limits.filter { !isRemoved($0.provider, $0.companionAccountID) },
            providerStatuses: snapshot.providerStatuses.filter { !isRemoved($0.provider, $0.companionAccountID) },
            promptCacheSummaries: snapshot.promptCacheSummaries.filter { !isRemoved($0.provider, $0.companionAccountID) })
        let oldPools = UsageSnapshot(generatedAt: snapshot.generatedAt, limits: snapshot.limits.map(\.usageLimit)).mainLimitSummaries
        let newPools = UsageSnapshot(generatedAt: filtered.generatedAt, limits: filtered.limits.map(\.usageLimit)).mainLimitSummaries
        let unchangedPools = Set(newPools.filter { pool in
            oldPools.first { $0.id == pool.id }.map {
                Set($0.liveLimits.map(\.id)) == Set(pool.liveLimits.map(\.id))
            } == true
        }.map(\.id))
        return CompanionSyncDocument(snapshot: filtered, widgetDisplayPreferences: widgetDisplayPreferences,
            observedBurnRates: observedBurnRates.filter { unchangedPools.contains($0.key) },
            fastModeForecastSettings: fastModeForecastSettings,
            accountRetentionStates: accountRetentionStates?.filter { !isRemoved($0.provider, $0.companionAccountID) },
            cloudKitUserScope: cloudKitUserScope,
            accountDisplayMetadata: accountDisplayMetadata?.filter {
                !removedRows.contains($0.id) && !removed.contains($0.configurationID)
            }, removedDisplayIDs: removed.sorted())
    }
}
