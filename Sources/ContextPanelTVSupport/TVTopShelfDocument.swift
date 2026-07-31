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

    public var renderedCards: [TVTopShelfCard] {
        Array(cards.prefix(Provider.allCases.count))
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
        let statusLane = prominentStatusLane(in: section)
        let displayLane = statusLane ?? capacityLane
        let headline: String
        if let statusLane {
            headline = statusHeadline(lane: statusLane, fallbackStatus: section.status)
        } else if let remainingPercent = capacityLane?.remainingPercent {
            headline = "\(remainingPercent)% left"
        } else {
            headline = switch section.status {
            case .close, .limited, .stale, .failure, .loading:
                statusLabel(section.status)
            case .healthy, .unknown:
                capacityLane?.kind == .accountStatus ? "No fresh capacity" : "Unknown"
            }
        }
        let detail = detailText(lane: displayLane, mode: mode, fallbackStatus: section.status)
        return TVTopShelfCard(
            id: "provider-\(section.provider.rawValue)",
            provider: section.provider,
            title: "\(section.provider.displayName) · \(headline)",
            headline: headline,
            detail: detail,
            status: statusLane?.status ?? section.status,
            remainingPercent: statusLane == nil ? capacityLane?.remainingPercent : nil,
            actionURLString: TVAppRoute.provider(section.provider).url.absoluteString
        )
    }

    private static func prominentStatusLane(in section: TVProviderRunwaySection) -> TVRunwayLane? {
        let statusLanes = section.lanes.filter { lane in
            guard lane.kind == .accountStatus else { return false }
            return switch lane.status {
            case .close, .limited, .stale, .failure, .loading:
                true
            case .healthy, .unknown:
                false
            }
        }
        return statusLanes.first { $0.status == section.status } ?? statusLanes.first
    }

    private static func statusHeadline(
        lane: TVRunwayLane,
        fallbackStatus: UsageStatus
    ) -> String {
        guard let detail = lane.detailText, detail != "No fresh capacity data" else {
            return statusLabel(fallbackStatus)
        }
        let headline = lane.title.split(separator: "·").first.map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return headline.flatMap { $0.isEmpty ? nil : $0 } ?? statusLabel(fallbackStatus)
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
        if lane.kind == .accountStatus {
            let components: [String?] = switch mode {
            case .fullDetail, .projectOnly:
                [lane.detailText, lane.resetText]
            case .countsOnly:
                [lane.detailText]
            }
            let detail = components.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            return detail.isEmpty ? statusLabel(lane.status) : detail
        }
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

public struct TVTopShelfRuntimeReceiptEvidence: Equatable, Sendable {
    public let selectedSource: RuntimeReceiptSelectedSource
    public let presentationDigest: String
    public let stateBranch: RuntimeReceiptStateBranch
    public let outcome: RuntimeReceiptOutcome

    public init(
        document: TVTopShelfDocument,
        loadedDocument: Bool,
        contentReturned: Bool,
        now: Date
    ) {
        selectedSource = loadedDocument ? .companionAppGroup : .none
        let isStale = loadedDocument && document.isStale(at: now)
        stateBranch = if isStale {
            .stale
        } else {
            switch document.snapshotState {
            case .ready:
                .ready
            case .setupNeeded:
                .setupNeeded
            case .stale:
                .stale
            case .failure:
                .failure
            }
        }
        if !contentReturned || stateBranch == .failure {
            outcome = .failure
        } else if stateBranch == .ready, selectedSource != .none {
            outcome = .success
        } else {
            outcome = .degraded
        }
        presentationDigest = RuntimePresentationDigest.topShelfDocument(
            generatedAt: loadedDocument ? document.generatedAt : nil,
            renderedAt: loadedDocument ? document.renderedAt : nil,
            state: document.snapshotState,
            tvPresentationMode: document.presentationMode.runtimeTVPresentationMode,
            freshness: Self.freshness(
                document: document,
                loadedDocument: loadedDocument,
                now: now
            ),
            cards: document.renderedCards.map { card in
                RuntimeTopShelfCardPresentation(
                    provider: card.provider,
                    status: card.status,
                    remainingPercent: card.remainingPercent
                )
            },
            contentReturned: contentReturned
        )
    }

    private static func freshness(
        document: TVTopShelfDocument,
        loadedDocument: Bool,
        now: Date
    ) -> RuntimeTopShelfFreshness {
        guard loadedDocument else {
            return RuntimeTopShelfFreshness(unit: .now, value: 0, isStale: false)
        }
        let seconds = max(Int(now.timeIntervalSince(document.generatedAt)), 0)
        if seconds < 60 {
            return RuntimeTopShelfFreshness(
                unit: .now,
                value: 0,
                isStale: document.isStale(at: now)
            )
        }
        if seconds < 60 * 60 {
            return RuntimeTopShelfFreshness(
                unit: .minute,
                value: seconds / 60,
                isStale: document.isStale(at: now)
            )
        }
        if seconds < 24 * 60 * 60 {
            return RuntimeTopShelfFreshness(
                unit: .hour,
                value: seconds / (60 * 60),
                isStale: document.isStale(at: now)
            )
        }
        return RuntimeTopShelfFreshness(
            unit: .day,
            value: seconds / (24 * 60 * 60),
            isStale: document.isStale(at: now)
        )
    }

}

private extension TVPresentationMode {
    var runtimeTVPresentationMode: RuntimeTVPresentationMode {
        switch self {
        case .fullDetail:
            .fullDetail
        case .projectOnly:
            .projectOnly
        case .countsOnly:
            .countsOnly
        }
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
