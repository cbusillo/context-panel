import Darwin
import Foundation
import Testing
@testable import ContextPanelCore

@Test func runtimeReceiptLockIsContainedWithinCoordinatedAccess() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let coordinator = ReceiptLockCoordinator()
    let value = try RuntimeReceiptDirectoryLock.withLock(
        directoryURL: directory,
        coordinator: coordinator
    ) {
        #expect(coordinator.isAccessing)
        #expect(!receiptLockIsAvailable(in: directory))
        return 42
    }
    #expect(value == 42)
    #expect(coordinator.accessCount == 1)
    #expect(coordinator.lockWasReleasedBeforeAccessEnded)
    #expect(receiptLockIsAvailable(in: directory))

    #expect(throws: CocoaError.self) {
        try RuntimeReceiptDirectoryLock.withLock(directoryURL: directory, coordinator: coordinator) {
            #expect(coordinator.isAccessing)
            throw CocoaError(.fileWriteUnknown)
        }
    }
    #expect(coordinator.lockWasReleasedBeforeAccessEnded)
    #expect(receiptLockIsAvailable(in: directory))
}

@Test func runtimeReceiptLockDoesNoWorkWhenCoordinationIsCancelledOrLockIsBusy() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let coordinator = ReceiptLockCoordinator()
    coordinator.cancelAccess = true
    #expect(throws: CocoaError.self) {
        try RuntimeReceiptDirectoryLock.withLock(directoryURL: directory, coordinator: coordinator) {
            Issue.record("Cancelled coordination must not enter the critical section")
        }
    }
    #expect(!FileManager.default.fileExists(atPath: directory.appending(path: ".write.lock").path))

    let descriptor = open(directory.appending(path: ".write.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    #expect(descriptor >= 0)
    defer { close(descriptor) }
    #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
    defer { flock(descriptor, LOCK_UN) }
    #expect(throws: RuntimeReceiptRemoteSyncError.busy) {
        try RuntimeReceiptDirectoryLock.withLock(directoryURL: directory) {
            Issue.record("A contended cross-process lock must not enter the critical section")
        }
    }
}

private final class ReceiptLockCoordinator: NSFileCoordinator {
    var isAccessing = false
    var accessCount = 0
    var cancelAccess = false
    var lockWasReleasedBeforeAccessEnded = false

    override func coordinate(
        writingItemAt url: URL,
        options: NSFileCoordinator.WritingOptions = [],
        error outError: AutoreleasingUnsafeMutablePointer<NSError?>?,
        byAccessor writer: (URL) -> Void
    ) {
        if cancelAccess {
            outError?.pointee = CocoaError(.userCancelled) as NSError
            return
        }
        isAccessing = true
        accessCount += 1
        writer(url)
        lockWasReleasedBeforeAccessEnded = receiptLockIsAvailable(in: url.deletingLastPathComponent())
        isAccessing = false
    }
}

private func receiptLockIsAvailable(in directory: URL) -> Bool {
    let descriptor = open(directory.appending(path: ".write.lock").path, O_RDWR)
    guard descriptor >= 0 else { return false }
    defer { close(descriptor) }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return false }
    flock(descriptor, LOCK_UN)
    return true
}
