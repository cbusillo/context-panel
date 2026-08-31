@testable import ContextPanelCore
import Foundation
import Testing

@Test func companionCloudKitUserScopeIsStableDistinctAndNonReversible() {
    let recordName = "_private-user-record-name"
    let first = CompanionCloudKitUserScope.derive(
        containerIdentifier: "iCloud.com.example.context-panel",
        userRecordName: recordName
    )
    let repeated = CompanionCloudKitUserScope.derive(
        containerIdentifier: "iCloud.com.example.context-panel",
        userRecordName: recordName
    )
    let otherUser = CompanionCloudKitUserScope.derive(
        containerIdentifier: "iCloud.com.example.context-panel",
        userRecordName: "other-user"
    )
    let otherContainer = CompanionCloudKitUserScope.derive(
        containerIdentifier: "iCloud.com.example.other",
        userRecordName: recordName
    )

    #expect(first == repeated)
    #expect(first != otherUser)
    #expect(first != otherContainer)
    #expect(first.rawValue.count == 64)
    #expect(first.rawValue.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    #expect(!first.rawValue.contains(recordName))
}

@Test func companionCloudKitUserScopeRejectsMalformedSerializedValues() {
    #expect(CompanionCloudKitUserScope(rawValue: String(repeating: "a", count: 64)) != nil)
    #expect(CompanionCloudKitUserScope(rawValue: String(repeating: "A", count: 64)) == nil)
    #expect(CompanionCloudKitUserScope(rawValue: String(repeating: "z", count: 64)) == nil)
    #expect(CompanionCloudKitUserScope(rawValue: String(repeating: "a", count: 63)) == nil)
}

@Test func companionCloudKitUserScopeStateStoreRoundTripsClearsAndRejectsCorruption() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "context-panel-user-scope-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let stateURL = root.appending(path: "cloudkit-user-scope.json")
    let store = CompanionCloudKitUserScopeStateStore(stateURL: stateURL)
    let scope = CompanionCloudKitUserScope.derive(
        containerIdentifier: "iCloud.com.example.context-panel",
        userRecordName: "user-a"
    )

    #expect(store.load() == nil)
    try store.save(scope, updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
    #expect(store.load() == scope)
    try Data("not-json".utf8).write(to: stateURL, options: .atomic)
    #expect(store.load() == nil)
    try store.clear()
    #expect(!FileManager.default.fileExists(atPath: stateURL.path))
}

@Test func companionSyncStorePurgesLegacyAndForeignUsageDocuments() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "context-panel-scoped-store-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let documentURL = root.appending(path: "companion.json")
    let store = CompanionSyncStore(documentURL: documentURL)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let scopeA = CompanionCloudKitUserScope.derive(
        containerIdentifier: "iCloud.com.example.context-panel",
        userRecordName: "user-a"
    )
    let scopeB = CompanionCloudKitUserScope.derive(
        containerIdentifier: "iCloud.com.example.context-panel",
        userRecordName: "user-b"
    )
    let legacy = CompanionSyncDocument(
        snapshot: CompanionSnapshot(
            generatedAt: now,
            publishedAt: now,
            limits: [],
            providerStatuses: [],
            promptCacheSummaries: []
        )
    )

    try store.save(legacy)
    #expect(store.load(
        expectedUserScope: scopeA,
        policy: SnapshotStoreStalenessPolicy(maximumAge: 60),
        now: now
    ).document == nil)
    #expect(!FileManager.default.fileExists(atPath: documentURL.path))

    try store.save(legacy.bound(to: scopeA))
    #expect(store.load(
        expectedUserScope: scopeB,
        policy: SnapshotStoreStalenessPolicy(maximumAge: 60),
        now: now
    ).document == nil)
    #expect(!FileManager.default.fileExists(atPath: documentURL.path))
}
