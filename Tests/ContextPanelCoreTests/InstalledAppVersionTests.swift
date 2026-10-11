import ContextPanelCore
import Foundation
import Testing

@Test func installedVersionReadsTheSuppliedBundleMetadata() {
    let metadata: [String: Any] = [
        "CFBundleShortVersionString": "9.7.3",
        "CFBundleVersion": "24680",
    ]
    let version = InstalledAppVersion(infoDictionary: metadata)
    #expect(version.marketingVersion == metadata["CFBundleShortVersionString"] as? String)
    #expect(version.buildNumber == metadata["CFBundleVersion"] as? String)
    #expect(version.displayText.contains(version.marketingVersion!))
    #expect(version.displayText.contains(version.buildNumber!))
}

@Test func missingInstalledVersionDoesNotBorrowASyncedOrDefaultVersion() {
    let cases: [[String: Any]] = [[:], ["CFBundleShortVersionString": " \n", "CFBundleVersion": 123]]
    for metadata in cases {
        let version = InstalledAppVersion(infoDictionary: metadata)
        #expect(version.marketingVersion == nil)
        #expect(version.buildNumber == nil)
    }
    let partial = InstalledAppVersion(infoDictionary: ["CFBundleVersion": "123"])
    #expect(partial.marketingVersion == nil)
    #expect(partial.buildNumber != nil)
}
