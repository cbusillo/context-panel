import ContextPanelCore
import Foundation

public enum TVSnapshotFreshnessPolicy {
    public static func isStale(
        state: WidgetSnapshotState,
        generatedAt: Date,
        at now: Date,
        maximumAge: TimeInterval = SnapshotFreshness.companionProviderMaximumAge
    ) -> Bool {
        state == .stale || now.timeIntervalSince(generatedAt) > maximumAge
    }

    public static func expirationDate(
        generatedAt: Date,
        maximumAge: TimeInterval = SnapshotFreshness.companionProviderMaximumAge
    ) -> Date {
        generatedAt.addingTimeInterval(maximumAge)
    }
}

public struct TVTopShelfCard: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let provider: Provider?
    public let title: String
    public let headline: String
    public let detail: String
    public let status: UsageStatus
    public let remainingPercent: Int?
    public let actionURLString: String

    public init(
        id: String,
        provider: Provider?,
        title: String,
        headline: String,
        detail: String,
        status: UsageStatus,
        remainingPercent: Int?,
        actionURLString: String
    ) {
        self.id = id
        self.provider = provider
        self.title = title
        self.headline = headline
        self.detail = detail
        self.status = status
        self.remainingPercent = remainingPercent
        self.actionURLString = actionURLString
    }
}

