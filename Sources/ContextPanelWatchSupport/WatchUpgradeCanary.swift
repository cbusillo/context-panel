import ContextPanelCore
import Foundation
import OSLog

private let watchUpgradeCanaryLogger = Logger(
    subsystem: "com.shinycomputers.contextpanel",
    category: "watch-upgrade-canary"
)

public enum WatchUpgradeCanary {
    public static let infoDictionaryKey = "ContextPanelWatchUpgradeCanary"
    static let fallbackMarker = "B"
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
    case widgetPlaceholder
    case widgetSnapshot
    case widgetTimelineStarted
    case widgetTimelineCompleted
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
}

public enum WatchUpgradeCanaryRequestContext: String, Codable, CaseIterable, Sendable {
    case live
    case preview
}

public struct WatchUpgradeCanaryObservationKey: Hashable, Sendable {
    public let family: WatchUpgradeCanaryFamily
    public let requestContext: WatchUpgradeCanaryRequestContext

    public init(
        family: WatchUpgradeCanaryFamily,
        requestContext: WatchUpgradeCanaryRequestContext
    ) {
        self.family = family
        self.requestContext = requestContext
    }

    public static var all: [WatchUpgradeCanaryObservationKey] {
        WatchUpgradeCanaryFamily.allCases.flatMap { family in
            WatchUpgradeCanaryRequestContext.allCases.map { requestContext in
                WatchUpgradeCanaryObservationKey(
                    family: family,
                    requestContext: requestContext
                )
            }
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
    public static let schemaVersion = 3

    public let schemaVersion: Int
    public let component: WatchUpgradeCanaryComponent
    public let marker: String
    public let bundleIdentifier: String
    public let marketingVersion: String
    public let buildNumber: String
    public let event: WatchUpgradeCanaryEvent
    public let family: WatchUpgradeCanaryFamily?
    public let requestContext: WatchUpgradeCanaryRequestContext?
    public let requestID: UUID?
    public let requestStartedAt: Date?
    public let observedAt: Date
    public let sessionID: UUID?
    public let processIdentifier: Int32

    public init(
        component: WatchUpgradeCanaryComponent,
        identity: WatchUpgradeCanaryBuildIdentity,
        event: WatchUpgradeCanaryEvent,
        family: WatchUpgradeCanaryFamily?,
        requestContext: WatchUpgradeCanaryRequestContext?,
        requestID: UUID?,
        requestStartedAt: Date?,
        sessionID: UUID?,
        processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier,
        observedAt: Date
    ) {
        schemaVersion = Self.schemaVersion
        self.component = component
        marker = WatchUpgradeCanary.marker
        bundleIdentifier = identity.bundleIdentifier
        marketingVersion = identity.marketingVersion
        buildNumber = identity.buildNumber
        self.event = event
        self.family = family
        self.requestContext = requestContext
        self.requestID = requestID
        self.requestStartedAt = requestStartedAt
        self.observedAt = observedAt
        self.sessionID = sessionID
        self.processIdentifier = processIdentifier
    }

    public func belongsToCanaryRun(
        marketingVersion: String,
        buildNumber: String,
        sessionID: UUID,
        appObservedAt: Date? = nil
    ) -> Bool {
        let callbackStartedAt = requestStartedAt ?? observedAt
        return marker == WatchUpgradeCanary.marker
            && self.marketingVersion == marketingVersion
            && self.buildNumber == buildNumber
            && self.sessionID == sessionID
            && appObservedAt.map { callbackStartedAt >= $0 } != false
    }
}

public struct WatchUpgradeCanaryObservationSnapshot: Equatable, Sendable {
    public let placeholder: WatchUpgradeCanaryReceipt?
    public let snapshot: WatchUpgradeCanaryReceipt?
    public let timeline: WatchUpgradeCanaryReceipt?

    public init(
        placeholder: WatchUpgradeCanaryReceipt?,
        snapshot: WatchUpgradeCanaryReceipt?,
        timeline: WatchUpgradeCanaryReceipt?
    ) {
        self.placeholder = placeholder
        self.snapshot = snapshot
        self.timeline = timeline
    }

    public static let empty = WatchUpgradeCanaryObservationSnapshot(
        placeholder: nil,
        snapshot: nil,
        timeline: nil
    )

    public var latest: WatchUpgradeCanaryReceipt? {
        [placeholder, snapshot, timeline]
            .compactMap { $0 }
            .max { $0.observedAt < $1.observedAt }
    }

    public func strongestCurrentReceipt(
        marketingVersion: String,
        buildNumber: String,
        sessionID: UUID,
        appObservedAt: Date
    ) -> WatchUpgradeCanaryReceipt? {
        [placeholder, snapshot, timeline]
            .compactMap { $0 }
            .filter {
                $0.belongsToCanaryRun(
                    marketingVersion: marketingVersion,
                    buildNumber: buildNumber,
                    sessionID: sessionID,
                    appObservedAt: appObservedAt
                )
            }
            .max { left, right in
                let leftRank = Self.evidenceRank(left.event)
                let rightRank = Self.evidenceRank(right.event)
                if leftRank == rightRank {
                    return left.observedAt < right.observedAt
                }
                return leftRank < rightRank
            }
    }

    private static func evidenceRank(_ event: WatchUpgradeCanaryEvent) -> Int {
        switch event {
        case .widgetPlaceholder:
            0
        case .widgetSnapshot:
            1
        case .widgetTimelineStarted:
            2
        case .widgetTimelineCompleted:
            3
        case .appLaunch:
            -1
        }
    }
}

public struct WatchUpgradeCanarySnapshot: Equatable, Sendable {
    public let app: WatchUpgradeCanaryReceipt?
    public let observations: [WatchUpgradeCanaryObservationKey: WatchUpgradeCanaryObservationSnapshot]

    public init(
        app: WatchUpgradeCanaryReceipt?,
        observations: [WatchUpgradeCanaryObservationKey: WatchUpgradeCanaryObservationSnapshot]
    ) {
        self.app = app
        self.observations = observations
    }

    public static let empty = WatchUpgradeCanarySnapshot(app: nil, observations: [:])

    public func observation(
        family: WatchUpgradeCanaryFamily,
        requestContext: WatchUpgradeCanaryRequestContext
    ) -> WatchUpgradeCanaryObservationSnapshot {
        observations[WatchUpgradeCanaryObservationKey(
            family: family,
            requestContext: requestContext
        )] ?? .empty
    }

    public var widget: WatchUpgradeCanaryReceipt? {
        observations.values
            .compactMap(\.latest)
            .max { $0.observedAt < $1.observedAt }
    }
}

private enum WatchUpgradeCanaryReceiptSlot: Hashable {
    case app
    case placeholder(WatchUpgradeCanaryObservationKey)
    case snapshot(WatchUpgradeCanaryObservationKey)
    case timeline(WatchUpgradeCanaryObservationKey)

    var label: String {
        switch self {
        case .app:
            "app"
        case let .placeholder(key):
            "\(key.family.rawValue)-\(key.requestContext.rawValue)-placeholder"
        case let .snapshot(key):
            "\(key.family.rawValue)-\(key.requestContext.rawValue)-snapshot"
        case let .timeline(key):
            "\(key.family.rawValue)-\(key.requestContext.rawValue)-timeline"
        }
    }

    var component: WatchUpgradeCanaryComponent {
        switch self {
        case .app:
            .app
        case .placeholder, .snapshot, .timeline:
            .widget
        }
    }

    var family: WatchUpgradeCanaryFamily? {
        switch self {
        case .app:
            nil
        case let .placeholder(key), let .snapshot(key), let .timeline(key):
            key.family
        }
    }

    var requestContext: WatchUpgradeCanaryRequestContext? {
        switch self {
        case .app:
            nil
        case let .placeholder(key), let .snapshot(key), let .timeline(key):
            key.requestContext
        }
    }

    func accepts(event: WatchUpgradeCanaryEvent) -> Bool {
        switch self {
        case .app:
            event == .appLaunch
        case .placeholder:
            event == .widgetPlaceholder
        case .snapshot:
            event == .widgetSnapshot
        case .timeline:
            event == .widgetTimelineStarted || event == .widgetTimelineCompleted
        }
    }

    var fileName: String {
        let marker = WatchUpgradeCanary.marker.lowercased()
        switch self {
        case .app:
            return "watch-app-canary-\(marker)-receipt.json"
        case let .placeholder(key):
            return widgetFileName(marker: marker, key: key, suffix: "placeholder")
        case let .snapshot(key):
            return widgetFileName(marker: marker, key: key, suffix: "snapshot")
        case let .timeline(key):
            return widgetFileName(marker: marker, key: key, suffix: "timeline")
        }
    }

    private func widgetFileName(
        marker: String,
        key: WatchUpgradeCanaryObservationKey,
        suffix: String
    ) -> String {
        "watch-widget-canary-\(marker)-\(key.family.rawValue)-\(key.requestContext.rawValue)-\(suffix)-receipt.json"
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
    public func recordApp(
        identity: WatchUpgradeCanaryBuildIdentity = .current(),
        sessionID: UUID,
        now: Date = Date()
    ) -> WatchUpgradeCanaryReceipt? {
        let receipt = WatchUpgradeCanaryReceipt(
            component: .app,
            identity: identity,
            event: .appLaunch,
            family: nil,
            requestContext: nil,
            requestID: nil,
            requestStartedAt: nil,
            sessionID: sessionID,
            observedAt: now
        )
        Self.fileLock.lock()
        defer { Self.fileLock.unlock() }

        do {
            try Self.coordinatedWrite(receipt, to: receiptURL(for: .app))
            logRecorded(receipt)
            return receipt
        } catch {
            logWriteFailure(component: .app, error: error)
            return nil
        }
    }

    @discardableResult
    public func recordWidgetObservation(
        event: WatchUpgradeCanaryEvent,
        family: WatchUpgradeCanaryFamily,
        requestContext: WatchUpgradeCanaryRequestContext,
        requestID: UUID,
        identity: WatchUpgradeCanaryBuildIdentity = .current(),
        sessionID: UUID?,
        now: Date = Date()
    ) -> WatchUpgradeCanaryReceipt? {
        let key = WatchUpgradeCanaryObservationKey(
            family: family,
            requestContext: requestContext
        )
        let slot: WatchUpgradeCanaryReceiptSlot
        switch event {
        case .widgetPlaceholder:
            slot = .placeholder(key)
        case .widgetSnapshot:
            slot = .snapshot(key)
        case .appLaunch, .widgetTimelineStarted, .widgetTimelineCompleted:
            return nil
        }
        let receipt = WatchUpgradeCanaryReceipt(
            component: .widget,
            identity: identity,
            event: event,
            family: family,
            requestContext: requestContext,
            requestID: requestID,
            requestStartedAt: nil,
            sessionID: sessionID,
            observedAt: now
        )
        return writeWidgetReceipt(
            receipt,
            slot: slot,
            expectedSessionID: sessionID
        ) { existing in
            guard let existing else { return true }
            guard existing.observedAt <= now else {
                throw ReceiptError.requestSuperseded
            }
            return true
        }
    }

    @discardableResult
    public func recordTimelineStarted(
        family: WatchUpgradeCanaryFamily,
        requestContext: WatchUpgradeCanaryRequestContext,
        requestID: UUID,
        identity: WatchUpgradeCanaryBuildIdentity = .current(),
        sessionID: UUID?,
        now: Date = Date()
    ) -> WatchUpgradeCanaryReceipt? {
        let key = WatchUpgradeCanaryObservationKey(
            family: family,
            requestContext: requestContext
        )
        let receipt = WatchUpgradeCanaryReceipt(
            component: .widget,
            identity: identity,
            event: .widgetTimelineStarted,
            family: family,
            requestContext: requestContext,
            requestID: requestID,
            requestStartedAt: now,
            sessionID: sessionID,
            observedAt: now
        )
        return writeWidgetReceipt(
            receipt,
            slot: .timeline(key),
            expectedSessionID: sessionID
        ) { existing in
            guard let existing else { return true }
            if existing.requestID == requestID {
                return false
            }
            guard (existing.requestStartedAt ?? existing.observedAt) <= now else {
                throw ReceiptError.requestSuperseded
            }
            return true
        }
    }

    @discardableResult
    public func recordTimelineCompleted(
        family: WatchUpgradeCanaryFamily,
        requestContext: WatchUpgradeCanaryRequestContext,
        requestID: UUID,
        startedAt: Date,
        identity: WatchUpgradeCanaryBuildIdentity = .current(),
        sessionID: UUID?,
        now: Date = Date()
    ) -> WatchUpgradeCanaryReceipt? {
        let key = WatchUpgradeCanaryObservationKey(
            family: family,
            requestContext: requestContext
        )
        let receipt = WatchUpgradeCanaryReceipt(
            component: .widget,
            identity: identity,
            event: .widgetTimelineCompleted,
            family: family,
            requestContext: requestContext,
            requestID: requestID,
            requestStartedAt: startedAt,
            sessionID: sessionID,
            observedAt: now
        )
        return writeWidgetReceipt(
            receipt,
            slot: .timeline(key),
            expectedSessionID: sessionID
        ) { existing in
            guard let existing else {
                throw ReceiptError.requestStartMissing
            }
            guard existing.requestID == requestID,
                  let existingStartedAt = existing.requestStartedAt,
                  abs(existingStartedAt.timeIntervalSince(startedAt)) < 0.001
            else {
                throw ReceiptError.requestSuperseded
            }
            switch existing.event {
            case .widgetTimelineStarted:
                return true
            case .widgetTimelineCompleted:
                return false
            case .appLaunch, .widgetPlaceholder, .widgetSnapshot:
                throw ReceiptError.invalidReceipt
            }
        }
    }

    public func captureWidgetSessionID() -> UUID? {
        load(slot: .app)?.sessionID
    }

    public func loadSnapshot() -> WatchUpgradeCanarySnapshot {
        var observations: [WatchUpgradeCanaryObservationKey: WatchUpgradeCanaryObservationSnapshot] = [:]
        for key in WatchUpgradeCanaryObservationKey.all {
            let observation = WatchUpgradeCanaryObservationSnapshot(
                placeholder: load(slot: .placeholder(key)),
                snapshot: load(slot: .snapshot(key)),
                timeline: load(slot: .timeline(key))
            )
            if observation != .empty {
                observations[key] = observation
            }
        }
        return WatchUpgradeCanarySnapshot(
            app: load(slot: .app),
            observations: observations
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

    private func writeWidgetReceipt(
        _ receipt: WatchUpgradeCanaryReceipt,
        slot: WatchUpgradeCanaryReceiptSlot,
        expectedSessionID: UUID?,
        validateExisting: @escaping (WatchUpgradeCanaryReceipt?) throws -> Bool
    ) -> WatchUpgradeCanaryReceipt? {
        Self.fileLock.lock()
        defer { Self.fileLock.unlock() }

        do {
            let storedReceipt = try Self.coordinatedWidgetWrite(
                receipt,
                expectedSessionID: expectedSessionID,
                appReceiptURL: receiptURL(for: .app),
                widgetReceiptURL: receiptURL(for: slot),
                expectedWidgetSlot: slot,
                validateExisting: validateExisting
            )
            logRecorded(storedReceipt)
            return storedReceipt
        } catch ReceiptError.sessionChanged {
            let family = receipt.family?.rawValue ?? "none"
            watchUpgradeCanaryLogger.log(
                "Skipped Watch upgrade canary event from a previous app session: event=\(receipt.event.rawValue, privacy: .public) family=\(family, privacy: .public)"
            )
            return nil
        } catch ReceiptError.requestSuperseded {
            let family = receipt.family?.rawValue ?? "none"
            watchUpgradeCanaryLogger.log(
                "Skipped superseded Watch upgrade canary request: event=\(receipt.event.rawValue, privacy: .public) family=\(family, privacy: .public)"
            )
            return nil
        } catch ReceiptError.requestStartMissing {
            let family = receipt.family?.rawValue ?? "none"
            watchUpgradeCanaryLogger.log(
                "Skipped Watch upgrade canary completion without a matching start: family=\(family, privacy: .public)"
            )
            return nil
        } catch {
            logWriteFailure(component: .widget, error: error)
            return nil
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
                "Watch upgrade canary read failed: slot=\(slot.label, privacy: .public) domain=\(error.domain, privacy: .public) code=\(error.code)"
            )
            return nil
        }
    }

    private func receiptURL(for slot: WatchUpgradeCanaryReceiptSlot) -> URL {
        directoryURL.appending(path: slot.fileName)
    }

    private func logRecorded(_ receipt: WatchUpgradeCanaryReceipt) {
        let family = receipt.family?.rawValue ?? "none"
        let requestContext = receipt.requestContext?.rawValue ?? "none"
        watchUpgradeCanaryLogger.log(
            "Recorded Watch upgrade canary: marker=\(receipt.marker, privacy: .public) component=\(receipt.component.rawValue, privacy: .public) build=\(receipt.buildNumber, privacy: .public) event=\(receipt.event.rawValue, privacy: .public) family=\(family, privacy: .public) context=\(requestContext, privacy: .public)"
        )
    }

    private func logWriteFailure(component: WatchUpgradeCanaryComponent, error: Error) {
        let error = error as NSError
        watchUpgradeCanaryLogger.error(
            "Watch upgrade canary write failed: component=\(component.rawValue, privacy: .public) domain=\(error.domain, privacy: .public) code=\(error.code)"
        )
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
        expectedWidgetSlot: WatchUpgradeCanaryReceiptSlot,
        validateExisting: (WatchUpgradeCanaryReceipt?) throws -> Bool
    ) throws -> WatchUpgradeCanaryReceipt {
        var storedReceipt: WatchUpgradeCanaryReceipt?
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
                let callbackStartedAt = receipt.requestStartedAt ?? receipt.observedAt
                guard appReceipt.map({ callbackStartedAt >= $0.observedAt }) != false else {
                    throw ReceiptError.sessionChanged
                }
                let existing: WatchUpgradeCanaryReceipt?
                do {
                    existing = try decodeReceipt(
                        from: coordinatedWidgetURL,
                        expectedSlot: expectedWidgetSlot
                    )
                } catch ReceiptError.invalidReceipt {
                    existing = nil
                }
                guard try validateExisting(existing) else {
                    storedReceipt = existing
                    return
                }
                try FileManager.default.createDirectory(
                    at: coordinatedWidgetURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try makeEncoder().encode(receipt).write(
                    to: coordinatedWidgetURL,
                    options: .atomic
                )
                storedReceipt = receipt
            } catch {
                accessError = error
            }
        }
        if let accessError { throw accessError }
        if let coordinatorError { throw coordinatorError }
        guard let storedReceipt else { throw ReceiptError.invalidReceipt }
        return storedReceipt
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
        let data = try Data(contentsOf: url)
        let candidate: WatchUpgradeCanaryReceipt
        do {
            candidate = try makeDecoder().decode(
                WatchUpgradeCanaryReceipt.self,
                from: data
            )
        } catch {
            throw ReceiptError.invalidReceipt
        }
        guard candidate.schemaVersion == WatchUpgradeCanaryReceipt.schemaVersion,
              candidate.marker == WatchUpgradeCanary.marker,
              candidate.component == expectedSlot.component,
              candidate.family == expectedSlot.family,
              candidate.requestContext == expectedSlot.requestContext,
              expectedSlot.accepts(event: candidate.event)
        else {
            throw ReceiptError.invalidReceipt
        }
        switch expectedSlot {
        case .app:
            guard candidate.requestID == nil,
                  candidate.requestStartedAt == nil
            else {
                throw ReceiptError.invalidReceipt
            }
        case .placeholder, .snapshot:
            guard candidate.requestID != nil,
                  candidate.requestStartedAt == nil
            else {
                throw ReceiptError.invalidReceipt
            }
        case .timeline:
            guard candidate.requestID != nil,
                  candidate.requestStartedAt != nil
            else {
                throw ReceiptError.invalidReceipt
            }
        }
        return candidate
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    private enum ReceiptError: Error {
        case invalidReceipt
        case sessionChanged
        case requestStartMissing
        case requestSuperseded
    }
}
