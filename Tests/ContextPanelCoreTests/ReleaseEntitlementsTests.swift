import Darwin
import Foundation
import Testing
import ContextPanelCore

/// Every target for a platform declares one minimum OS, in both the XcodeGen
/// `deploymentTarget` and its explicit build setting, so an embedded extension or
/// library can never require a newer OS than the app that ships it. The value
/// itself lives only in `project.yml`; bumping it consistently needs no test edit.
@Test func everyPlatformDeclaresOneDeploymentTarget() throws {
    let project = try loadProjectSpec()
    let buildSettingKeys = [
        "macOS": "MACOSX_DEPLOYMENT_TARGET",
        "iOS": "IPHONEOS_DEPLOYMENT_TARGET",
        "visionOS": "XROS_DEPLOYMENT_TARGET",
        "watchOS": "WATCHOS_DEPLOYMENT_TARGET",
        "tvOS": "TVOS_DEPLOYMENT_TARGET",
    ]
    var declared: [String: [String: String]] = [:]

    for targetName in project.targetNames {
        let target = try #require(project.target(named: targetName))
        let platforms = target["supportedDestinations"]?.stringArray
            ?? [target["platform"]?.string].compactMap { $0 }
        let allSettings = project.allTargetSettings(named: targetName) ?? []
        for platform in platforms {
            let settingKey = try #require(buildSettingKeys[platform], "\(targetName): \(platform)")
            let fromTarget = target["deploymentTarget"]?.string
                ?? target["deploymentTarget"]?.object?[platform]?.string
            let values = [fromTarget].compactMap { $0 }
                + allSettings.compactMap { $0[settingKey]?.string }
            #expect(!values.isEmpty, "\(targetName) declares no \(platform) deployment target")
            for (index, value) in values.enumerated() {
                declared[platform, default: [:]]["\(targetName)#\(index)"] = value
            }
        }
    }

    #expect(Set(declared.keys) == Set(buildSettingKeys.keys))
    for (platform, values) in declared {
        #expect(Set(values.values).count == 1, "\(platform) deployment targets disagree: \(values)")
    }
}

@Test func appAndRefreshAgentDoNotWriteRawErrorsToPublicLogs() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let appSource = try FileManager.default.contentsOfDirectory(
        at: root.appending(path: "Sources/ContextPanelApp"),
        includingPropertiesForKeys: nil
    )
    .filter { $0.pathExtension == "swift" }
    .map { try String(contentsOf: $0, encoding: .utf8) }
    .joined(separator: "\n")
    let refreshAgentSource = try String(
        contentsOf: root.appending(path: "Sources/ContextPanelRefreshAgent/ContextPanelRefreshAgent.swift"),
        encoding: .utf8
    )

    #expect(!appSource.contains("error.localizedDescription, privacy: .public"))
    #expect(!refreshAgentSource.contains(#"\(error.localizedDescription)\n\", stderr"#))
}

@Test func appAndRefreshAgentTargetsDoNotCarryGoogleOAuthBuildSettings() throws {
    let project = try loadProjectSpec()

    for targetName in ["ContextPanel", "ContextPanelRefreshAgent"] {
        let configurations = try #require(project.allTargetSettings(named: targetName))
        for settings in configurations {
            #expect(settings.keys.allSatisfy { !$0.hasPrefix("CONTEXT_PANEL_GOOGLE_") })
        }
    }

    let plist = try loadInfoPlist("Config/ContextPanelRefreshAgent-Info.plist")
    #expect(plist.keys.allSatisfy { !$0.hasPrefix("CONTEXT_PANEL_GOOGLE_") })
}

private func loadInfoPlist(_ path: String) throws -> [String: Any] {
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: path)
    let data = try Data(contentsOf: url)
    let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    return try #require(plist as? [String: Any])
}

private func loadProjectSpec() throws -> ProjectSpec {
    try ProjectSpecCache.outcome.get()
}

private enum ProjectSpecCache {
    static let outcome: Result<ProjectSpec, ProjectSpecError> = {
        do {
            return .success(try ProjectSpec.load())
        } catch let error as ProjectSpecError {
            return .failure(error)
        } catch {
            return .failure(.unexpected(String(describing: error)))
        }
    }()
}

private struct ProjectSpec: Sendable {
    private static let readerTimeout: TimeInterval = 15
    private let targets: [String: ProjectSpecValue]

