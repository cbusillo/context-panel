import ContextPanelCore

public struct CompanionSyncPresentation: Equatable, Sendable {
    public let title: String
    public let detail: String
    public let symbol: String
    public let usageSummary: String?

    public init(result: CompanionSyncLoadResult) {
        if let error = result.errorMessage {
            usageSummary = nil
            title = "Sync failed"
            detail = error
            symbol = "icloud.slash"
            return
        }

        switch result.status {
        case .healthy, .close, .limited:
            usageSummary = Self.usageSummary(for: result.document)
            title = "Synced from Mac"
            detail = "Latest Mac snapshot received through iCloud."
            symbol = "checkmark.icloud"
        case .stale:
            usageSummary = Self.usageSummary(for: result.document)
            title = "Mac sync is stale"
            detail = "Open Context Panel on your Mac to publish a fresh snapshot."
            symbol = "clock.badge.exclamationmark"
        case .failure:
            if result.document != nil {
                usageSummary = Self.usageSummary(for: result.document)
                title = "Synced from Mac"
                detail = "Latest Mac snapshot received through iCloud."
                symbol = "checkmark.icloud"
            } else {
                usageSummary = nil
                title = "Sync failed"
                detail = "The companion could not read the synced snapshot."
                symbol = "icloud.slash"
            }
        case .loading:
            usageSummary = nil
            title = "Loading Mac sync"
            detail = "Checking iCloud for the latest Mac snapshot."
            symbol = "arrow.clockwise.icloud"
        case .unknown:
            usageSummary = nil
            title = "Waiting for Mac sync"
            detail = "Open Context Panel on your Mac to publish usage lanes through iCloud."
            symbol = "icloud.and.arrow.down"
        }
    }

    private static func usageSummary(for document: CompanionSyncDocument?) -> String? {
        guard let document else { return nil }
        let snapshot = document.snapshot

        let limitedCount = snapshot.limits.filter { $0.status == .limited }.count
        if limitedCount == 1 { return "1 usage lane needs attention." }
        if limitedCount > 1 { return "\(limitedCount) usage lanes need attention." }

        let closeCount = snapshot.limits.filter { $0.status == .close }.count
        if closeCount == 1 { return "1 usage lane is close to its limit." }
        if closeCount > 1 { return "\(closeCount) usage lanes are close to their limits." }

        let failedCount = snapshot.providerStatuses.filter { $0.status == .failure }.count
        if failedCount == 1 { return "1 provider needs attention on your Mac." }
        if failedCount > 1 { return "\(failedCount) providers need attention on your Mac." }

        return nil
    }
}
