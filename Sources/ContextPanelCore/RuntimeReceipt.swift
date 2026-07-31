import CryptoKit
import Foundation
import MachO

public enum RuntimeEvidenceClass: String, Codable, Equatable, Sendable {
    case actualRuntime = "actual-runtime"
}

public enum RuntimePlatform: String, Codable, Equatable, Sendable {
    case macOS
    case iOS
    case iPadOS
    case visionOS
    case watchOS
    case tvOS
}

public enum RuntimeCompanionDeviceClass: Equatable, Sendable {
    case phone
    case pad
    case vision
}

public enum RuntimeSurface: String, Codable, CaseIterable, Equatable, Sendable {
    case macOSApp = "macos.app"
    case macOSWidget = "macos.widget"
    case macOSRefreshAgent = "macos.refresh-agent"
    case iPhoneApp = "ios.app"
    case iPhoneWidget = "ios.widget"
    case iPadApp = "ipados.app"
    case iPadWidget = "ipados.widget"
    case visionOSApp = "visionos.app"
    case visionOSWidget = "visionos.widget"
    case watchOSApp = "watchos.app"
    case watchOSComplication = "watchos.complication"
    case tvOSApp = "tvos.app"
    case tvOSTopShelf = "tvos.top-shelf"

    public var platform: RuntimePlatform {
        switch self {
        case .macOSApp, .macOSWidget, .macOSRefreshAgent:
            .macOS
        case .iPhoneApp, .iPhoneWidget:
            .iOS
        case .iPadApp, .iPadWidget:
            .iPadOS
        case .visionOSApp, .visionOSWidget:
            .visionOS
        case .watchOSApp, .watchOSComplication:
            .watchOS
        case .tvOSApp, .tvOSTopShelf:
            .tvOS
        }
    }

    public static func companionApp(for deviceClass: RuntimeCompanionDeviceClass) -> RuntimeSurface {
        switch deviceClass {
        case .phone:
            .iPhoneApp
        case .pad:
            .iPadApp
        case .vision:
            .visionOSApp
        }
    }

    public static func companionWidget(for deviceClass: RuntimeCompanionDeviceClass) -> RuntimeSurface {
        switch deviceClass {
        case .phone:
            .iPhoneWidget
        case .pad:
            .iPadWidget
        case .vision:
            .visionOSWidget
        }
    }
}

public struct RuntimeSurfaceFingerprints: Codable, Equatable, Sendable {
    public let render: String
    public let runtime: String
    public let placement: String
    public let combined: String

    public init(render: String, runtime: String, placement: String, combined: String) {
        self.render = render
        self.runtime = runtime
        self.placement = placement
        self.combined = combined
    }

    var isValid: Bool {
        [render, runtime, placement, combined].allSatisfy(Self.isSHA256)
    }

    static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (48 ... 57).contains(byte) || (97 ... 102).contains(byte)
        }
    }
}

public struct RuntimeBuildCoordinate: Codable, Equatable, Sendable {
    public let marketingVersion: String
    public let buildNumber: String
    public let manifestID: String
    public let contractFingerprint: String

    public init(
        marketingVersion: String,
        buildNumber: String,
        manifestID: String,
        contractFingerprint: String
    ) {
        self.marketingVersion = marketingVersion
        self.buildNumber = buildNumber
        self.manifestID = manifestID
        self.contractFingerprint = contractFingerprint
    }
}

public struct RuntimeSurfaceBuildIdentity: Codable, Equatable, Sendable {
    public let surface: RuntimeSurface
    public let platform: RuntimePlatform
    public let artifactID: String
    public let bundleIdentifier: String
    public let build: RuntimeBuildCoordinate
    public let fingerprints: RuntimeSurfaceFingerprints
    public let executableUUIDs: [String]

    public init(
        surface: RuntimeSurface,
        artifactID: String,
        bundleIdentifier: String,
        build: RuntimeBuildCoordinate,
        fingerprints: RuntimeSurfaceFingerprints,
        executableUUIDs: [String]
    ) {
        self.surface = surface
        platform = surface.platform
        self.artifactID = artifactID
        self.bundleIdentifier = bundleIdentifier
        self.build = build
        self.fingerprints = fingerprints
        self.executableUUIDs = Self.normalizedExecutableUUIDs(executableUUIDs)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        surface = try container.decode(RuntimeSurface.self, forKey: .surface)
        platform = try container.decode(RuntimePlatform.self, forKey: .platform)
        guard platform == surface.platform else {
            throw DecodingError.dataCorruptedError(
                forKey: .platform,
                in: container,
                debugDescription: "runtime platform does not match the surface"
            )
        }
        artifactID = try container.decode(String.self, forKey: .artifactID)
        bundleIdentifier = try container.decode(String.self, forKey: .bundleIdentifier)
        build = try container.decode(RuntimeBuildCoordinate.self, forKey: .build)
        fingerprints = try container.decode(RuntimeSurfaceFingerprints.self, forKey: .fingerprints)
        let decodedExecutableUUIDs = try container.decode([String].self, forKey: .executableUUIDs)
        let normalizedExecutableUUIDs = Self.normalizedExecutableUUIDs(decodedExecutableUUIDs)
        guard decodedExecutableUUIDs == normalizedExecutableUUIDs else {
            throw DecodingError.dataCorruptedError(
                forKey: .executableUUIDs,
                in: container,
                debugDescription: "executable UUIDs must be unique canonical UUID strings"
            )
        }
        executableUUIDs = decodedExecutableUUIDs
    }