    static func load(timeout: TimeInterval = readerTimeout) throws -> ProjectSpec {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let projectURL = root.appending(path: "project.yml")
        let readerURL = root.appending(path: "scripts/context-panel-project-spec-json.rb")
        guard FileManager.default.fileExists(atPath: projectURL.path) else {
            throw ProjectSpecError.missingFile("project.yml")
        }
        guard FileManager.default.fileExists(atPath: readerURL.path) else {
            throw ProjectSpecError.missingFile("scripts/context-panel-project-spec-json.rb")
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appending(path: "context-panel-project-spec-\(UUID().uuidString).json")
        let errorURL = FileManager.default.temporaryDirectory
            .appending(path: "context-panel-project-spec-\(UUID().uuidString).err")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        defer {
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: errorURL)
        }

        let outputHandle = try FileHandle(forWritingTo: outputURL)
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        defer {
            try? outputHandle.close()
            try? errorHandle.close()
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ruby")
        process.arguments = [readerURL.path, "--project", projectURL.path]
        process.currentDirectoryURL = root
        process.standardOutput = outputHandle
        process.standardError = errorHandle

        let completion = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completion.signal() }
        do {
            try process.run()
        } catch {
            throw ProjectSpecError.launchFailed(String(describing: error))
        }

        if completion.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if completion.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = completion.wait(timeout: .now() + 1)
            }
            throw ProjectSpecError.timedOut(timeout)
        }

        let errorData = try Data(contentsOf: errorURL)
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let errorText = String(decoding: errorData.prefix(2_000), as: UTF8.self)
                .replacingOccurrences(of: root.path, with: "<repo>")
            throw ProjectSpecError.readerFailed(process.terminationStatus, errorText)
        }

        let outputData = try Data(contentsOf: outputURL)
        let payload: ProjectSpecPayload
        do {
            payload = try JSONDecoder().decode(ProjectSpecPayload.self, from: outputData)
        } catch {
            throw ProjectSpecError.invalidJSON(String(describing: error))
        }
        guard payload.schemaVersion == 1 else {
            throw ProjectSpecError.unsupportedSchema(payload.schemaVersion)
        }
        guard case let .object(targets)? = payload.project["targets"] else {
            throw ProjectSpecError.missingTargets
        }
        return ProjectSpec(targets: targets)
    }

    var targetNames: [String] {
        targets.keys.sorted()
    }

    func target(named targetName: String) -> [String: ProjectSpecValue]? {
        targets[targetName]?.object
    }

    func allTargetSettings(named targetName: String) -> [[String: ProjectSpecValue]]? {
        guard let settings = settings(named: targetName) else { return nil }
        let supportedKeys = Set(["base", "configs"])
        guard Set(settings.keys).isSubset(of: supportedKeys) else { return nil }
        var configurations = settings["base"]?.object.map { [$0] } ?? []
        if let configuredValues = settings["configs"]?.object?.values {
            let configured = configuredValues.compactMap(\.object)
            guard configured.count == configuredValues.count else { return nil }
            configurations.append(contentsOf: configured)
        }
        return configurations
    }

    private func settings(named targetName: String) -> [String: ProjectSpecValue]? {
        target(named: targetName)?["settings"]?.object
    }
}

private struct ProjectSpecPayload: Decodable, Sendable {
    let schemaVersion: Int
    let project: [String: ProjectSpecValue]
}

private enum ProjectSpecValue: Decodable, Sendable {
    case string(String)
    case bool(Bool)
    case number(Double)
    case object([String: ProjectSpecValue])
    case array([ProjectSpecValue])
    case null

    var string: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    var object: [String: ProjectSpecValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    var array: [ProjectSpecValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    var stringArray: [String]? {
        guard let array else { return nil }
        let values = array.compactMap(\.string)
        return values.count == array.count ? values : nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode([String: ProjectSpecValue].self) {
            self = .object(value)
        } else {
            self = .array(try container.decode([ProjectSpecValue].self))
        }
    }
}

private enum ProjectSpecError: Error, CustomStringConvertible, Sendable {
    case missingFile(String)
    case launchFailed(String)
    case timedOut(TimeInterval)
    case readerFailed(Int32, String)
    case invalidJSON(String)
    case unsupportedSchema(Int)
    case missingTargets
    case unexpected(String)

    var description: String {
        switch self {
        case let .missingFile(path):
            "Project specification input is missing: \(path)"
        case let .launchFailed(message):
            "Project specification reader could not launch: \(message)"
        case let .timedOut(timeout):
            "Project specification reader exceeded the \(timeout)-second deadline"
        case let .readerFailed(status, errorText):
            "Project specification reader exited with status \(status): \(errorText)"
        case let .invalidJSON(message):
            "Project specification reader returned invalid JSON: \(message)"
        case let .unsupportedSchema(version):
            "Project specification reader returned unsupported schema \(version)"
        case .missingTargets:
            "Project specification reader returned no targets"
        case let .unexpected(message):
            "Project specification reader failed unexpectedly: \(message)"
        }
    }
}
