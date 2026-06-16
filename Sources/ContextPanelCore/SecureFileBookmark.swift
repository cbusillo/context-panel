import Foundation

#if os(macOS)
public struct SecureFileBookmarkStore: Sendable {
    private static let currentBookmarkPrefix = "appScoped:"
    private static let documentScopedBookmarkPrefix = "documentScoped:"
    private let storeURL: URL

    public init(storeURL: URL) {
        self.storeURL = storeURL
    }

    public func bookmarkData(for path: String) -> Data? {
        guard let all = loadAll(), let value = all[path] else { return nil }
        return Self.decodeBookmarkData(value, relativeTo: storeURL)?.data
    }

    public func currentBookmarkData(for path: String) -> Data? {
        guard let all = loadAll() else { return nil }
        return all[path].flatMap(Self.decodeCurrentBookmarkData)
    }

    public func hasBookmark(for path: String) -> Bool {
        guard let all = loadAll(), let value = all[path] else { return false }
        return Self.decodeBookmarkData(value, relativeTo: storeURL) != nil
    }

    public func hasCurrentBookmark(for path: String) -> Bool {
        guard let all = loadAll(), let value = all[path] else { return false }
        return Self.decodeCurrentBookmarkData(value) != nil
    }

    public func canReadBookmark(for path: String) -> Bool {
        guard let bookmark = bookmark(for: path) else { return false }
        return SecureFileBookmark.canRead(bookmarkData: bookmark.data, relativeTo: bookmark.relativeURL)
    }

    public func canResolveBookmark(for path: String) -> Bool {
        guard let bookmark = bookmark(for: path) else { return false }
        return SecureFileBookmark.canResolve(bookmarkData: bookmark.data, relativeTo: bookmark.relativeURL)
    }

    public func canReadLegacyAppScopedBookmark(for path: String) -> Bool {
        guard let all = loadAll(),
              let value = all[path],
              let data = Data(base64Encoded: value)
        else { return false }
        return SecureFileBookmark.canReadLegacyAppScoped(bookmarkData: data)
    }

    public func createAndStoreBookmark(for fileURL: URL, path: String) throws {
        let data = try SecureFileBookmark.create(for: fileURL)
        try store(bookmarkData: data, for: path)
    }

    public func withResolvedURL<T>(for path: String, _ body: (URL) throws -> T) throws -> T? {
        guard let bookmark = bookmark(for: path) else { return nil }
        return try SecureFileBookmark.withResolvedURL(
            bookmarkData: bookmark.data,
            relativeTo: bookmark.relativeURL,
            body
        )
    }

    public func readData(for path: String) throws -> Data? {
        guard let bookmark = bookmark(for: path) else { return nil }
        return try SecureFileBookmark.read(bookmarkData: bookmark.data, relativeTo: bookmark.relativeURL).data
    }

    private func store(bookmarkData: Data, for path: String) throws {
        var all = loadAll() ?? [:]
        all[path] = Self.currentBookmarkPrefix + bookmarkData.base64EncodedString()
        try save(all)
    }

    private static func decodeCurrentBookmarkData(_ value: String) -> Data? {
        guard value.hasPrefix(currentBookmarkPrefix) else { return nil }
        return Data(base64Encoded: String(value.dropFirst(currentBookmarkPrefix.count)))
    }

    private func bookmark(for path: String) -> StoredBookmark? {
        guard let all = loadAll(), let value = all[path] else { return nil }
        return Self.decodeBookmarkData(value, relativeTo: storeURL)
    }

    private static func decodeBookmarkData(_ value: String, relativeTo storeURL: URL) -> StoredBookmark? {
        if let current = decodeCurrentBookmarkData(value) {
            return StoredBookmark(data: current, relativeURL: nil)
        }
        if value.hasPrefix(documentScopedBookmarkPrefix) {
            return Data(base64Encoded: String(value.dropFirst(documentScopedBookmarkPrefix.count))).map {
                StoredBookmark(data: $0, relativeURL: storeURL)
            }
        }
        return Data(base64Encoded: value).map {
            StoredBookmark(data: $0, relativeURL: nil)
        }
    }

    public func remove(for path: String) throws {
        guard var all = loadAll(), all[path] != nil else { return }
        all.removeValue(forKey: path)
        try save(all)
    }

    private func loadAll() -> [String: String]? {
        guard let data = try? Data(contentsOf: storeURL),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: String]
        else { return nil }
        return dict
    }

    private func save(_ dict: [String: String]) throws {
        let directory = storeURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys, .prettyPrinted])
        try data.write(to: storeURL, options: .atomic)
    }
}

private struct StoredBookmark {
    let data: Data
    let relativeURL: URL?
}