public struct TVTopShelfDocument: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let generatedAt: Date
    public let renderedAt: Date
    public let snapshotState: WidgetSnapshotState
    public let presentationMode: TVPresentationMode
    public let cards: [TVTopShelfCard]

    public init(
        snapshot: WidgetSnapshot,
        preferences: WidgetDisplayPreferences = .defaultPreferences,
        mode: TVPresentationMode,
        now: Date = Date()
    ) {
        let presentation = TVRunwayPresentation(
            snapshot: snapshot,
            preferences: preferences,
            mode: mode,
            now: now
        )
        schemaVersion = Self.schemaVersion
        generatedAt = presentation.generatedAt
        renderedAt = now
        snapshotState = presentation.state
        presentationMode = mode
        cards = presentation.sections.isEmpty
            ? [Self.setupCard(presentation: presentation)]
            : presentation.sections.map { Self.card(section: $0, mode: mode) }
    }

    public var containsProviderData: Bool {
        cards.contains { $0.provider != nil }
    }

    public func isStale(
        at now: Date,
        maximumAge: TimeInterval = SnapshotFreshness.companionProviderMaximumAge
    ) -> Bool {
        TVSnapshotFreshnessPolicy.isStale(
            state: snapshotState,
            generatedAt: generatedAt,
            at: now,
            maximumAge: maximumAge
        )
    }

    public func collectionTitle(at now: Date) -> String {
        guard containsProviderData else { return "Context Panel" }
        if isStale(at: now) { return "Saved provider runway" }
        if cards.contains(where: { $0.status == .failure || $0.status == .limited }) {
            return "Provider attention"
        }
        if cards.contains(where: { $0.status == .close }) {
            return "Runway is getting tight"
        }
        return "Provider runway"
    }

    public func freshnessText(at now: Date) -> String {
        let prefix = isStale(at: now) ? "Saved" : "Updated"
        return "\(prefix) \(Self.compactAge(since: generatedAt, now: now))"
    }

    public func contentExpirationDate(at now: Date) -> Date? {
        guard containsProviderData, !isStale(at: now) else { return nil }
        let expirationDate = TVSnapshotFreshnessPolicy.expirationDate(generatedAt: generatedAt)
        return expirationDate > now ? expirationDate : nil
    }

    private static func card(
        section: TVProviderRunwaySection,
        mode: TVPresentationMode
    ) -> TVTopShelfCard {
        let capacityLane = section.primaryLane
        let headline: String
        if let remainingPercent = capacityLane?.remainingPercent {
            headline = "\(remainingPercent)% left"
        } else {
            headline = switch section.status {
            case .close, .limited, .stale, .failure, .loading:
                statusLabel(section.status)
            case .healthy, .unknown:
                capacityLane?.kind == .accountStatus ? "No fresh capacity" : "Unknown"
            }
        }
        let detail = detailText(lane: capacityLane, mode: mode, fallbackStatus: section.status)
        return TVTopShelfCard(
            id: "provider-\(section.provider.rawValue)",
            provider: section.provider,
            title: "\(section.provider.displayName) · \(headline)",
            headline: headline,
            detail: detail,
            status: section.status,
            remainingPercent: capacityLane?.remainingPercent,
            actionURLString: TVAppRoute.provider(section.provider).url.absoluteString
        )
    }

    private static func setupCard(presentation: TVRunwayPresentation) -> TVTopShelfCard {
        TVTopShelfCard(
            id: "setup",
            provider: nil,
            title: presentation.headline,
            headline: presentation.headline,
            detail: presentation.detail,
            status: presentation.status,
            remainingPercent: nil,
            actionURLString: TVAppRoute.runway.url.absoluteString
        )
    }

    private static func detailText(
        lane: TVRunwayLane?,
        mode: TVPresentationMode,
        fallbackStatus: UsageStatus
    ) -> String {
        guard let lane else { return statusLabel(fallbackStatus) }
        let safeTitle = safeLaneTitle(lane.title)
        let components: [String?] = switch mode {
        case .fullDetail:
            [safeTitle, lane.exactCapacityText, lane.resetText]
        case .projectOnly:
            [safeTitle, lane.resetText]
        case .countsOnly:
            [safeTitle]
        }
        let detail = components.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return detail.isEmpty ? statusLabel(lane.status) : detail
    }

    private static func safeLaneTitle(_ title: String) -> String {
        title.split(separator: "·").last.map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        } ?? title
    }

    private static func statusLabel(_ status: UsageStatus) -> String {
        switch status {
        case .healthy:
            "Available"
        case .close:
            "Close to limit"
        case .limited:
            "Limited"
        case .stale:
            "Saved data"
        case .unknown:
            "Unknown"
        case .failure:
            "Needs attention"
        case .loading:
            "Refreshing"
        }
    }

    private static func compactAge(since date: Date, now: Date) -> String {
        let seconds = max(Int(now.timeIntervalSince(date)), 0)
        if seconds < 60 { return "now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }
}

public struct TVTopShelfDocumentStore: Sendable {
    public let documentURL: URL

    public init(documentURL: URL) {
        self.documentURL = documentURL
    }

    public func load() -> TVTopShelfDocument? {
        guard let data = try? Data(contentsOf: documentURL) else { return nil }
        guard let document = try? Self.makeDecoder().decode(TVTopShelfDocument.self, from: data) else {
            return nil
        }
        guard document.schemaVersion == TVTopShelfDocument.schemaVersion else { return nil }
        return document
    }

    public func save(_ document: TVTopShelfDocument) throws {
        try FileManager.default.createDirectory(
            at: documentURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try Self.makeEncoder().encode(document)
        try data.write(to: documentURL, options: .atomic)
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

public struct TVTopShelfSharedLocations: Equatable, Sendable {
    public let rootDirectory: URL

    public init(containerURL: URL) {
        rootDirectory = containerURL
            .appending(path: "Library", directoryHint: .isDirectory)
            .appending(path: "Caches", directoryHint: .isDirectory)
            .appending(path: "Context Panel", directoryHint: .isDirectory)
            .appending(path: "TV", directoryHint: .isDirectory)
    }

    public var documentURL: URL {
        rootDirectory.appending(path: "top-shelf.json")
    }

    public var imageDirectoryURL: URL {
        rootDirectory.appending(path: "Top Shelf", directoryHint: .isDirectory)
    }

    public static func live(
        fileManager: FileManager = .default,
        appGroupID: String = ContextPanelLocations.companionAppGroupID
    ) -> TVTopShelfSharedLocations? {
        guard let containerURL = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else {
            return nil
        }
        return TVTopShelfSharedLocations(containerURL: containerURL)
    }
}
