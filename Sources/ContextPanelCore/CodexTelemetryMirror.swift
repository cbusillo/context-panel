import Foundation
import Darwin

/// Only normalized counts are persisted here. Session text and provider IDs never
/// enter the app group, and a Lab lifetime counter is never a recent observation.
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
        if client == .codexLab {
            mirror = try lab(source: source, sourceIDPath: sourceIDPath, previous: previous, now: now, fileManager: fileManager)
        } else {
            mirror = Self(observations: CodexSessionTelemetryReader.observations(rootDirectory: source, now: now, fileManager: fileManager), baselines: [:])
        }
        mirror.refreshedAt = now
        try JSONEncoder().encode(mirror).write(to: target, options: .atomic)
    }

    static func lab(
        source: URL,
        sourceIDPath: String,
        previous: Self?,
        now: Date,
        fileManager: FileManager
    ) throws -> Self {
        let files = try fileManager.contentsOfDirectory(
            at: source, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        let maximumAge = PromptCacheSummary.defaultMaximumAge
        var result = Self(observations: [], baselines: [:])
        var presentAccounts = Set<String>()
        for (index, file) in files.filter({ $0.pathExtension == "json" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).prefix(256).enumerated() {
            let accountID = ConnectorRedactor.localAccountID(
                provider: .openAI, path: sourceIDPath + "/" + file.lastPathComponent
            )
            presentAccounts.insert(accountID)
            guard file.pathExtension == "json",
                  let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size <= 1_048_576,
                  let data = try? Data(contentsOf: file),
                  let sample = try? JSONDecoder().decode(LabSample.self, from: data),
                  let updatedAt = ContextPanelDateFormatting.date(from: sample.lastUpdated),
                  updatedAt <= now, now.timeIntervalSince(updatedAt) <= maximumAge,
                  sample.totals.inputTokens >= 0, sample.totals.inputTokens <= 1_000_000_000_000,
                  sample.totals.cachedInputTokens.map({ $0 >= 0 && $0 <= sample.totals.inputTokens }) ?? true
            else { continue }
            let baseline = Baseline(sampledAt: now, input: sample.totals.inputTokens, cached: sample.totals.cachedInputTokens)
            result.baselines[accountID] = baseline
            guard let old = previous?.baselines[accountID], old.sampledAt <= now,
                  now.timeIntervalSince(old.sampledAt) <= maximumAge,
                  baseline.input >= old.input,
                  baseline.cached.flatMap({ value in old.cached.map { value >= $0 } }) ?? true
            else { continue }
            let delta = baseline.input - old.input
            if delta > 0 {
                let cached = baseline.cached.flatMap { value in old.cached.map { value - $0 } }
                guard cached.map({ $0 <= delta }) ?? true else { continue }
                result.observations.append(PromptCacheObservation(
                    provider: .openAI, accountID: accountID, accountName: "Codex Lab · Account \(index + 1)",
                    observedAt: now, windowLabel: "Since refresh",
                    tokens: PromptCacheTokenSet(inputTokens: delta, cachedInputTokens: cached),
                    measurement: .increment
                ))
            }
        }
        // Retain distinct measured intervals for the bounded recent average.
        result.observations += PromptCacheTelemetryReader.filteredRecentObservations(previous?.observations ?? [], now: now)
            .filter { presentAccounts.contains($0.accountID) }
        result.observations = Array(result.observations.sorted { $0.observedAt > $1.observedAt }.prefix(2_048))
        return result
    }

    private struct LabSample: Decodable {
        let lastUpdated: String
        let totals: Totals
        enum CodingKeys: String, CodingKey { case lastUpdated = "last_updated", totals }
        struct Totals: Decodable {
            let inputTokens: Int
            let cachedInputTokens: Int?
            enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens", cachedInputTokens = "cached_input_tokens"
            }
        }
    }
}