    enum CodingKeys: String, CodingKey {
        case surface
        case platform
        case artifactID
        case bundleIdentifier
        case build
        case fingerprints
        case executableUUIDs
    }

    var isValid: Bool {
        platform == surface.platform
            && !artifactID.isEmpty
            && !bundleIdentifier.isEmpty
            && !build.marketingVersion.isEmpty
            && !build.buildNumber.isEmpty
            && RuntimeSurfaceFingerprints.isSHA256(build.manifestID)
            && RuntimeSurfaceFingerprints.isSHA256(build.contractFingerprint)
            && fingerprints.isValid
            && !executableUUIDs.isEmpty
            && executableUUIDs.allSatisfy { UUID(uuidString: $0) != nil }
    }

    private static func normalizedExecutableUUIDs(_ values: [String]) -> [String] {
        Array(Set(values.compactMap { UUID(uuidString: $0)?.uuidString.uppercased() })).sorted()
    }
}

public enum RuntimeBuildIdentityLoader {
    public static let manifestResourceName = "ContextPanelSurfaceManifest"

    public static func load(
        surface: RuntimeSurface,
        bundle: Bundle = .main
    ) -> RuntimeSurfaceBuildIdentity? {
        guard let manifestURL = bundle.url(
            forResource: manifestResourceName,
            withExtension: "json"
        ),
            let data = try? Data(contentsOf: manifestURL),
            let bundleIdentifier = bundle.bundleIdentifier,
            let marketingVersion = bundle.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String,
            let buildNumber = bundle.object(
                forInfoDictionaryKey: kCFBundleVersionKey as String
            ) as? String,
            let executableUUIDs = RuntimeExecutableIdentity.loadedMainExecutableUUIDs(),
            !executableUUIDs.isEmpty
        else {
            return nil
        }

        return load(
            surface: surface,
            manifestData: data,
            bundleIdentifier: bundleIdentifier,
            marketingVersion: marketingVersion,
            buildNumber: buildNumber,
            executableUUIDs: executableUUIDs
        )
    }

    public static func load(
        surface: RuntimeSurface,
        manifestData: Data,
        bundleIdentifier: String,
        marketingVersion: String,
        buildNumber: String,
        executableUUIDs: [String]
    ) -> RuntimeSurfaceBuildIdentity? {
        guard !bundleIdentifier.isEmpty,
              !marketingVersion.isEmpty,
              !buildNumber.isEmpty,
              !executableUUIDs.isEmpty,
              let manifest = try? JSONDecoder().decode(EmbeddedSurfaceManifest.self, from: manifestData),
              manifest.schemaVersion == 1,
              manifest.kind == "context-panel-surface-build-intent",
              RuntimeSurfaceFingerprints.isSHA256(manifest.manifestID),
              RuntimeSurfaceFingerprints.isSHA256(manifest.contractFingerprint)
        else {
            return nil
        }

        let matches = manifest.surfaces.filter { $0.id == surface.rawValue }
        guard matches.count == 1,
              let match = matches.first,
              !match.artifactID.isEmpty,
              match.bundleIdentifier == bundleIdentifier,
              match.fingerprints.isValid
        else {
            return nil
        }

        let identity = RuntimeSurfaceBuildIdentity(
            surface: surface,
            artifactID: match.artifactID,
            bundleIdentifier: bundleIdentifier,
            build: RuntimeBuildCoordinate(
                marketingVersion: marketingVersion,
                buildNumber: buildNumber,
                manifestID: manifest.manifestID,
                contractFingerprint: manifest.contractFingerprint
            ),
            fingerprints: match.fingerprints,
            executableUUIDs: executableUUIDs
        )
        return identity.isValid ? identity : nil
    }
}

