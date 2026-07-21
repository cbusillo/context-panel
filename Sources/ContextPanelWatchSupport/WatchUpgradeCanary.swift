import ContextPanelCore
import Foundation
import OSLog

private let watchUpgradeCanaryLogger = Logger(
    subsystem: "com.shinycomputers.contextpanel",
    category: "watch-upgrade-canary"
)

public enum WatchUpgradeCanary {
    public static let infoDictionaryKey = "ContextPanelWatchUpgradeCanary"
    static let fallbackMarker = "A"
    public static let marker = Bundle.main.object(
        forInfoDictionaryKey: infoDictionaryKey
    ) as? String ?? fallbackMarker
}

public enum WatchUpgradeCanaryComponent: String, Codable, Sendable {
    case app
    case widget
}

public enum WatchUpgradeCanaryEvent: String, Codable, Sendable {
    case appLaunch
    case widgetSnapshot
    case widgetTimelineStarted
    case widgetTimelineCompleted

    fileprivate var component: WatchUpgradeCanaryComponent {
        switch self {
        case .appLaunch:
            .app
        case .widgetSnapshot, .widgetTimelineStarted, .widgetTimelineCompleted:
            .widget
        }
    }
}

public struct WatchUpgradeCanaryBuildIdentity: Equatable, Sendable {
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

public struct WatchUpgradeCanaryReceipt: Codable, Equatable, Sendable {
    public static let schemaVersion = 2

    public let schemaVersion: Int
    public let component: WatchUpgradeCanaryComponent
    public let marker: String
    public let bundleIdentifier: String
    public let marketingVersion: String
    public let buildNumber: String
    public let event: WatchUpgradeCanaryEvent
    public let observedAt: Date
    public let sessionID: UUID?

    public init(
        component: WatchUpgradeCanaryComponent,
        identity: WatchUpgradeCanaryBuildIdentity,
        event: WatchUpgradeCanaryEvent,
        sessionID: UUID?,
        observedAt: Date
    ) {
        schemaVersion = Self.schemaVersion
        self.component = component
        marker = WatchUpgradeCanary.marker
        bundleIdentifier = identity.bundleIdentifier
        marketingVersion = identity.marketingVersion
        buildNumber = identity.buildNumber
        self.event = event
        self.observedAt = observedAt
        self.sessionID = sessionID
    }

    public func belongsToCanaryRun(
        marketingVersion: String,
        buildNumber: String,
        sessionID: UUID
    ) -> Bool {
        marker == WatchUpgradeCanary.marker
            && self.marketingVersion == marketingVersion
            && self.buildNumber == buildNumber
            && self.sessionID == sessionID
    }
}

public struct WatchUpgradeCanarySnapshot: Equatable, Sendable {
    public let app: WatchUpgradeCanaryReceipt?
    public let widgetSnapshot: WatchUpgradeCanaryReceipt?
    public let widgetTimelineStarted: WatchUpgradeCanaryReceipt?
    public let widgetTimelineCompleted: WatchUpgradeCanaryReceipt?

    public init(
        app: WatchUpgradeCanaryReceipt?,
        widgetSnapshot: WatchUpgradeCanaryReceipt?,
        widgetTimelineStarted: WatchUpgradeCanaryReceipt?,
        widgetTimelineCompleted: WatchUpgradeCanaryReceipt?
    ) {
        self.app = app
        self.widgetSnapshot = widgetSnapshot
        self.widgetTimelineStarted = widgetTimelineStarted
        self.widgetTimelineCompleted = widgetTimelineCompleted
    }

    public static let empty = WatchUpgradeCanarySnapshot(
        app: nil,
        widgetSnapshot: nil,
        widgetTimelineStarted: nil,
        widgetTimelineCompleted: nil
    )

    public var widget: WatchUpgradeCanaryReceipt? {
        [widgetSnapshot, widgetTimelineStarted, widgetTimelineCompleted]
            .compactMap { $0 }
            .max { $0.observedAt < $1.observedAt }
    }
}

private enum WatchUpgradeCanaryReceiptSlot: String {
    case app
    case widgetSnapshot
    case widgetTimelineStarted
    case widgetTimelineCompleted

    init?(component: WatchUpgradeCanaryComponent, event: WatchUpgradeCanaryEvent) {
        guard component == event.component else { return nil }
        switch event {
        case .appLaunch:
            self = .app
        case .widgetSnapshot:
            self = .widgetSnapshot
        case .widgetTimelineStarted:
            self = .widgetTimelineStarted
        case .widgetTimelineCompleted:
            self = .widgetTimelineCompleted
        }
    }

    var component: WatchUpgradeCanaryComponent {
        switch self {
        case .app:
            .app
        case .widgetSnapshot, .widgetTimelineStarted, .widgetTimelineCompleted:
            .widget
        }
    }

