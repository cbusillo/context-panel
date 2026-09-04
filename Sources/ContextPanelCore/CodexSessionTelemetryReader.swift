import CryptoKit
import Darwin
import Foundation

/// Reads a bounded sample of local Codex session usage, never account credentials.
/// `rootDirectory` is the `sessions` directory, not the Codex home directory.
/// Large/old session trees and truncated tails can undercount usage. A first total
/// is a baseline unless its last-turn counters prove that it contains one turn.
/// Identical timestamp/counter events from unrelated sessions are conservatively
/// coalesced; these observations are a recent sample, not an account billing total.
/// Discovery checks today, tomorrow, direct-root files, then the preceding 365 UTC
/// date directories newest first. It visits at most 8,192 direct
/// children before choosing the 64 newest files by
/// modification time. Sessions created before that horizon can be omitted even
/// when resumed recently. Reads cover at most 8 MiB total / 256 KiB per file,
/// with 64 KiB lines and 2,048 output observations.
public enum CodexSessionTelemetryReader {
    static let maximumCalendarDays = 366
    static let maximumEntries = 8_192
    static let maximumFiles = 64
    static let maximumFileBytes = 256 * 1_024
    static let maximumTotalBytes = 8 * 1_024 * 1_024
    static let maximumLineBytes = 64 * 1_024
    static let maximumObservations = 2_048

    public static func observations(
        rootDirectory: URL,
        now: Date = Date(),
        maximumAge: TimeInterval = PromptCacheSummary.defaultMaximumAge,
        fileManager: FileManager = .default
    ) -> [PromptCacheObservation] {
        guard maximumAge.isFinite, maximumAge >= 0 else { return [] }
        var remainingBytes = maximumTotalBytes
        var result: [PromptCacheObservation] = []
        var seen = Set<String>()
        let decoder = JSONDecoder()
        let fractionalDate = ISO8601DateFormatter()
        fractionalDate.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plainDate = ISO8601DateFormatter()

        for url in sessionFiles(rootDirectory: rootDirectory, now: now, fileManager: fileManager) {
            guard remainingBytes > 0, result.count < maximumObservations else { break }
            guard let tail = readTail(url, byteLimit: min(maximumFileBytes, remainingBytes)) else { continue }
            remainingBytes -= tail.bytesRead
            var previous: Counters?
            var previousDate: Date?
            var first = true
            for line in tail.data.split(separator: 0x0A, omittingEmptySubsequences: false) {
                defer { first = false }
                // The first tail fragment and unfinished final JSONL row are not records.
                if first && tail.truncated { continue }
                guard line.count <= maximumLineBytes,
                      let envelope = try? decoder.decode(Envelope.self, from: Data(line)),
                      envelope.type == "event_msg", envelope.payload.type == "token_count",
                      let timestamp = fractionalDate.date(from: envelope.timestamp)
                        ?? plainDate.date(from: envelope.timestamp),
                      timestamp <= now,
                      previousDate.map({ timestamp >= $0 }) ?? true,
                      let current = envelope.payload.info?.totalTokenUsage,
                      current.isValid
                else { continue }

                let baseline = previous ?? initialBaseline(
                    current: current,
                    last: envelope.payload.info?.lastTokenUsage,
                    truncated: tail.truncated
                )
                previous = current
                previousDate = timestamp
                guard let baseline, current.inputTokens > baseline.inputTokens,
                      now.timeIntervalSince(timestamp) <= maximumAge else { continue }
                let input = current.inputTokens - baseline.inputTokens
                let cached: Int?
                if let currentCached = current.cachedInputTokens,
                   let previousCached = baseline.cachedInputTokens,
                   currentCached >= previousCached, currentCached - previousCached <= input {
                    cached = currentCached - previousCached
                } else {
                    cached = nil
                }
                // Copied/resumed/forked histories retain the event timestamp and
                // counters. Deduplicate those events across files without exposing
                // thread IDs or guessing which current login produced old usage.
                let fingerprint = "\(timestamp.timeIntervalSince1970):\(baseline.inputTokens):"
                    + "\(current.inputTokens):\(baseline.cachedInputTokens.map(String.init) ?? "?"):"
                    + "\(current.cachedInputTokens.map(String.init) ?? "?")"
                let digest = SHA256.hash(data: Data(fingerprint.utf8))
                    .map { String(format: "%02x", $0) }.joined()
                let id = "codex-session:\(digest)"
                guard seen.insert(id).inserted else { continue }
                result.append(PromptCacheObservation(
                    id: id,
                    provider: .openAI,
                    accountID: "codex-session-unattributed",
                    accountName: "Codex · Account unknown",
                    observedAt: timestamp,
                    windowLabel: "Session increment",
                    tokens: PromptCacheTokenSet(inputTokens: input, cachedInputTokens: cached),
                    measurement: .increment
                ))
                if result.count >= maximumObservations { break }
            }
        }
        return result.sorted {
            if $0.observedAt != $1.observedAt { return $0.observedAt > $1.observedAt }
            return $0.id < $1.id
        }
    }