enum RuntimeExecutableIdentity {
    static func loadedMainExecutableUUIDs() -> [String]? {
        guard _dyld_image_count() > 0,
              let header = _dyld_get_image_header(0),
              let uuid = loadedImageUUID(header: header)
        else {
            return nil
        }
        return [uuid]
    }

    private static func loadedImageUUID(
        header: UnsafePointer<mach_header>
    ) -> String? {
        let commandCount: UInt32
        let commands: UnsafeRawPointer
        switch header.pointee.magic {
        case MH_MAGIC:
            commandCount = header.pointee.ncmds
            commands = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header>.size)
        case MH_MAGIC_64:
            let header64 = UnsafeRawPointer(header).assumingMemoryBound(to: mach_header_64.self)
            commandCount = header64.pointee.ncmds
            commands = UnsafeRawPointer(header64).advanced(by: MemoryLayout<mach_header_64>.size)
        default:
            return nil
        }

        var commandPointer = commands
        for _ in 0 ..< commandCount {
            let command = commandPointer.assumingMemoryBound(to: load_command.self).pointee
            guard command.cmdsize >= MemoryLayout<load_command>.size else { return nil }
            if command.cmd == LC_UUID {
                let uuidCommand = commandPointer.assumingMemoryBound(to: uuid_command.self).pointee
                return UUID(uuid: uuidCommand.uuid).uuidString.uppercased()
            }
            commandPointer = commandPointer.advanced(by: Int(command.cmdsize))
        }
        return nil
    }
}

public enum RuntimeReceiptTrigger: String, Codable, Equatable, Sendable {
    case appSnapshotLoad = "app-snapshot-load"
    case widgetSnapshot = "widget-snapshot"
    case widgetTimeline = "widget-timeline"
    case refreshOnce = "refresh-once"
    case backgroundRefresh = "background-refresh"
}

public enum RuntimeReceiptPresentationMode: String, Codable, Equatable, Sendable {
    case appOverview = "app-overview"
    case widgetSystemSmall = "widget-system-small"
    case widgetSystemMedium = "widget-system-medium"
    case widgetSystemLarge = "widget-system-large"
    case widgetSystemExtraLarge = "widget-system-extra-large"
    case widgetAccessoryCircular = "widget-accessory-circular"
    case widgetAccessoryRectangular = "widget-accessory-rectangular"
    case widgetAccessoryInline = "widget-accessory-inline"
    case widgetAccessoryCorner = "widget-accessory-corner"
    case widgetUnknown = "widget-unknown"
    case refreshAgent = "refresh-agent"
    case watchApp = "watch-app"
    case topShelf = "top-shelf"
}

public enum RuntimeReceiptSelectedSource: String, Codable, Equatable, Sendable {
    case appGroupSnapshot = "app-group-snapshot"
    case widgetSandboxMirror = "widget-sandbox-mirror"
    case refreshedSnapshot = "refreshed-snapshot"
    case companionAppGroup = "companion-app-group"
    case companionLocalCache = "companion-local-cache"
    case cloudKit = "cloudkit"
    case iCloud = "icloud"
    case none
}

public enum RuntimeReceiptStateBranch: String, Codable, Equatable, Sendable {
    case ready
    case setupNeeded = "setup-needed"
    case stale
    case failure
    case refreshed
    case skippedFresh = "skipped-fresh"
    case skippedAlreadyRunning = "skipped-already-running"
    case skippedNoReports = "skipped-no-reports"
    case unknown
}

public enum RuntimeReceiptOutcome: String, Codable, Equatable, Sendable {
    case success
    case degraded
    case failure
}

public enum CompanionRuntimePresentationSurface: Equatable, Sendable {
    case app
    case widget
}

public struct CompanionRuntimeReceiptEvidence: Equatable, Sendable {
    public let selectedSource: RuntimeReceiptSelectedSource
    public let presentationDigest: String
    public let stateBranch: RuntimeReceiptStateBranch
    public let outcome: RuntimeReceiptOutcome

    public init(
        result: CompanionSyncLoadResult,
        snapshot: WidgetSnapshot,
        displayPreferences: WidgetDisplayPreferences,
        appearanceSettings: CompanionAppearanceSettings?,
        presentationSurface: CompanionRuntimePresentationSurface,
        presentationMode: RuntimeReceiptPresentationMode,
        presentationDate: Date
    ) {
        selectedSource = switch result.transportMetadata?.source {
        case .some(.appGroup):
            .companionAppGroup
        case .some(.localCache):
            .companionLocalCache
        case .some(.cloudKit):
            .cloudKit
        case .some(.iCloud):
            .iCloud
        case .some(.custom), .none:
            .none
        }
        stateBranch = switch snapshot.state {
        case .ready:
            .ready
        case .setupNeeded:
            .setupNeeded
        case .stale:
            .stale
        case .failure:
            .failure
        }
        if stateBranch == .failure {
            outcome = .failure
        } else if stateBranch == .ready,
                  snapshot.syncErrorMessage == nil,
                  selectedSource != .none {
            outcome = .success
        } else {
            outcome = .degraded
        }
        presentationDigest = RuntimePresentationDigest.companionSnapshot(
            result: result,
            snapshot: snapshot,
            displayPreferences: displayPreferences,
            appearanceSettings: appearanceSettings,
            presentationSurface: presentationSurface,
            presentationMode: presentationMode,
            presentationDate: presentationDate
        )
    }
}

