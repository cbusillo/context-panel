import Foundation
import Darwin

/// Only normalized counts are persisted here. Session text and provider IDs never
/// enter the app group. Native Codex sessions use bounded JSONL reads.
/// Historical normalized Lab mirrors remain decodable.
struct CodexTelemetryMirror: Codable {
    var observations: [PromptCacheObservation]
    var baselines: [String: Baseline]
    var refreshedAt: Date? = nil

    struct Baseline: Codable {
        let sampledAt: Date
        let input: Int
        let cached: Int?
    }

    static func write(source: URL, sourceIDPath: String, client: CodexClient?, target: URL, now: Date, fileManager: FileManager) throws {
        try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lock = target.deletingLastPathComponent().appending(path: ".telemetry.lock")
        let descriptor = open(lock.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw CocoaError(.fileLocking) }
        defer { flock(descriptor, LOCK_UN) }
        let previous = (try? Data(contentsOf: target)).flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
        // A refresh that started earlier must not roll back a newer writer.
        guard previous?.refreshedAt.map({ $0 <= now }) ?? true else { return }
        var mirror: Self
        if client?.isRetired == true {
            mirror = Self(observations: [], baselines: [:])
        } else {
            mirror = Self(
                observations: CodexSessionTelemetryReader.observations(
                    rootDirectory: source,
                    client: client ?? .codex,
                    now: now,
                    fileManager: fileManager
                ),
                baselines: [:]
            )
        }
        mirror.refreshedAt = now
        try JSONEncoder().encode(mirror).write(to: target, options: .atomic)
    }

}