public enum SecureFileBookmark {
    public struct ReadResult: Sendable {
        public let data: Data
        public let resolvedURL: URL
        public let isStale: Bool
    }

    public static func create(for url: URL, relativeTo relativeURL: URL? = nil) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: relativeURL
        )
    }

    public static func readData(bookmarkData: Data, relativeTo relativeURL: URL? = nil) throws -> Data {
        try read(bookmarkData: bookmarkData, relativeTo: relativeURL).data
    }

    public static func read(bookmarkData: Data, relativeTo relativeURL: URL? = nil) throws -> ReadResult {
        try withResolvedURLResult(bookmarkData: bookmarkData, relativeTo: relativeURL) { url, isStale in
            let data = try Data(contentsOf: url)
            return ReadResult(data: data, resolvedURL: url, isStale: isStale)
        }
    }

    public static func withResolvedURL<T>(
        bookmarkData: Data,
        relativeTo relativeURL: URL? = nil,
        _ body: (URL) throws -> T
    ) throws -> T {
        try withResolvedURLResult(bookmarkData: bookmarkData, relativeTo: relativeURL) { url, _ in
            try body(url)
        }
    }

    private static func withResolvedURLResult<T>(
        bookmarkData: Data,
        relativeTo relativeURL: URL? = nil,
        _ body: (URL, Bool) throws -> T
    ) throws -> T {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            relativeTo: relativeURL,
            bookmarkDataIsStale: &isStale
        )
        guard url.startAccessingSecurityScopedResource() else {
            throw CocoaError(.fileReadNoPermission)
        }
        defer { url.stopAccessingSecurityScopedResource() }
        return try body(url, isStale)
    }

    public static func canRead(bookmarkData: Data, relativeTo relativeURL: URL? = nil) -> Bool {
        do {
            _ = try read(bookmarkData: bookmarkData, relativeTo: relativeURL)
            return true
        } catch {
            return false
        }
    }

    public static func canResolve(bookmarkData: Data, relativeTo relativeURL: URL? = nil) -> Bool {
        do {
            return try withResolvedURL(bookmarkData: bookmarkData, relativeTo: relativeURL) { url in
                FileManager.default.fileExists(atPath: url.path)
            }
        } catch {
            return false
        }
    }

    public static func canReadLegacyAppScoped(bookmarkData: Data) -> Bool {
        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            guard url.startAccessingSecurityScopedResource() else {
                return false
            }
            defer { url.stopAccessingSecurityScopedResource() }
            _ = try Data(contentsOf: url)
            return true
        } catch {
            return false
        }
    }
}
#else
public struct SecureFileBookmarkStore: Sendable {
    public init(storeURL: URL) {}

    public func bookmarkData(for path: String) -> Data? { nil }

    public func currentBookmarkData(for path: String) -> Data? { nil }

    public func hasBookmark(for path: String) -> Bool { false }

    public func hasCurrentBookmark(for path: String) -> Bool { false }

    public func canReadBookmark(for path: String) -> Bool { false }

    public func canResolveBookmark(for path: String) -> Bool { false }

    public func canReadLegacyAppScopedBookmark(for path: String) -> Bool { false }

    public func createAndStoreBookmark(for fileURL: URL, path: String) throws {
        throw CocoaError(.featureUnsupported)
    }

    public func withResolvedURL<T>(for path: String, _ body: (URL) throws -> T) throws -> T? { nil }

    public func readData(for path: String) throws -> Data? { nil }

    public func remove(for path: String) throws {}
}

public enum SecureFileBookmark {
    public struct ReadResult: Sendable {
        public let data: Data
        public let resolvedURL: URL
        public let isStale: Bool
    }

    public static func create(for url: URL, relativeTo relativeURL: URL? = nil) throws -> Data {
        throw CocoaError(.featureUnsupported)
    }

    public static func readData(bookmarkData: Data, relativeTo relativeURL: URL? = nil) throws -> Data {
        throw CocoaError(.fileReadNoPermission)
    }

    public static func read(bookmarkData: Data, relativeTo relativeURL: URL? = nil) throws -> ReadResult {
        throw CocoaError(.fileReadNoPermission)
    }

    public static func withResolvedURL<T>(
        bookmarkData: Data,
        relativeTo relativeURL: URL? = nil,
        _ body: (URL) throws -> T
    ) throws -> T {
        throw CocoaError(.fileReadNoPermission)
    }

    public static func canRead(bookmarkData: Data, relativeTo relativeURL: URL? = nil) -> Bool { false }

    public static func canResolve(bookmarkData: Data, relativeTo relativeURL: URL? = nil) -> Bool { false }

    public static func canReadLegacyAppScoped(bookmarkData: Data) -> Bool { false }
}
#endif