public struct RuntimeReceipt: Codable, Equatable, Identifiable, Sendable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let id: String
    public let evidenceClass: RuntimeEvidenceClass
    public let sessionID: UUID
    public let sessionCreatedAt: Date
    public let sessionExpiresAt: Date
    public let observedAt: Date
    public let retentionExpiresAt: Date
    public let processInstanceID: UUID
    public let processSequence: UInt64
    public let buildIdentity: RuntimeSurfaceBuildIdentity
    public let trigger: RuntimeReceiptTrigger
    public let presentationMode: RuntimeReceiptPresentationMode
    public let selectedSource: RuntimeReceiptSelectedSource
    public let presentationDigest: String
    public let stateBranch: RuntimeReceiptStateBranch
    public let outcome: RuntimeReceiptOutcome

    public init(
        session: RuntimeValidationSession,
        observedAt: Date,
        processInstanceID: UUID,
        processSequence: UInt64,
        buildIdentity: RuntimeSurfaceBuildIdentity,
        trigger: RuntimeReceiptTrigger,
        presentationMode: RuntimeReceiptPresentationMode,
        selectedSource: RuntimeReceiptSelectedSource,
        presentationDigest: String,
        stateBranch: RuntimeReceiptStateBranch,
        outcome: RuntimeReceiptOutcome
    ) {
        schemaVersion = Self.schemaVersion
        evidenceClass = .actualRuntime
        sessionID = session.id
        sessionCreatedAt = Self.wholeSecond(session.createdAt)
        sessionExpiresAt = Self.wholeSecond(session.expiresAt)
        self.observedAt = Self.wholeSecond(observedAt)
        retentionExpiresAt = Self.wholeSecond(
            observedAt.addingTimeInterval(session.receiptTTLSeconds)
        )
        self.processInstanceID = processInstanceID
        self.processSequence = processSequence
        self.buildIdentity = buildIdentity
        self.trigger = trigger
        self.presentationMode = presentationMode
        self.selectedSource = selectedSource
        self.presentationDigest = presentationDigest
        self.stateBranch = stateBranch
        self.outcome = outcome
        id = Self.makeID(
            sessionID: sessionID,
            sessionCreatedAt: sessionCreatedAt,
            sessionExpiresAt: sessionExpiresAt,
            observedAt: self.observedAt,
            retentionExpiresAt: retentionExpiresAt,
            processInstanceID: processInstanceID,
            processSequence: processSequence,
            buildIdentity: buildIdentity,
            trigger: trigger,
            presentationMode: presentationMode,
            selectedSource: selectedSource,
            presentationDigest: presentationDigest,
            stateBranch: stateBranch,
            outcome: outcome
        )
    }

    var isStructurallyValid: Bool {
        schemaVersion == Self.schemaVersion
            && evidenceClass == .actualRuntime
            && RuntimeSurfaceFingerprints.isSHA256(id)
            && RuntimeSurfaceFingerprints.isSHA256(presentationDigest)
            && processSequence > 0
            && buildIdentity.isValid
            && sessionCreatedAt <= sessionExpiresAt
            && sessionExpiresAt.timeIntervalSince(sessionCreatedAt) <= RuntimeValidationSession.maximumDuration
            && observedAt >= sessionCreatedAt.addingTimeInterval(-RuntimeValidationSession.maximumClockSkew)
            && observedAt < sessionExpiresAt
            && retentionExpiresAt > observedAt
            && retentionExpiresAt.timeIntervalSince(observedAt) <= RuntimeValidationSession.maximumReceiptTTL
            && id == Self.makeID(
                sessionID: sessionID,
                sessionCreatedAt: sessionCreatedAt,
                sessionExpiresAt: sessionExpiresAt,
                observedAt: observedAt,
                retentionExpiresAt: retentionExpiresAt,
                processInstanceID: processInstanceID,
                processSequence: processSequence,
                buildIdentity: buildIdentity,
                trigger: trigger,
                presentationMode: presentationMode,
                selectedSource: selectedSource,
                presentationDigest: presentationDigest,
                stateBranch: stateBranch,
                outcome: outcome
            )
    }

    var rateLimitKey: String {
        [
            sessionID.uuidString.lowercased(),
            buildIdentity.surface.rawValue,
            trigger.rawValue,
            presentationMode.rawValue,
            selectedSource.rawValue,
            presentationDigest,
            stateBranch.rawValue,
            outcome.rawValue,
        ].joined(separator: "|")
    }

    private static func makeID(
        sessionID: UUID,
        sessionCreatedAt: Date,
        sessionExpiresAt: Date,
        observedAt: Date,
        retentionExpiresAt: Date,
        processInstanceID: UUID,
        processSequence: UInt64,
        buildIdentity: RuntimeSurfaceBuildIdentity,
        trigger: RuntimeReceiptTrigger,
        presentationMode: RuntimeReceiptPresentationMode,
        selectedSource: RuntimeReceiptSelectedSource,
        presentationDigest: String,
        stateBranch: RuntimeReceiptStateBranch,
        outcome: RuntimeReceiptOutcome
    ) -> String {
        RuntimeReceiptDigest.sha256(
            domain: "context-panel/runtime-receipt/id/v1",
            parts: [
                sessionID.uuidString.lowercased(),
                String(epochSeconds(sessionCreatedAt)),
                String(epochSeconds(sessionExpiresAt)),
                String(epochSeconds(observedAt)),
                String(epochSeconds(retentionExpiresAt)),
                buildIdentity.surface.rawValue,
                buildIdentity.platform.rawValue,
                buildIdentity.artifactID,
                buildIdentity.bundleIdentifier,
                buildIdentity.build.marketingVersion,
                buildIdentity.build.buildNumber,
                buildIdentity.build.manifestID,
                buildIdentity.build.contractFingerprint,
                buildIdentity.fingerprints.render,
                buildIdentity.fingerprints.runtime,
                buildIdentity.fingerprints.placement,
                buildIdentity.fingerprints.combined,
                buildIdentity.executableUUIDs.joined(separator: ","),
                processInstanceID.uuidString.lowercased(),
                String(processSequence),
                trigger.rawValue,
                presentationMode.rawValue,
                selectedSource.rawValue,
                presentationDigest,
                stateBranch.rawValue,
                outcome.rawValue,
            ]
        )
    }

    private static func wholeSecond(_ date: Date) -> Date {
        Date(timeIntervalSince1970: TimeInterval(epochSeconds(date)))
    }

    private static func epochSeconds(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970.rounded(.down))
    }
}

