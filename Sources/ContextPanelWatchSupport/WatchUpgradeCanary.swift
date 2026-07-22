import ContextPanelCore
import Foundation
import OSLog

private let watchUpgradeCanaryLogger = Logger(
    subsystem: "com.shinycomputers.contextpanel",
    category: "watch-upgrade-canary"
)

public enum WatchUpgradeCanary {
    public static let infoDictionaryKey = "ContextPanelWatchUpgradeCanary"
    static let fallbackMarker = "?"
    public static let marker = Bundle.main.object(
        forInfoDictionaryKey: infoDictionaryKey
    ) as? String ?? fallbackMarker
}

public enum WatchUpgradeCanaryComponent: String, Codable, Sendable {
    case app
    case widget
}

public enum WatchUpgradeCanaryEvent: String, Codable, Sendable {
    case appActivated
    case configurationsBeforeReload
    case reloadRequested
    case configurationsAfterReload
    case widgetPlaceholder
    case widgetSnapshot
    case widgetTimeline

    public var shortName: String {
        switch self {
        case .appActivated:
            "app"
        case .configurationsBeforeReload:
            "before"
        case .reloadRequested:
            "reload"
        case .configurationsAfterReload:
            "after"
        case .widgetPlaceholder:
            "ph"
        case .widgetSnapshot:
            "snap"
        case .widgetTimeline:
            "done"
        }
    }
}

public enum WatchUpgradeCanaryFamily: String, Codable, CaseIterable, Sendable, Identifiable {
    case circular
    case corner
    case rectangular
    case inline

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .circular:
            "Circle"
        case .corner:
            "Corner"
        case .rectangular:
            "Rect"
        case .inline:
            "Inline"
        }
    }

    public var compactName: String {
        switch self {
        case .circular:
            "C"
        case .corner:
            "K"
        case .rectangular:
            "R"
        case .inline:
            "I"
        }
    }
}

public enum WatchUpgradeCanaryRequestContext: String, Codable, CaseIterable, Sendable {
    case live
    case preview
}

public struct WatchUpgradeCanaryBuildIdentity: Codable, Equatable, Sendable {
    public let bundleIdentifier: String
    public let marketingVersion: String
    public let buildNumber: String

    public init(
        bundleIdentifier: String,
        marketingVersion: String,
        buildNumber: String
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.marketingVersion = marketingVersion
        self.buildNumber = buildNumber
    }

    public static func current(bundle: Bundle = .main) -> WatchUpgradeCanaryBuildIdentity {
        WatchUpgradeCanaryBuildIdentity(
            bundleIdentifier: bundle.bundleIdentifier ?? "unknown",
            marketingVersion: bundle.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "unknown",
            buildNumber: bundle.object(
                forInfoDictionaryKey: kCFBundleVersionKey as String
            ) as? String ?? "unknown"
        )
    }
}

public struct WatchUpgradeCanaryFamilyCount: Codable, Equatable, Sendable, Identifiable {
    public let family: WatchUpgradeCanaryFamily
    public let count: Int

    public var id: WatchUpgradeCanaryFamily { family }

    public init(family: WatchUpgradeCanaryFamily, count: Int) {
        self.family = family
        self.count = count
    }
}

public struct WatchUpgradeCanaryConfigurationSnapshot: Codable, Equatable, Sendable {
    public let matchingKindCount: Int
    public let otherKindCount: Int
    public let families: [WatchUpgradeCanaryFamilyCount]

    public init(
        matchingKindCount: Int,
        otherKindCount: Int,
        familyCounts: [WatchUpgradeCanaryFamily: Int]
    ) {
        self.matchingKindCount = matchingKindCount
        self.otherKindCount = otherKindCount
        families = WatchUpgradeCanaryFamily.allCases.compactMap { family in
            guard let count = familyCounts[family], count > 0 else { return nil }
            return WatchUpgradeCanaryFamilyCount(family: family, count: count)
        }
    }

    public func count(for family: WatchUpgradeCanaryFamily) -> Int {
        families.first { $0.family == family }?.count ?? 0
    }
}

public struct WatchUpgradeCanaryEventRecord: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let id: UUID
    public let marker: String
    public let component: WatchUpgradeCanaryComponent
    public let event: WatchUpgradeCanaryEvent
    public let identity: WatchUpgradeCanaryBuildIdentity
    public let family: WatchUpgradeCanaryFamily?
    public let requestContext: WatchUpgradeCanaryRequestContext?
    public let configuration: WatchUpgradeCanaryConfigurationSnapshot?
    public let observedAt: Date
    public let processIdentifier: Int32

    public init(
        id: UUID = UUID(),
        marker: String = WatchUpgradeCanary.marker,
        component: WatchUpgradeCanaryComponent,
        event: WatchUpgradeCanaryEvent,
        identity: WatchUpgradeCanaryBuildIdentity = .current(),
        family: WatchUpgradeCanaryFamily? = nil,
        requestContext: WatchUpgradeCanaryRequestContext? = nil,
        configuration: WatchUpgradeCanaryConfigurationSnapshot? = nil,
        observedAt: Date = Date(),
        processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier
    ) {
        schemaVersion = Self.schemaVersion
        self.id = id
        self.marker = marker
        self.component = component
        self.event = event
        self.identity = identity
        self.family = family
        self.requestContext = requestContext
        self.configuration = configuration
        self.observedAt = observedAt
        self.processIdentifier = processIdentifier
    }
}

