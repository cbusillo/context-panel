import Foundation
import Testing

@testable import ContextPanelCore

#if os(macOS)
@Test func bookmarkStoreRenewsStaleBookmarkAfterAtomicReplacement() throws {
    let root = try secureBookmarkTemporaryDirectory()
    let fileURL = root.appending(path: "auth.json")
    let storeURL = root.appending(path: "bookmarks.json")
    let store = SecureFileBookmarkStore(storeURL: storeURL)
    try Data("first".utf8).write(to: fileURL)
    try store.createAndStoreBookmark(for: fileURL, path: fileURL.path)
    let originalBookmark = try #require(store.currentBookmarkData(for: fileURL.path))

    try Data("second".utf8).write(to: fileURL, options: .atomic)
    let staleStoreData = try Data(contentsOf: storeURL)

    #expect(store.accessSummary().resolvable == 1)
    #expect(try Data(contentsOf: storeURL) == staleStoreData)

    #expect(try store.readData(for: fileURL.path) == Data("second".utf8))
    let renewedBookmark = try #require(store.currentBookmarkData(for: fileURL.path))
    #expect(renewedBookmark != originalBookmark)
    #expect(try SecureFileBookmark.read(bookmarkData: renewedBookmark).isStale == false)
}

@Test func bookmarkStoreClassifiesDocumentScopedEntryWithoutRewriting() throws {
    let root = try secureBookmarkTemporaryDirectory()
    let fileURL = root.appending(path: "auth.json")
    let storeURL = root.appending(path: "bookmarks.json")
    let bookmarkData = Data([0x01, 0x02, 0x03])
    let storedValue = "documentScoped:" + bookmarkData.base64EncodedString()
    try JSONSerialization.data(
        withJSONObject: [fileURL.path: storedValue],
        options: [.sortedKeys]
    ).write(to: storeURL, options: .atomic)
    let store = SecureFileBookmarkStore(storeURL: storeURL)
    let originalData = try Data(contentsOf: storeURL)

    let summary = store.accessSummary()

    #expect(summary.documentScoped == 1)
    #expect(summary.resolvable == 0)
    #expect(try Data(contentsOf: storeURL) == originalData)
}

@Test func bookmarkStoreCanReadStaleBookmarkWithoutRenewingForHelperIdentity() throws {
    let root = try secureBookmarkTemporaryDirectory()
    let fileURL = root.appending(path: "auth.json")
    let storeURL = root.appending(path: "bookmarks.json")
    let authorizingStore = SecureFileBookmarkStore(storeURL: storeURL)
    try Data("first".utf8).write(to: fileURL)
    try authorizingStore.createAndStoreBookmark(for: fileURL, path: fileURL.path)
    try Data("second".utf8).write(to: fileURL, options: .atomic)
    let staleStoreData = try Data(contentsOf: storeURL)
    let helperStore = SecureFileBookmarkStore(
        storeURL: storeURL,
        renewsStaleBookmarks: false
    )

    #expect(try helperStore.readData(for: fileURL.path) == Data("second".utf8))
    #expect(try Data(contentsOf: storeURL) == staleStoreData)
}

@Test func bookmarkStoreReadsStaleBookmarkWhenRenewalCannotPersist() throws {
    let root = try secureBookmarkTemporaryDirectory()
    let fileURL = root.appending(path: "auth.json")
    let storeURL = root.appending(path: "bookmarks.json")
    let store = SecureFileBookmarkStore(storeURL: storeURL)
    try Data("first".utf8).write(to: fileURL)
    try store.createAndStoreBookmark(for: fileURL, path: fileURL.path)
    try Data("second".utf8).write(to: fileURL, options: .atomic)
    let staleStoreData = try Data(contentsOf: storeURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    }

    #expect(try store.readData(for: fileURL.path) == Data("second".utf8))
    #expect(try Data(contentsOf: storeURL) == staleStoreData)
}

@Test func staleRenewalDoesNotOverwriteConcurrentReauthorization() throws {
    let root = try secureBookmarkTemporaryDirectory()
    let originalFile = root.appending(path: "original.json")
    let replacementFile = root.appending(path: "replacement.json")
    let storeURL = root.appending(path: "bookmarks.json")
    let configuredPath = root.appending(path: "configured.json").path
    let store = SecureFileBookmarkStore(storeURL: storeURL)
    try Data("original".utf8).write(to: originalFile)
    try Data("replacement".utf8).write(to: replacementFile)
    try store.createAndStoreBookmark(for: originalFile, path: configuredPath)
    try Data("updated-original".utf8).write(to: originalFile, options: .atomic)

    let resolvedData = try store.withResolvedURL(for: configuredPath) { resolvedURL in
        let data = try Data(contentsOf: resolvedURL)
        try store.createAndStoreBookmark(for: replacementFile, path: configuredPath)
        return data
    }

    #expect(resolvedData == Data("updated-original".utf8))
    #expect(try store.readData(for: configuredPath) == Data("replacement".utf8))
}