public enum RuntimePresentationDigest {
    public static func storedSnapshot(
        _ snapshot: StoredUsageSnapshot?,
        status: UsageStatus
    ) -> String {
        let payload = StoredSnapshotDigestPayload(
            schemaVersion: 1,
            savedAtMilliseconds: snapshot.map { milliseconds($0.savedAt) },
            generatedAtMilliseconds: snapshot.map { milliseconds($0.snapshot.generatedAt) },
            status: status.rawValue,
            limits: sanitizedLimits(snapshot?.snapshot.limits ?? []),
            reports: sanitizedReports(snapshot?.reports ?? [])
        )
        return RuntimeReceiptDigest.canonicalDigest(payload)
    }

    public static func widgetSnapshot(
        _ snapshot: WidgetSnapshot,
        displayPreferences: WidgetDisplayPreferences,
        presentationMode: RuntimeReceiptPresentationMode,
        presentationDate: Date
    ) -> String {
        widgetSnapshot(
            snapshot,
            displayPreferences: displayPreferences,
            presentationMode: presentationMode,
            presentationDate: presentationDate,
            includesPresentationDates: true
        )
    }

    private static func widgetSnapshot(
        _ snapshot: WidgetSnapshot,
        displayPreferences: WidgetDisplayPreferences,
        presentationMode: RuntimeReceiptPresentationMode,
        presentationDate: Date,
        includesPresentationDates: Bool
    ) -> String {
        let promptCacheSummary = snapshot.promptCacheSummary
        let payload = WidgetSnapshotDigestPayload(
            schemaVersion: 1,
            generatedAtMilliseconds: includesPresentationDates
                ? milliseconds(snapshot.generatedAt)
                : nil,
            presentationDateMilliseconds: includesPresentationDates
                ? milliseconds(presentationDate)
                : nil,
            state: snapshot.state.rawValue,
            status: snapshot.status.rawValue,
            promptCacheState: snapshot.promptCacheWidgetState.rawValue,
            promptCache: SanitizedPromptCacheDigestPayload(
                latestHitRateBasisPoints: basisPoints(promptCacheSummary.latestHitRate),
                weightedHitRateBasisPoints: basisPoints(promptCacheSummary.tokenWeightedHitRate),
                comparisonStatus: promptCacheSummary.comparisonStatus.rawValue,
                hasPossibleBreak: promptCacheSummary.hasPossibleCacheBreak
            ),
            fastModeSettings: SanitizedFastModeSettingsDigestPayload(
                defaultStandardBurnRateMilliUnitsPerHour: quantized(
                    snapshot.fastModeForecastSettings.defaultStandardBurnRateUnitsPerHour
                ),
                fastModeMultiplierMilli: quantized(
                    snapshot.fastModeForecastSettings.fastModeMultiplier
                ),
                reserveMilliUnits: quantized(
                    snapshot.fastModeForecastSettings.reserveUnits
                ),
                minimumSafeMilliHours: quantized(
                    snapshot.fastModeForecastSettings.minimumSafeHours
                )
            ),
            fastModeForecasts: sanitizedFastModeForecasts(
                snapshot: snapshot,
                presentationDate: presentationDate
            ),
            presentationMode: presentationMode.rawValue,
            mainLimitPreferences: displayPreferences.mainLimits.map { preference in
                SanitizedWidgetPreferenceDigestPayload(
                    provider: preference.provider.rawValue,
                    window: preference.window.rawValue,
                    isVisible: preference.isVisible,
                    sortOrder: preference.sortOrder
                )
            },
            selectedMainLimits: selectedMainLimits(
                snapshot: snapshot,
                displayPreferences: displayPreferences,
                presentationMode: presentationMode
            ),
            limits: sanitizedLimits(snapshot.limits),
            reports: sanitizedReports(snapshot.reports)
        )
        return RuntimeReceiptDigest.canonicalDigest(payload)
    }

