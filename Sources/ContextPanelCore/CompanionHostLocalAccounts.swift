import Foundation

/// An account without a verified provider identity belongs to the Mac that reports it.
/// Only verified accounts outlive that Mac's own listing, as on the Mac itself.
public extension CompanionSyncDocument {
    /// The accounts another publish may carry forward: verified provider identities only.
    /// Retired lanes and old local memberships leave the shared document at the next publish.
    func keepingVerifiedAccounts() -> Self {
        keepingAccounts(keepsUnobservedMetadata: false) { provider, id in
            SharedProviderAccountIdentity.isSharedAccountID(id, provider: provider)
        }
    }

    /// Rows published before shared identity existed carry no identity status. Once the same
    /// provider has verified accounts, such a row is an old membership and is not shown.
    /// Current connectors always record why an account is unverified, so their rows remain.
    func retiringUnprovenMemberships() -> Self {
        let verifiedProviders = Set((snapshot.limits.map { ($0.provider, $0.companionAccountID) }
            + snapshot.providerStatuses.map { ($0.provider, $0.companionAccountID) })
            .filter { SharedProviderAccountIdentity.isSharedAccountID($0.1, provider: $0.0) }.map(\.0))
        let unproven = Set(snapshot.providerStatuses.filter {
            verifiedProviders.contains($0.provider) && $0.accountIdentityStatus == .unverified
                && !SharedProviderAccountIdentity.isSharedAccountID($0.companionAccountID, provider: $0.provider)
        }.map { AccountDisplayMetadata.safeID($0.provider, $0.companionAccountID) })
        guard !unproven.isEmpty else { return self }
        return keepingAccounts(keepsUnobservedMetadata: true) { provider, id in
            !unproven.contains(AccountDisplayMetadata.safeID(provider, id))
        }
    }

    private func keepingAccounts(keepsUnobservedMetadata: Bool, _ keep: (Provider, String) -> Bool) -> Self {
        let filtered = CompanionSnapshot(generatedAt: snapshot.generatedAt, publishedAt: snapshot.publishedAt,
            limits: snapshot.limits.filter { keep($0.provider, $0.companionAccountID) },
            providerStatuses: snapshot.providerStatuses.filter { keep($0.provider, $0.companionAccountID) },
            promptCacheSummaries: snapshot.promptCacheSummaries.filter { keep($0.provider, $0.companionAccountID) })
        let observed = (snapshot.limits.map { ($0.provider, $0.companionAccountID) }
            + snapshot.providerStatuses.map { ($0.provider, $0.companionAccountID) }
            + snapshot.promptCacheSummaries.map { ($0.provider, $0.companionAccountID) })
        let kept = Set(observed.filter { keep($0.0, $0.1) }.map { AccountDisplayMetadata.safeID($0.0, $0.1) })
        let dropped = Set(observed.map { AccountDisplayMetadata.safeID($0.0, $0.1) }).subtracting(kept)
        return CompanionSyncDocument(snapshot: filtered, widgetDisplayPreferences: widgetDisplayPreferences,
            observedBurnRates: observedBurnRates(unchangedIn: filtered),
            fastModeForecastSettings: fastModeForecastSettings,
            accountRetentionStates: accountRetentionStates?.filter { keep($0.provider, $0.companionAccountID) },
            cloudKitUserScope: cloudKitUserScope,
            accountDisplayMetadata: accountDisplayMetadata?.filter {
                kept.contains($0.id) || (keepsUnobservedMetadata && !dropped.contains($0.id))
            },
            removedDisplayIDs: removedDisplayIDs,
            accountBurnRates: accountBurnRates?.filter { id, _ in
                filtered.limits.contains { $0.companionAccountID == id }
            },
            accountIdentityAliases: accountIdentityAliases,
            accountRemovalDates: accountRemovalDates, accountRestorationDates: accountRestorationDates)
    }
}