    var expectedEvent: WatchUpgradeCanaryEvent {
        switch self {
        case .app:
            .appLaunch
        case .widgetSnapshot:
            .widgetSnapshot
        case .widgetTimelineStarted:
            .widgetTimelineStarted
        case .widgetTimelineCompleted:
            .widgetTimelineCompleted
        }
    }

    var fileName: String {
        let marker = WatchUpgradeCanary.marker.lowercased()
        return switch self {
        case .app:
            "watch-app-canary-\(marker)-receipt.json"
        case .widgetSnapshot:
            "watch-widget-canary-\(marker)-snapshot-receipt.json"
        case .widgetTimelineStarted:
            "watch-widget-canary-\(marker)-timeline-started-receipt.json"
        case .widgetTimelineCompleted:
            "watch-widget-canary-\(marker)-timeline-completed-receipt.json"
        }
    }
}

public final class WatchUpgradeCanaryReceiptStore: @unchecked Sendable {
    private static let fileLock = NSLock()

    private let directoryURL: URL

    public convenience init?() {
        guard let directoryURL = ContextPanelLocations.watchUpgradeCanaryDirectoryURL() else {
            watchUpgradeCanaryLogger.error(
                "Watch upgrade canary App Group directory is unavailable."
            )
            return nil
        }
        self.init(directoryURL: directoryURL)
    }

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    @discardableResult
    public func record(
        component: WatchUpgradeCanaryComponent,
        event: WatchUpgradeCanaryEvent,
        identity: WatchUpgradeCanaryBuildIdentity = .current(),
        sessionID: UUID? = nil,
        now: Date = Date()
    ) -> WatchUpgradeCanaryReceipt? {
        guard let slot = WatchUpgradeCanaryReceiptSlot(component: component, event: event) else {
            watchUpgradeCanaryLogger.error(
                "Watch upgrade canary rejected mismatched component and event: component=\(component.rawValue, privacy: .public) event=\(event.rawValue, privacy: .public)"
            )
            return nil
        }
        let receipt = WatchUpgradeCanaryReceipt(
            component: component,
            identity: identity,
            event: event,
            sessionID: sessionID,
            observedAt: now
        )
        Self.fileLock.lock()
        defer { Self.fileLock.unlock() }

        do {
            try Self.coordinatedWrite(receipt, to: receiptURL(for: slot))
            watchUpgradeCanaryLogger.log(
                "Recorded Watch upgrade canary: marker=\(receipt.marker, privacy: .public) component=\(component.rawValue, privacy: .public) build=\(receipt.buildNumber, privacy: .public) event=\(event.rawValue, privacy: .public)"
            )
            return receipt
        } catch {
            let error = error as NSError
            watchUpgradeCanaryLogger.error(
                "Watch upgrade canary write failed: component=\(component.rawValue, privacy: .public) domain=\(error.domain, privacy: .public) code=\(error.code)"
            )
            return nil
        }
    }

    @discardableResult
    public func recordWidget(
        event: WatchUpgradeCanaryEvent,
        identity: WatchUpgradeCanaryBuildIdentity = .current(),
        sessionID: UUID?,
        now: Date = Date()
    ) -> WatchUpgradeCanaryReceipt? {
        guard let slot = WatchUpgradeCanaryReceiptSlot(component: .widget, event: event) else {
            return nil
        }
        let receipt = WatchUpgradeCanaryReceipt(
            component: .widget,
            identity: identity,
            event: event,
            sessionID: sessionID,
            observedAt: now
        )
        Self.fileLock.lock()
        defer { Self.fileLock.unlock() }

        do {
            try Self.coordinatedWidgetWrite(
                receipt,
                expectedSessionID: sessionID,
                appReceiptURL: receiptURL(for: .app),
                widgetReceiptURL: receiptURL(for: slot),
                expectedWidgetSlot: slot
            )
            watchUpgradeCanaryLogger.log(
                "Recorded Watch upgrade canary: marker=\(receipt.marker, privacy: .public) component=widget build=\(receipt.buildNumber, privacy: .public) event=\(event.rawValue, privacy: .public)"
            )
            return receipt
        } catch ReceiptError.sessionChanged {
            watchUpgradeCanaryLogger.log(
                "Skipped Watch upgrade canary event from a previous app session: event=\(event.rawValue, privacy: .public)"
            )
            return nil
        } catch {
            let error = error as NSError
            watchUpgradeCanaryLogger.error(
                "Watch upgrade canary write failed: component=widget domain=\(error.domain, privacy: .public) code=\(error.code)"
            )
            return nil
        }
    }

    public func captureWidgetSessionID() -> UUID? {
        load(component: .app)?.sessionID
    }