    public static func companionSnapshot(
        result: CompanionSyncLoadResult,
        snapshot: WidgetSnapshot,
        displayPreferences: WidgetDisplayPreferences,
        appearanceSettings: CompanionAppearanceSettings?,
        presentationSurface: CompanionRuntimePresentationSurface,
        presentationMode: RuntimeReceiptPresentationMode,
        presentationDate: Date
    ) -> String {
        let payload = CompanionSnapshotDigestPayload(
            schemaVersion: 1,
            widgetSnapshotDigest: widgetSnapshot(
                snapshot,
                displayPreferences: displayPreferences,
                presentationMode: presentationMode,
                presentationDate: presentationDate,
                includesPresentationDates: result.document != nil
            ),
            deliveryStatus: result.transportMetadata?.deliveryStatus.rawValue,
            hasSyncError: snapshot.syncErrorMessage != nil,
            refreshAttentionProviders: snapshot.refreshAttentionSummary?.providers
                .map(\.rawValue)
                .sorted() ?? [],
            refreshAttentionSnapshotAgeStale: snapshot.refreshAttentionSummary?.isSnapshotAgeStale ?? false,
            visionOSAppAppearance: presentationSurface == .app
                ? appearanceSettings?.visionOSAppAppearance.rawValue
                : nil,
            visionOSWidgetAppearance: presentationSurface == .app
                ? appearanceSettings?.visionOSWidgetAppearance.rawValue
                : nil,
            resolvedVisionOSWidgetAppearance: presentationSurface == .widget
                ? appearanceSettings?.resolvedVisionOSWidgetAppearance.rawValue
                : nil
        )
        return RuntimeReceiptDigest.canonicalDigest(payload)
    }

    private static func sanitizedFastModeForecasts(
        snapshot: WidgetSnapshot,
        presentationDate: Date
    ) -> [SanitizedFastModeForecastDigestPayload] {
        snapshot.usageSnapshot.mainLimitSummaries.openAIFastModeCapacityForecast(
            now: presentationDate,
            observedBurnRates: snapshot.observedBurnRates,
            settings: snapshot.fastModeForecastSettings
        ).forecasts.map { forecast in
            SanitizedFastModeForecastDigestPayload(
                window: forecast.window?.rawValue,
                recommendation: forecast.recommendation.rawValue,
                confidence: forecast.confidence.rawValue,
                unit: forecast.unit?.rawValue,
                remainingMilliUnits: quantized(forecast.remainingUnits),
                totalMilliUnits: quantized(forecast.totalUnits),
                nextResetAtMilliseconds: forecast.nextResetAt.map(milliseconds),
                milliHoursUntilReset: quantized(forecast.hoursUntilReset),
                standardBurnRateMilliUnitsPerHour: quantized(
                    forecast.standardBurnRateUnitsPerHour
                ),
                fastBurnRateMilliUnitsPerHour: quantized(
                    forecast.fastBurnRateUnitsPerHour
                ),
                standardModeRunwayMilliHours: quantized(
                    forecast.standardModeRunwayHours
                ),
                fastModeRunwayMilliHours: quantized(forecast.fastModeRunwayHours),
                projectedStandardMilliUnits: quantized(
                    forecast.projectedStandardUseUntilReset
                ),
                projectedFastMilliUnits: quantized(
                    forecast.projectedFastUseUntilReset
                ),
                reserveMilliUnits: quantized(forecast.reserveUnits)
            )
        }
    }