    private static func initialBaseline(current: Counters, last: Counters?, truncated: Bool) -> Counters? {
        guard !truncated, let last, last.isValid,
              current.inputTokens == last.inputTokens,
              current.cachedInputTokens == last.cachedInputTokens else { return nil }
        return Counters(inputTokens: 0, cachedInputTokens: current.cachedInputTokens == nil ? nil : 0)
    }

    private static func sessionFiles(rootDirectory: URL, now: Date, fileManager: FileManager) -> [URL] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard let rootValues = try? rootDirectory.resourceValues(forKeys: keys),
              rootValues.isDirectory == true, rootValues.isSymbolicLink != true else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = calendar.startOfDay(for: now)
        var candidates: [(url: URL, modified: Date)] = []
        var entries = 0
        var checkedDirectories: [String: Bool] = [:]
        func collectFiles(in directory: URL) {
            guard let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants, .skipsPackageDescendants]
            ) else { return }
            // Direct-child enumeration avoids path-depth arithmetic, including
            // when Foundation canonicalizes an ancestor alias (/var, for example).
            while entries < maximumEntries, let url = enumerator.nextObject() as? URL {
                entries += 1
                guard url.pathExtension == "jsonl",
                      let values = try? url.resourceValues(forKeys: keys),
                      values.isSymbolicLink != true, values.isRegularFile == true else { continue }
                candidates.append((url, values.contentModificationDate ?? .distantPast))
            }
        }
        // Address calendar buckets directly: neither a large old subtree nor
        // filesystem enumeration order can hide today's directory. Visit today
        // before tomorrow so an oversized future bucket cannot spend its budget.
        // Tomorrow covers clients whose local calendar is ahead of UTC.
        let offsets = [0, 1] + Array(stride(from: -1, through: -(maximumCalendarDays - 1), by: -1))
        for offset in offsets {
            if offset == -1 { collectFiles(in: rootDirectory) }
            guard entries < maximumEntries else { break }
            guard let date = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            let components = calendar.dateComponents([.year, .month, .day], from: date)
            guard let year = components.year, let month = components.month, let day = components.day else { continue }
            var directory = rootDirectory
            var readable = true
            for component in [String(format: "%04d", year), String(format: "%02d", month), String(format: "%02d", day)] {
                directory.appendPathComponent(component, isDirectory: true)
                let allowed: Bool
                if let cached = checkedDirectories[directory.path] {
                    allowed = cached
                } else {
                    let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    allowed = values?.isDirectory == true && values?.isSymbolicLink != true
                    checkedDirectories[directory.path] = allowed
                }
                if !allowed { readable = false; break }
            }
            if readable { collectFiles(in: directory) }
        }
        return candidates.sorted {
            if $0.modified != $1.modified { return $0.modified > $1.modified }
            return $0.url.path < $1.url.path
        }.prefix(maximumFiles).map(\.url)
    }

    private static func readTail(_ url: URL, byteLimit: Int) -> (data: Data, truncated: Bool, bytesRead: Int)? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size > 0 else { return nil }
        let offset = max(Int64(info.st_size) - Int64(byteLimit), 0)
        do {
            try handle.seek(toOffset: UInt64(offset))
            guard var data = try handle.read(upToCount: byteLimit) else { return nil }
            let bytesRead = data.count
            // Only newline-terminated records are committed. This also handles a
            // writer appending while the file is read, without retries or locks.
            if let lastNewline = data.lastIndex(of: 0x0A) {
                data = Data(data[...lastNewline])
            } else {
                data = Data()
            }
            return (data, offset > 0, bytesRead)
        } catch {
            return nil
        }
    }

    private struct Envelope: Decodable {
        let timestamp: String
        let type: String
        let payload: Payload
    }

    private struct Payload: Decodable {
        let type: String
        let info: Usage?
    }

    private struct Usage: Decodable {
        let totalTokenUsage: Counters?
        let lastTokenUsage: Counters?

        enum CodingKeys: String, CodingKey {
            case totalTokenUsage = "total_token_usage"
            case lastTokenUsage = "last_token_usage"
        }
    }

    private struct Counters: Decodable {
        let inputTokens: Int
        let cachedInputTokens: Int?

        var isValid: Bool {
            inputTokens >= 0 && inputTokens <= 1_000_000_000_000
                && (cachedInputTokens.map { $0 >= 0 && $0 <= inputTokens } ?? true)
        }

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case cachedInputTokens = "cached_input_tokens"
        }
    }
}
