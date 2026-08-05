import ContextPanelCore
import Foundation

public enum WatchSyncPresentationTone: Equatable, Sendable {
    case available
    case warning
    case failure
    case neutral
}

public struct WatchSyncPresentation: Equatable, Sendable {
    public let title: String
    public let detail: String
    public let diagnosticDetail: String?
    public let diagnosticAccessibilityLabel: String?
    public let symbol: String
    public let tone: WatchSyncPresentationTone
    public let generatedText: String?
    public let generatedAccessibilityText: String?
    public let shouldShowDetail: Bool

    public init(
        result: CompanionSyncLoadResult,
        snapshot: WidgetSnapshot,
        syncErrorMessage: String?,
        now: Date = Date()
    ) {
        switch result.status {
        case .healthy, .close, .limited:
            if let generatedAt = result.document?.snapshot.generatedAt {
                generatedText = SnapshotFreshness.compactAgeText(since: generatedAt, now: now)
                generatedAccessibilityText = Self.relativeAccessibilityText(since: generatedAt, now: now)
            } else {
                generatedText = nil
                generatedAccessibilityText = nil
            }
        case .stale, .failure, .loading, .unknown:
            generatedText = nil
            generatedAccessibilityText = nil
        }

        let visibleDiagnostic = result.status == .failure
            ? Self.safeDiagnosticDetail(syncErrorMessage)
            : nil
        diagnosticDetail = visibleDiagnostic
        diagnosticAccessibilityLabel = visibleDiagnostic.map { "Sync error details: \($0)" }
        shouldShowDetail = result.status == .failure || result.status == .stale || result.status == .unknown

        switch result.status {
        case .healthy, .close, .limited:
            title = "Synced"
            detail = snapshot.message
            symbol = "checkmark.circle"
            tone = .available
        case .stale:
            title = "Saved usage is stale"
            detail = syncErrorMessage == nil
                ? "Open Context Panel on your Mac to refresh this watch."
                : "Showing saved usage because the latest update failed."
            symbol = "clock.badge.exclamationmark"
            tone = .warning
        case .loading:
            title = "Checking for updates"
            detail = "Looking for the latest usage from your Mac."
            symbol = "arrow.clockwise.icloud"
            tone = .neutral
        case .failure:
            title = "Update unavailable"
            detail = "The watch could not load the latest usage from your Mac."
            symbol = "icloud.slash"
            tone = .failure
        case .unknown:
            title = "Waiting for your Mac"
            detail = "Open Context Panel on your Mac to share usage with this watch."
            symbol = "icloud.and.arrow.down"
            tone = .neutral
        }
    }

    private static let maximumDiagnosticCharacterCount = 120

    private static func relativeAccessibilityText(since date: Date, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    private static func safeDiagnosticDetail(_ value: String?) -> String? {
        guard let value else { return nil }

        let redacted = ConnectorRedactor.safeErrorDescription(value)
        let normalized = normalizedText(redacted)
        guard !normalized.isEmpty else { return nil }
        guard normalized.count > maximumDiagnosticCharacterCount else { return normalized }

        let prefix = normalized.prefix(maximumDiagnosticCharacterCount - 1)
        return String(prefix).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    private static func normalizedText(_ value: String) -> String {
        value
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}