    private static func selectedMainLimits(
        snapshot: WidgetSnapshot,
        displayPreferences: WidgetDisplayPreferences,
        presentationMode: RuntimeReceiptPresentationMode
    ) -> [SanitizedWidgetLaneDigestPayload] {
        let summaries = snapshot.usageSnapshot.mainLimitSummaries
        let lanes: [WidgetMainLimitLane]
        switch presentationMode {
        case .widgetSystemSmall:
            let selection = displayPreferences.mainLimitAnswerSelection(from: summaries)
            lanes = [selection.primary].compactMap { $0 }
                + selection.compactSupportingLanes(maximumCount: 2)
        case .widgetSystemMedium:
            lanes = displayPreferences.visibleMainLimitLanes(from: summaries, maximumCount: 3)
        case .widgetSystemLarge, .widgetSystemExtraLarge:
            lanes = displayPreferences.visibleMainLimitLanes(from: summaries, maximumCount: 5)
        case .appOverview, .widgetAccessoryCircular, .widgetAccessoryRectangular,
             .widgetAccessoryInline, .widgetAccessoryCorner, .widgetUnknown,
             .refreshAgent, .watchApp, .topShelf:
            lanes = displayPreferences.visibleMainLimitLanes(from: summaries, maximumCount: 5)
        }
        return lanes.map { lane in
            SanitizedWidgetLaneDigestPayload(
                provider: lane.provider.rawValue,
                window: lane.window.rawValue,
                status: lane.summary?.status.rawValue,
                usageBucket: lane.summary?.usageRatio.map {
                    min(Int(($0 * 20).rounded(.down)), 20)
                }
            )
        }
    }

    private static func sanitizedLimits(_ limits: [UsageLimit]) -> [SanitizedLimitDigestPayload] {
        limits.map { limit in
            SanitizedLimitDigestPayload(
                provider: limit.provider.rawValue,
                unit: limit.unit.rawValue,
                status: limit.status.rawValue,
                usageBucket: limit.usageRatio.map { min(Int(($0 * 20).rounded(.down)), 20) },
                resetsAtMilliseconds: limit.resetsAt.map(milliseconds),
                lastUpdatedAtMilliseconds: limit.lastUpdatedAt.map(milliseconds),
                confidence: limit.confidence.rawValue,
                freshnessMode: limit.freshnessMode.rawValue,
                presentationAssumption: limit.presentationAssumption?.rawValue
            )
        }.sorted { $0.sortKey < $1.sortKey }
    }

    private static func sanitizedReports(_ reports: [StoredProviderReport]) -> [SanitizedReportDigestPayload] {
        reports.map { report in
            SanitizedReportDigestPayload(
                provider: report.provider.rawValue,
                generatedAtMilliseconds: milliseconds(report.generatedAt),
                status: report.status.rawValue,
                accessState: report.accessState.kind.rawValue
            )
        }.sorted { $0.sortKey < $1.sortKey }
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    private static func basisPoints(_ value: Double?) -> Int? {
        value.map { Int(($0 * 10_000).rounded()) }
    }

    private static func quantized(_ value: Double?) -> Int64? {
        value.map { Int64(($0 * 1_000).rounded()) }
    }

    private static func quantized(_ value: Double) -> Int64 {
        Int64((value * 1_000).rounded())
    }
}

private struct EmbeddedSurfaceManifest: Decodable {
    let schemaVersion: Int
    let kind: String
    let manifestID: String
    let contractFingerprint: String
    let surfaces: [EmbeddedSurface]

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case kind
        case manifestID = "manifestId"
        case contractFingerprint
        case surfaces
    }
}

private struct EmbeddedSurface: Decodable {
    let id: String
    let artifactID: String
    let bundleIdentifier: String
    let fingerprints: RuntimeSurfaceFingerprints

    enum CodingKeys: String, CodingKey {
        case id
        case artifactID = "artifactId"
        case bundleIdentifier
        case fingerprints
    }
}

private struct StoredSnapshotDigestPayload: Encodable {
    let schemaVersion: Int
    let savedAtMilliseconds: Int64?
    let generatedAtMilliseconds: Int64?
    let status: String
    let limits: [SanitizedLimitDigestPayload]
    let reports: [SanitizedReportDigestPayload]
}