    public func loadSnapshot() -> WatchUpgradeCanarySnapshot {
        WatchUpgradeCanarySnapshot(
            app: load(slot: .app),
            widgetSnapshot: load(slot: .widgetSnapshot),
            widgetTimelineStarted: load(slot: .widgetTimelineStarted),
            widgetTimelineCompleted: load(slot: .widgetTimelineCompleted)
        )
    }

    public func load(component: WatchUpgradeCanaryComponent) -> WatchUpgradeCanaryReceipt? {
        switch component {
        case .app:
            load(slot: .app)
        case .widget:
            loadSnapshot().widget
        }
    }

    private func load(slot: WatchUpgradeCanaryReceiptSlot) -> WatchUpgradeCanaryReceipt? {
        Self.fileLock.lock()
        defer { Self.fileLock.unlock() }

        do {
            return try Self.coordinatedLoad(
                from: receiptURL(for: slot),
                expectedSlot: slot
            )
        } catch {
            let error = error as NSError
            watchUpgradeCanaryLogger.error(
                "Watch upgrade canary read failed: slot=\(slot.rawValue, privacy: .public) domain=\(error.domain, privacy: .public) code=\(error.code)"
            )
            return nil
        }
    }

    private func receiptURL(for slot: WatchUpgradeCanaryReceiptSlot) -> URL {
        directoryURL.appending(path: slot.fileName)
    }

    private static func coordinatedWrite(
        _ receipt: WatchUpgradeCanaryReceipt,
        to url: URL
    ) throws {
        var accessError: Error?
        var coordinatorError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: url,
            options: .forReplacing,
            error: &coordinatorError
        ) { coordinatedURL in
            do {
                try FileManager.default.createDirectory(
                    at: coordinatedURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try makeEncoder().encode(receipt).write(to: coordinatedURL, options: .atomic)
            } catch {
                accessError = error
            }
        }
        if let accessError { throw accessError }
        if let coordinatorError { throw coordinatorError }
    }

    private static func coordinatedWidgetWrite(
        _ receipt: WatchUpgradeCanaryReceipt,
        expectedSessionID: UUID?,
        appReceiptURL: URL,
        widgetReceiptURL: URL,
        expectedWidgetSlot: WatchUpgradeCanaryReceiptSlot
    ) throws {
        var accessError: Error?
        var coordinatorError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: appReceiptURL,
            options: [],
            writingItemAt: widgetReceiptURL,
            options: .forReplacing,
            error: &coordinatorError
        ) { coordinatedAppURL, coordinatedWidgetURL in
            do {
                let appReceipt = try decodeReceipt(
                    from: coordinatedAppURL,
                    expectedSlot: .app
                )
                guard appReceipt?.sessionID == expectedSessionID else {
                    throw ReceiptError.sessionChanged
                }
                guard receipt.component == expectedWidgetSlot.component,
                      receipt.event == expectedWidgetSlot.expectedEvent
                else {
                    throw ReceiptError.invalidReceipt
                }
                try FileManager.default.createDirectory(
                    at: coordinatedWidgetURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try makeEncoder().encode(receipt).write(
                    to: coordinatedWidgetURL,
                    options: .atomic
                )
            } catch {
                accessError = error
            }
        }
        if let accessError { throw accessError }
        if let coordinatorError { throw coordinatorError }
    }

    private static func coordinatedLoad(
        from url: URL,
        expectedSlot: WatchUpgradeCanaryReceiptSlot
    ) throws -> WatchUpgradeCanaryReceipt? {
        var receipt: WatchUpgradeCanaryReceipt?
        var accessError: Error?
        var coordinatorError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: url,
            options: [],
            error: &coordinatorError
        ) { coordinatedURL in
            do {
                receipt = try decodeReceipt(from: coordinatedURL, expectedSlot: expectedSlot)
            } catch {
                accessError = error
            }
        }
        if let accessError { throw accessError }
        if let coordinatorError { throw coordinatorError }
        return receipt
    }

    private static func decodeReceipt(
        from url: URL,
        expectedSlot: WatchUpgradeCanaryReceiptSlot
    ) throws -> WatchUpgradeCanaryReceipt? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let candidate = try makeDecoder().decode(
            WatchUpgradeCanaryReceipt.self,
            from: Data(contentsOf: url)
        )
        guard candidate.schemaVersion == WatchUpgradeCanaryReceipt.schemaVersion,
              candidate.marker == WatchUpgradeCanary.marker,
              candidate.component == expectedSlot.component,
              candidate.event == expectedSlot.expectedEvent
        else {
            throw ReceiptError.invalidReceipt
        }
        return candidate
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private enum ReceiptError: Error {
        case invalidReceipt
        case sessionChanged
    }
}
