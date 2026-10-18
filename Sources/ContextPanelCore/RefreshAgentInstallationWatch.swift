import Darwin
import Foundation

/// The file a process was launched from, identified by device and inode.
public struct ExecutableFileIdentity: Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64

    public init(device: UInt64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }

    public static func current(atPath path: String) -> ExecutableFileIdentity? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return ExecutableFileIdentity(device: UInt64(bitPattern: Int64(info.st_dev)), inode: UInt64(info.st_ino))
    }
}

/// App Store and TestFlight updates replace the app bundle and stop the app, but
/// leave its login item running from the replaced files. The helper notices the
/// new executable at its launch path and exits between refreshes, so launchd
/// starts the installed copy.
public struct RefreshAgentInstallationWatch: Sendable {
    /// launchd restarts the login item after an unsuccessful exit (`EX_TEMPFAIL`).
    public static let replacedInstallationExitCode: Int32 = 75
    public static let defaultCheckInterval: TimeInterval = 60

    public typealias Sleep = @Sendable (TimeInterval) async throws -> Void

    private let launchIdentity: ExecutableFileIdentity?
    private let currentIdentity: @Sendable () -> ExecutableFileIdentity?
    private let checkInterval: TimeInterval
    private let sleep: Sleep

    public init(
        launchIdentity: ExecutableFileIdentity?,
        currentIdentity: @escaping @Sendable () -> ExecutableFileIdentity?,
        checkInterval: TimeInterval = defaultCheckInterval,
        sleep: @escaping Sleep = { seconds in try await Task.sleep(for: .seconds(seconds)) }
    ) {
        self.launchIdentity = launchIdentity
        self.currentIdentity = currentIdentity
        self.checkInterval = checkInterval
        self.sleep = sleep
    }

    public static func appDefault(executablePath: String?) -> RefreshAgentInstallationWatch {
        let launchIdentity = executablePath.flatMap(ExecutableFileIdentity.current(atPath:))
        return RefreshAgentInstallationWatch(
            launchIdentity: launchIdentity,
            currentIdentity: { executablePath.flatMap(ExecutableFileIdentity.current(atPath:)) }
        )
    }

    /// A missing file is treated as not replaced: the installer may be between
    /// moving the old bundle away and placing the new one.
    public var installationWasReplaced: Bool {
        guard let launchIdentity, let current = currentIdentity() else { return false }
        return current != launchIdentity
    }

    /// Sleeps until the next refresh, checking the installation between short
    /// sleeps. Returns true as soon as the installation was replaced.
    public func sleepUntilNextRefresh(seconds: TimeInterval) async throws -> Bool {
        var remaining = max(seconds, 0)
        while remaining > 0 {
            if installationWasReplaced { return true }
            let step = min(remaining, checkInterval)
            try await sleep(step)
            remaining -= step
        }
        return installationWasReplaced
    }
}
