import ContextPanelCore

public struct CompanionSyncPresentation: Equatable, Sendable {
    public let title: String
    public let detail: String
    public let symbol: String
    public let usageSummary: String?

    public init(result: CompanionSyncLoadResult) {
        if result.errorMessage != nil {
            usageSummary = nil
            title = "Sync unavailable"
            detail = "This device could not load your synced usage."
            symbol = "icloud.slash"
            return
        }

        switch result.status {
        case .healthy, .close, .limited:
            usageSummary = Self.usageSummary(for: result.document)
            title = "Synced from Mac"
            detail = "Latest usage received from your Mac."
            symbol = Self.syncedSymbol(for: result)
        case .stale:
            usageSummary = Self.usageSummary(for: result.document)
            title = "Saved usage is stale"
            detail = "Open Context Panel on your Mac to refresh this device."
            symbol = "clock.badge.exclamationmark"
        case .failure:
            if result.document != nil {
                usageSummary = Self.usageSummary(for: result.document)
                title = "Synced from Mac"
                detail = "Latest usage received from your Mac."
                symbol = Self.syncedSymbol(for: result)
            } else {
                usageSummary = nil
                title = "Sync unavailable"
                detail = "This device could not load your synced usage."
                symbol = "icloud.slash"
            }
        case .loading:
            usageSummary = nil
            title = "Checking for updates"
            detail = "Looking for the latest usage from your Mac."
            symbol = "arrow.clockwise.icloud"
        case .unknown:
            usageSummary = nil
            title = "Waiting for your Mac"
            detail = "Open Context Panel on your Mac to share usage with this device."
            symbol = "icloud.and.arrow.down"
        }
    }

    private static func syncedSymbol(for result: CompanionSyncLoadResult) -> String {
        switch result.transportMetadata?.source {
        case .appGroup:
            "checkmark.circle"
        default:
            "checkmark.icloud"
        }
    }

    private static func usageSummary(for document: CompanionSyncDocument?) -> String? {
        guard let document else { return nil }
        let snapshot = document.snapshot

        let failedCount = snapshot.providerStatuses.filter { $0.status == .failure }.count
        if failedCount == 1 { return "1 provider needs attention on your Mac." }
        if failedCount > 1 { return "\(failedCount) providers need attention on your Mac." }

        return nil
    }
}
