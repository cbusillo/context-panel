import Foundation
import Testing

@testable import ContextPanelCore

private final class ScriptedInstallation: @unchecked Sendable {
    private let lock = NSLock()
    private var identity: ExecutableFileIdentity?
    private var sleeps: [TimeInterval] = []
    private var replaceAfterSleepCount: Int?

    init(identity: ExecutableFileIdentity?, replaceAfterSleepCount: Int? = nil) {
        self.identity = identity
        self.replaceAfterSleepCount = replaceAfterSleepCount
    }

    var current: ExecutableFileIdentity? {
        lock.withLock { identity }
    }

    var sleptSeconds: [TimeInterval] {
        lock.withLock { sleeps }
    }

    func sleep(_ seconds: TimeInterval) {
        lock.withLock {
            sleeps.append(seconds)
            if sleeps.count == replaceAfterSleepCount {
                identity = ExecutableFileIdentity(device: 1, inode: 99)
            }
        }
    }
}

private let launchedIdentity = ExecutableFileIdentity(device: 1, inode: 42)

private func makeWatch(_ installation: ScriptedInstallation) -> RefreshAgentInstallationWatch {
    RefreshAgentInstallationWatch(
        launchIdentity: launchedIdentity,
        currentIdentity: { installation.current },
        checkInterval: 60,
        sleep: { seconds in installation.sleep(seconds) }
    )
}

@Test func refreshAgentSleepsTheWholeIntervalWhileTheInstallationIsUnchanged() async throws {
    let installation = ScriptedInstallation(identity: launchedIdentity)

    let replaced = try await makeWatch(installation).sleepUntilNextRefresh(seconds: 150)

    #expect(!replaced)
    #expect(installation.sleptSeconds == [60, 60, 30])
}

@Test func refreshAgentStopsSleepingSoonAfterTheAppIsReplaced() async throws {
    let installation = ScriptedInstallation(identity: launchedIdentity, replaceAfterSleepCount: 2)

    let replaced = try await makeWatch(installation).sleepUntilNextRefresh(seconds: 900)

    #expect(replaced)
    #expect(installation.sleptSeconds == [60, 60])
}

@Test func refreshAgentKeepsRunningWhileItsExecutableIsMissingMidInstall() async throws {
    let installation = ScriptedInstallation(identity: nil)

    let replaced = try await makeWatch(installation).sleepUntilNextRefresh(seconds: 120)

    #expect(!replaced)
    #expect(installation.sleptSeconds == [60, 60])
}

@Test func executableIdentityChangesWhenTheFileIsReplacedAtTheSamePath() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "installation-watch-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = directory.appending(path: "ContextPanelRefreshAgent")
    try Data("old".utf8).write(to: executable)
    let watch = RefreshAgentInstallationWatch.appDefault(executablePath: executable.path)
    #expect(!watch.installationWasReplaced)

    try Data("new".utf8).write(to: executable, options: [.atomic])

    #expect(watch.installationWasReplaced)
}
