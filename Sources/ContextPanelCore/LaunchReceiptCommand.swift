import Foundation

/// Writes one launch receipt for a launcher that macOS refuses the App Group (#873).
/// The installed app's own entitlement covers the store, so no other process needs a grant.
public enum LaunchReceiptCommand {
    public struct Result: Sendable {
        public let exitCode: Int32
        public let standardOutput: Data
        public let standardError: Data
    }

    static let receiptKeys: Set<String> = ["schemaVersion", "provider", "accountID", "launchedAt"]
    static let launcherPattern = "^[a-z0-9]{1,32}$"

    /// Reads at most this many bytes, so oversized input is rejected without reading all of it.
    public static let inputLimit = LaunchReceiptStore.maximumFileBytes + 1

    public static func run(arguments: [String], input: () -> Data, rootDirectory: URL, now: Date = Date()) -> Result {
        if arguments == ["--help"] {
            return Result(exitCode: 0, standardOutput: Data(
                """
                usage: "/Applications/Context Panel.app/Contents/MacOS/Context Panel" --record-launch --launcher <token> < receipt.json
                Reads one schema 1 launch receipt on stdin and prints the stored file name.

                """.utf8
            ), standardError: Data())
        }
        guard arguments.count == 2, arguments[0] == "--launcher",
              arguments[1].range(of: launcherPattern, options: .regularExpression) != nil else {
            return failure(64, "Invalid arguments; use --help.")
        }
        let launcher = arguments[1]

        let data = input()
        guard data.count <= LaunchReceiptStore.maximumFileBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == receiptKeys,
              let receipt = try? JSONDecoder.contextPanelISO8601.decode(LaunchReceipt.self, from: data),
              LaunchReceiptStore.isUsable(receipt, now: now) else {
            return failure(64, "Invalid launch receipt; see the launch receipt contract.")
        }

        let directory = rootDirectory.appending(path: LaunchReceiptStore.directoryName)
        let name = "\(fileTimestamp(receipt.launchedAt))-\(launcher)-\(randomHex()).json"
        let temporary = directory.appending(path: ".\(launcher)-\(randomHex()).tmp")
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let encoded = try encoder.encode(receipt)
            // Only the receipt directory is created; a missing storage root stays an error.
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700])
            } catch CocoaError.fileWriteFileExists {}
            prune(directory: directory, launcher: launcher, now: now)
            try encoded.write(to: temporary)
            try FileManager.default.moveItem(at: temporary, to: directory.appending(path: name))
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            return failure(1, "Launch receipt storage unavailable: \(reason(error)).")
        }
        return Result(exitCode: 0, standardOutput: Data("\(name)\n".utf8), standardError: Data())
    }

    /// Deletes only this launcher's own receipts once they are a day old; other launchers' files stay.
    static func prune(directory: URL, launcher: String, now: Date) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        let own = "^[0-9]{8}T[0-9]{6}Z-\(launcher)-[0-9a-f]+\\.json$"
        for name in names where name.range(of: own, options: .regularExpression) != nil {
            let url = directory.appending(path: name)
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size <= LaunchReceiptStore.maximumFileBytes,
                  let data = try? Data(contentsOf: url),
                  let receipt = try? JSONDecoder.contextPanelISO8601.decode(LaunchReceipt.self, from: data),
                  now.timeIntervalSince(receipt.launchedAt) >= LaunchReceiptStore.lookback else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func fileTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    static func randomHex() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// The system's reason without the path, which may be private.
    static func reason(_ error: Error) -> String {
        let nsError = error as NSError
        let posix = nsError.domain == NSPOSIXErrorDomain ? nsError
            : nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        if let posix, posix.domain == NSPOSIXErrorDomain, let message = strerror(Int32(posix.code)) {
            return String(cString: message)
        }
        return "\(nsError.domain) \(nsError.code)"
    }

    static func failure(_ code: Int32, _ message: String) -> Result {
        Result(exitCode: code, standardOutput: Data(), standardError: Data("\(message)\n".utf8))
    }
}