private struct WidgetSnapshotDigestPayload: Encodable {
    let schemaVersion: Int
    let generatedAtMilliseconds: Int64?
    let presentationDateMilliseconds: Int64?
    let state: String
    let status: String
    let promptCacheState: String
    let promptCache: SanitizedPromptCacheDigestPayload
    let fastModeSettings: SanitizedFastModeSettingsDigestPayload
    let fastModeForecasts: [SanitizedFastModeForecastDigestPayload]
    let presentationMode: String
    let mainLimitPreferences: [SanitizedWidgetPreferenceDigestPayload]
    let selectedMainLimits: [SanitizedWidgetLaneDigestPayload]
    let limits: [SanitizedLimitDigestPayload]
    let reports: [SanitizedReportDigestPayload]
}

private struct CompanionSnapshotDigestPayload: Encodable {
    let schemaVersion: Int
    let widgetSnapshotDigest: String
    let deliveryStatus: String?
    let hasSyncError: Bool
    let refreshAttentionProviders: [String]
    let refreshAttentionSnapshotAgeStale: Bool
    let visionOSAppAppearance: String?
    let visionOSWidgetAppearance: String?
    let resolvedVisionOSWidgetAppearance: String?
}

private struct SanitizedPromptCacheDigestPayload: Encodable {
    let latestHitRateBasisPoints: Int?
    let weightedHitRateBasisPoints: Int?
    let comparisonStatus: String
    let hasPossibleBreak: Bool
}

private struct SanitizedFastModeSettingsDigestPayload: Encodable {
    let defaultStandardBurnRateMilliUnitsPerHour: Int64?
    let fastModeMultiplierMilli: Int64
    let reserveMilliUnits: Int64
    let minimumSafeMilliHours: Int64
}

private struct SanitizedFastModeForecastDigestPayload: Encodable {
    let window: String?
    let recommendation: String
    let confidence: String
    let unit: String?
    let remainingMilliUnits: Int64?
    let totalMilliUnits: Int64?
    let nextResetAtMilliseconds: Int64?
    let milliHoursUntilReset: Int64?
    let standardBurnRateMilliUnitsPerHour: Int64?
    let fastBurnRateMilliUnitsPerHour: Int64?
    let standardModeRunwayMilliHours: Int64?
    let fastModeRunwayMilliHours: Int64?
    let projectedStandardMilliUnits: Int64?
    let projectedFastMilliUnits: Int64?
    let reserveMilliUnits: Int64
}

private struct SanitizedWidgetLaneDigestPayload: Encodable {
    let provider: String
    let window: String
    let status: String?
    let usageBucket: Int?
}

private struct SanitizedWidgetPreferenceDigestPayload: Encodable {
    let provider: String
    let window: String
    let isVisible: Bool
    let sortOrder: Int
}

private struct SanitizedLimitDigestPayload: Encodable {
    let provider: String
    let unit: String
    let status: String
    let usageBucket: Int?
    let resetsAtMilliseconds: Int64?
    let lastUpdatedAtMilliseconds: Int64?
    let confidence: String
    let freshnessMode: String
    let presentationAssumption: String?

    var sortKey: String {
        [
            provider,
            unit,
            status,
            usageBucket.map(String.init) ?? "",
            resetsAtMilliseconds.map(String.init) ?? "",
            lastUpdatedAtMilliseconds.map(String.init) ?? "",
            confidence,
            freshnessMode,
            presentationAssumption ?? "",
        ].joined(separator: "|")
    }
}

private struct SanitizedReportDigestPayload: Encodable {
    let provider: String
    let generatedAtMilliseconds: Int64
    let status: String
    let accessState: String

    var sortKey: String {
        [provider, String(generatedAtMilliseconds), status, accessState].joined(separator: "|")
    }
}

enum RuntimeReceiptDigest {
    static func canonicalDigest<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else {
            return sha256(domain: "context-panel/runtime-presentation/v1", parts: ["encoding-failed"])
        }
        return sha256(
            domain: "context-panel/runtime-presentation/v1",
            dataParts: [data]
        )
    }

    static func sha256(domain: String, parts: [String]) -> String {
        sha256(domain: domain, dataParts: parts.map { Data($0.utf8) })
    }

    private static func sha256(domain: String, dataParts: [Data]) -> String {
        var hasher = SHA256()
        update(&hasher, with: Data(domain.utf8))
        for part in dataParts {
            update(&hasher, with: part)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func update(_ hasher: inout SHA256, with data: Data) {
        var length = UInt64(data.count).bigEndian
        withUnsafeBytes(of: &length) { hasher.update(bufferPointer: $0) }
        hasher.update(data: data)
    }
}