@Test func bookmarkStoreReauthorizationReplacesLegacyEntryAndPreservesSibling() throws {
    let root = try secureBookmarkTemporaryDirectory()
    let firstFile = root.appending(path: "first.json")
    let secondFile = root.appending(path: "second.json")
    let storeURL = root.appending(path: "bookmarks.json")
    try Data("first".utf8).write(to: firstFile)
    try Data("second".utf8).write(to: secondFile)
    let firstLegacyBookmark = try SecureFileBookmark.create(for: firstFile)
    let secondBookmark = try SecureFileBookmark.create(for: secondFile)
    let secondStoredValue = "appScoped:" + secondBookmark.base64EncodedString()
    let seeded = [
        firstFile.path: firstLegacyBookmark.base64EncodedString(),
        secondFile.path: secondStoredValue,
    ]
    try JSONSerialization.data(withJSONObject: seeded, options: [.sortedKeys])
        .write(to: storeURL, options: .atomic)
    let store = SecureFileBookmarkStore(storeURL: storeURL)

    try store.createAndStoreBookmark(for: firstFile, path: firstFile.path)

    let savedData = try Data(contentsOf: storeURL)
    let saved = try #require(try JSONSerialization.jsonObject(with: savedData) as? [String: String])
    #expect(saved[firstFile.path]?.hasPrefix("appScoped:") == true)
    #expect(saved[secondFile.path] == secondStoredValue)
    #expect(store.hasReadableCurrentBookmark(for: firstFile.path))
    #expect(store.hasReadableCurrentBookmark(for: secondFile.path))
}

@Test func bookmarkStoreReportsBrokenCurrentBookmarkWithoutExposingPaths() throws {
    let root = try secureBookmarkTemporaryDirectory()
    let fileURL = root.appending(path: "auth.json")
    let store = SecureFileBookmarkStore(storeURL: root.appending(path: "bookmarks.json"))
    try Data("contents".utf8).write(to: fileURL)
    try store.createAndStoreBookmark(for: fileURL, path: fileURL.path)
    try FileManager.default.removeItem(at: fileURL)

    #expect(store.hasCurrentBookmark(for: fileURL.path))
    #expect(store.hasReadableCurrentBookmark(for: fileURL.path) == false)
    #expect(store.accessSummary() == SecureFileBookmarkAccessSummary(
        storeExists: true,
        total: 1,
        current: 1,
        resolvable: 0
    ))
}

@Test func bookmarkStoreQuarantinesCorruptStoreDuringReauthorization() throws {
    let root = try secureBookmarkTemporaryDirectory()
    let fileURL = root.appending(path: "auth.json")
    let storeURL = root.appending(path: "bookmarks.json")
    let corruptData = Data("not-json".utf8)
    try Data("contents".utf8).write(to: fileURL)
    try corruptData.write(to: storeURL)
    let store = SecureFileBookmarkStore(storeURL: storeURL)

    #expect(store.accessSummary() == SecureFileBookmarkAccessSummary(
        storeExists: true,
        storeReadable: false
    ))
    try store.createAndStoreBookmark(for: fileURL, path: fileURL.path)

    #expect(store.hasReadableCurrentBookmark(for: fileURL.path))
    #expect(store.accessSummary().total == 1)
    let quarantinedURLs = try FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: nil
    ).filter { $0.lastPathComponent.hasPrefix("bookmarks.json.corrupt-") }
    #expect(quarantinedURLs.count == 1)
    #expect(try Data(contentsOf: #require(quarantinedURLs.first)) == corruptData)
}

@Test func concurrentBookmarkWritesPreserveEveryEntry() throws {
    let root = try secureBookmarkTemporaryDirectory()
    let store = SecureFileBookmarkStore(storeURL: root.appending(path: "bookmarks.json"))
    let fileURLs = try (0..<24).map { index in
        let fileURL = root.appending(path: "auth-\(index).json")
        try Data("contents-\(index)".utf8).write(to: fileURL)
        return fileURL
    }
    let errors = BookmarkWriteErrorRecorder()

    DispatchQueue.concurrentPerform(iterations: fileURLs.count) { index in
        do {
            try store.createAndStoreBookmark(for: fileURLs[index], path: fileURLs[index].path)
        } catch {
            errors.record(error)
        }
    }

    #expect(errors.count == 0)
    #expect(store.accessSummary().total == fileURLs.count)
}

private func secureBookmarkTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
        path: "context-panel-bookmark-tests-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private final class BookmarkWriteErrorRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var errors: [Error] = []

    var count: Int {
        lock.withLock { errors.count }
    }

    func record(_ error: Error) {
        lock.withLock { errors.append(error) }
    }
}
#endif