public enum WatchUpgradeCanaryHistorySource: String, Sendable {
    case neutral
    case legacy
}

public struct WatchUpgradeCanaryHistoryEvent: Equatable, Sendable, Identifiable {
    public let id: String
    public let source: WatchUpgradeCanaryHistorySource
    public let marker: String
    public let component: WatchUpgradeCanaryComponent
    public let eventName: String
    public let family: WatchUpgradeCanaryFamily?
    public let requestContext: WatchUpgradeCanaryRequestContext?
    public let marketingVersion: String
    public let buildNumber: String
    public let observedAt: Date

    public init(record: WatchUpgradeCanaryEventRecord) {
        id = "neutral:\(record.id.uuidString)"
        source = .neutral
        marker = record.marker
        component = record.component
        eventName = record.event.rawValue
        family = record.family
        requestContext = record.requestContext
        marketingVersion = record.identity.marketingVersion
        buildNumber = record.identity.buildNumber
        observedAt = record.observedAt
    }

    init(
        fileName: String,
        marker: String,
        component: WatchUpgradeCanaryComponent,
        eventName: String,
        family: WatchUpgradeCanaryFamily?,
        requestContext: WatchUpgradeCanaryRequestContext?,
        marketingVersion: String,
        buildNumber: String,
        observedAt: Date
    ) {
        id = "legacy:\(fileName)"
        source = .legacy
        self.marker = marker
        self.component = component
        self.eventName = eventName
        self.family = family
        self.requestContext = requestContext
        self.marketingVersion = marketingVersion
        self.buildNumber = buildNumber
        self.observedAt = observedAt
    }

    public var shortEventName: String {
        switch eventName {
        case WatchUpgradeCanaryEvent.widgetPlaceholder.rawValue, "widgetPlaceholder":
            "ph"
        case WatchUpgradeCanaryEvent.widgetSnapshot.rawValue, "widgetSnapshot":
            "snap"
        case WatchUpgradeCanaryEvent.widgetTimeline.rawValue, "widgetTimelineCompleted":
            "done"
        case "widgetTimelineStarted":
            "start"
        case WatchUpgradeCanaryEvent.reloadRequested.rawValue:
            "reload"
        default:
            eventName
        }
    }
}

public final class WatchUpgradeCanaryEventStore: @unchecked Sendable {
    private static let eventDirectoryName = "Neutral Events"

    private let directoryURL: URL

    public convenience init?() {
        guard let directoryURL = ContextPanelLocations.watchUpgradeCanaryDirectoryURL() else {
            return nil
        }
        self.init(directoryURL: directoryURL)
    }

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    @discardableResult
    public func append(_ record: WatchUpgradeCanaryEventRecord) throws -> URL {
        let eventDirectoryURL = directoryURL.appending(
            path: Self.eventDirectoryName,
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: eventDirectoryURL,
            withIntermediateDirectories: true
        )
        let fileURL = eventDirectoryURL.appending(
            path: "event-\(record.id.uuidString.lowercased()).json"
        )
        try Self.encoder.encode(record).write(to: fileURL, options: .atomic)
        return fileURL
    }

    public func loadHistory() throws -> [WatchUpgradeCanaryHistoryEvent] {
        let neutralEvents = try loadNeutralEvents().map(
            WatchUpgradeCanaryHistoryEvent.init(record:)
        )
        let legacyEvents = try loadLegacyEvents()
        return (neutralEvents + legacyEvents).sorted { left, right in
            if left.observedAt == right.observedAt {
                return left.id < right.id
            }
            return left.observedAt < right.observedAt
        }
    }

    private func loadNeutralEvents() throws -> [WatchUpgradeCanaryEventRecord] {
        let eventDirectoryURL = directoryURL.appending(
            path: Self.eventDirectoryName,
            directoryHint: .isDirectory
        )
        let files = try contentsOfDirectoryIfPresent(at: eventDirectoryURL)
        return files.compactMap { fileURL in
            guard fileURL.pathExtension == "json",
                  let data = try? Data(contentsOf: fileURL),
                  let record = try? Self.decoder.decode(
                    WatchUpgradeCanaryEventRecord.self,
                    from: data
                  ),
                  record.schemaVersion == WatchUpgradeCanaryEventRecord.schemaVersion
            else {
                return nil
            }
            return record
        }
    }

