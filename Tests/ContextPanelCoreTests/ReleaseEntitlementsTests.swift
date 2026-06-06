import Foundation
import Testing

@Test func appStoreEntitlementsSupportSandboxedProviderRefreshes() throws {
    for path in [
        "Config/ContextPanelAppStore.entitlements",
        "Config/ContextPanelRefreshAgentAppStore.entitlements",
    ] {
        let entitlements = try loadEntitlements(path)
        #expect(entitlements["com.apple.security.app-sandbox"] as? Bool == true)
        #expect(entitlements["com.apple.security.network.client"] as? Bool == true)
        #expect(entitlements["com.apple.security.files.user-selected.read-only"] as? Bool == true)
        #expect(entitlements["com.apple.security.files.bookmarks.app-scope"] as? Bool == true)
        #expect(entitlements["com.apple.security.files.bookmarks.document-scope"] == nil)
        let appGroups = try #require(entitlements["com.apple.security.application-groups"] as? [String])
        #expect(appGroups == ["MM5YXC7T6E.group.com.shinycomputers.contextpanel"])
        let keychainGroups = try #require(entitlements["keychain-access-groups"] as? [String])
        #expect(keychainGroups == ["MM5YXC7T6E.com.shinycomputers.contextpanel.provider-credentials"])
    }
}

@Test func debugEntitlementsShareProviderCredentialKeychainGroup() throws {
    for path in [
        "Config/ContextPanel.entitlements",
        "Config/ContextPanelRefreshAgent.entitlements",
    ] {
        let entitlements = try loadEntitlements(path)
        let keychainGroups = try #require(entitlements["keychain-access-groups"] as? [String])
        #expect(keychainGroups == ["MM5YXC7T6E.com.shinycomputers.contextpanel.provider-credentials"])
    }
}

@Test func widgetEntitlementsStaySandboxedAndAppGroupOnly() throws {
    let entitlements = try loadEntitlements("Config/ContextPanelWidget.entitlements")

    #expect(entitlements["com.apple.security.app-sandbox"] as? Bool == true)
    let appGroups = try #require(entitlements["com.apple.security.application-groups"] as? [String])
    #expect(appGroups == ["MM5YXC7T6E.group.com.shinycomputers.contextpanel"])
    #expect(entitlements["com.apple.security.network.client"] == nil)
    #expect(entitlements["keychain-access-groups"] == nil)
    #expect(entitlements["com.apple.security.files.user-selected.read-only"] == nil)
    #expect(entitlements["com.apple.security.files.bookmarks.app-scope"] == nil)
    #expect(entitlements["com.apple.security.files.bookmarks.document-scope"] == nil)
}

@Test func refreshAgentPreservesBackgroundGeminiLegacyOAuth() throws {
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appending(path: "Sources/ContextPanelRefreshAgent/ContextPanelRefreshAgent.swift")
    let source = try String(contentsOf: url, encoding: .utf8)

    #expect(source.contains("SnapshotRefreshRunner.appDefault"))
    #expect(!source.contains("allowsLegacyGeminiOAuth: false"))
}

private func loadEntitlements(_ path: String) throws -> [String: Any] {
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: path)
    let data = try Data(contentsOf: url)
    let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    return try #require(plist as? [String: Any])
}
