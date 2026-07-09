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
            detail = Self.syncedDetail(for: result)
            symbol = Self.syncedSymbol(for: result)
        case .stale:
            usageSummary = Self.usageSummary(for: result.document)
            title = "Mac sync is stale"
            detail = "Open Context Panel on your Mac to publish a fresh snapshot."
            symbol = "clock.badge.exclamationmark"
        case .failure:
            if result.document != nil {
                usageSummary = Self.usageSummary(for: result.document)
                title = "Synced from Mac"
                detail = Self.syncedDetail(for: result)
                symbol = Self.syncedSymbol(for: result)
            } else {
                usageSummary = nil
                title = "Sync failed"
                detail = "The companion could not read the synced snapshot."
                symbol = "icloud.slash"
            }
        case .loading:
            usageSummary = nil
            title = "Loading Mac sync"
            detail = "Checking CloudKit for the latest Mac snapshot."
            symbol = "arrow.clockwise.icloud"
        case .unknown:
            usageSummary = nil
            title = "Waiting for Mac sync"
            detail = "Open Context Panel on your Mac to publish usage lanes through CloudKit."
            symbol = "icloud.and.arrow.down"
        }
    }

    private static func syncedDetail(for result: CompanionSyncLoadResult) -> String {
        switch result.transportMetadata?.source {
        case .cloudKit:
            "Latest Mac snapshot received through CloudKit."
        case .appGroup:
            appendCloudKitStatus(
                "Latest Mac snapshot loaded from the local mirror.",
                result: result
            )
        case .iCloud:
            appendCloudKitStatus(
                "Latest Mac snapshot received.",
                result: result
            )
        case .custom, .none:
            appendCloudKitStatus(
                "Latest Mac snapshot received.",
                result: result
            )
        }
    }

    private static func appendCloudKitStatus(_ detail: String, result: CompanionSyncLoadResult) -> String {
        guard result.transportMetadata?.source != .cloudKit else { return detail }
        guard let cloudKit = result.transportStatuses.first(where: { $0.source == .cloudKit }) else {
            return detail
        }
        if cloudKit.succeeded, cloudKit.loadedDocument == true {
            return "\(detail) CloudKit healthy."
        }
        if cloudKit.missingRecord {
            return "\(detail) CloudKit record not found."
        }
        if cloudKit.succeeded {
            return "\(detail) CloudKit connected."
        }
        if !cloudKit.isAvailable {
            return "\(detail) CloudKit unavailable."
        }
        return "\(detail) CloudKit retrying."
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