    private func loadLegacyEvents() throws -> [WatchUpgradeCanaryHistoryEvent] {
        let files = try contentsOfDirectoryIfPresent(at: directoryURL)
        return files.compactMap { fileURL in
            guard fileURL.lastPathComponent.hasPrefix("watch-"),
                  fileURL.lastPathComponent.contains("-canary-"),
                  fileURL.lastPathComponent.hasSuffix("-receipt.json")
            else {
                return nil
            }
            return legacyEvent(from: fileURL)
        }
    }

    private func legacyEvent(from fileURL: URL) -> WatchUpgradeCanaryHistoryEvent? {
        guard let data = try? Data(contentsOf: fileURL),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              let schemaVersion = (dictionary["schemaVersion"] as? NSNumber)?.intValue,
              schemaVersion == 2 || schemaVersion == 3,
              let marker = dictionary["marker"] as? String,
              fileURL.lastPathComponent.contains("-canary-\(marker.lowercased())-"),
              let componentRaw = dictionary["component"] as? String,
              let component = WatchUpgradeCanaryComponent(rawValue: componentRaw),
              let eventName = dictionary["event"] as? String,
              Self.legacyEventIsValid(component: component, eventName: eventName),
              let marketingVersion = dictionary["marketingVersion"] as? String,
              let buildNumber = dictionary["buildNumber"] as? String,
              let observedAt = Self.legacyDate(dictionary["observedAt"])
        else {
            return nil
        }
        return WatchUpgradeCanaryHistoryEvent(
            fileName: fileURL.lastPathComponent,
            marker: marker,
            component: component,
            eventName: eventName,
            family: (dictionary["family"] as? String).flatMap(WatchUpgradeCanaryFamily.init(rawValue:)),
            requestContext: (dictionary["requestContext"] as? String).flatMap(
                WatchUpgradeCanaryRequestContext.init(rawValue:)
            ),
            marketingVersion: marketingVersion,
            buildNumber: buildNumber,
            observedAt: observedAt
        )
    }

    private func contentsOfDirectoryIfPresent(at url: URL) throws -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return []
        }
        guard isDirectory.boolValue else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil
        )
    }

    private static func legacyEventIsValid(
        component: WatchUpgradeCanaryComponent,
        eventName: String
    ) -> Bool {
        switch component {
        case .app:
            eventName == "appLaunch"
        case .widget:
            [
                "widgetPlaceholder",
                "widgetSnapshot",
                "widgetTimelineStarted",
                "widgetTimelineCompleted",
            ].contains(eventName)
        }
    }

    private static func legacyDate(_ value: Any?) -> Date? {
        if let number = value as? NSNumber {
            return Date(timeIntervalSince1970: number.doubleValue / 1_000)
        }
        guard let string = value as? String else { return nil }
        return ISO8601DateFormatter().date(from: string)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()
}

public enum WatchUpgradeCanaryRecorder {
    private static let queue = DispatchQueue(
        label: "com.shinycomputers.contextpanel.watch-upgrade-canary-c",
        qos: .utility
    )

    public static func recordWidgetAsync(
        event: WatchUpgradeCanaryEvent,
        family: WatchUpgradeCanaryFamily,
        requestContext: WatchUpgradeCanaryRequestContext,
        observedAt: Date = Date()
    ) {
        enqueue(WatchUpgradeCanaryEventRecord(
            component: .widget,
            event: event,
            family: family,
            requestContext: requestContext,
            observedAt: observedAt
        ))
    }

    public static func recordAppAsync(
        event: WatchUpgradeCanaryEvent,
        configuration: WatchUpgradeCanaryConfigurationSnapshot? = nil,
        observedAt: Date = Date()
    ) {
        enqueue(WatchUpgradeCanaryEventRecord(
            component: .app,
            event: event,
            configuration: configuration,
            observedAt: observedAt
        ))
    }

    private static func enqueue(_ record: WatchUpgradeCanaryEventRecord) {
        watchUpgradeCanaryLogger.notice(
            "Observed neutral Watch upgrade canary event: marker=\(record.marker, privacy: .public) component=\(record.component.rawValue, privacy: .public) event=\(record.event.rawValue, privacy: .public) build=\(record.identity.buildNumber, privacy: .public)"
        )
        queue.async {
            do {
                guard let store = WatchUpgradeCanaryEventStore() else {
                    watchUpgradeCanaryLogger.error(
                        "Neutral Watch upgrade canary App Group store is unavailable."
                    )
                    return
                }
                try store.append(record)
                watchUpgradeCanaryLogger.log(
                    "Recorded neutral Watch upgrade canary event: marker=\(record.marker, privacy: .public) event=\(record.event.rawValue, privacy: .public) build=\(record.identity.buildNumber, privacy: .public)"
                )
            } catch {
                let error = error as NSError
                watchUpgradeCanaryLogger.error(
                    "Neutral Watch upgrade canary write failed: domain=\(error.domain, privacy: .public) code=\(error.code)"
                )
            }
        }
    }
}
