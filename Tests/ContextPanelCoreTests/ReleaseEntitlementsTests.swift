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

@Test func refreshAgentDoesNotReferenceRetiredGoogleCredentialPaths() throws {
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appending(path: "Sources/ContextPanelRefreshAgent/ContextPanelRefreshAgent.swift")
    let source = try String(contentsOf: url, encoding: .utf8)

    #expect(source.contains("SnapshotRefreshRunner.appDefault"))
    #expect(!source.contains("GeminiQuotaProbe"))
    #expect(!source.contains("allowsLegacyGeminiOAuth"))
    #expect(!source.contains("antigravityCredentialSource"))
    #expect(!source.contains("oauth_creds.json"))
}

@Test func appAndRefreshAgentTargetsReceiveGoogleOAuthBuildSettings() throws {
    let project = try loadProjectYAML()

    for targetName in ["ContextPanel", "ContextPanelRefreshAgent"] {
        let settings = try #require(project.targetSettings(named: targetName))
        #expect(settings["CONTEXT_PANEL_GOOGLE_OAUTH_CLIENT_ID"] as? String == "")
        #expect(settings["CONTEXT_PANEL_GOOGLE_OAUTH_CLIENT_SECRET"] as? String == "")
    }

    let refreshAgentSettings = try #require(
        project.targetSettings(named: "ContextPanelRefreshAgent")
    )
    #expect(refreshAgentSettings["GENERATE_INFOPLIST_FILE"] as? String == "false")
    #expect(
        refreshAgentSettings["INFOPLIST_FILE"] as? String
            == "Config/ContextPanelRefreshAgent-Info.plist"
    )

    let plist = try loadInfoPlist("Config/ContextPanelRefreshAgent-Info.plist")
    #expect(
        plist["CONTEXT_PANEL_GOOGLE_OAUTH_CLIENT_ID"] as? String
            == "$(CONTEXT_PANEL_GOOGLE_OAUTH_CLIENT_ID)"
    )
    #expect(
        plist["CONTEXT_PANEL_GOOGLE_OAUTH_CLIENT_SECRET"] as? String
            == "$(CONTEXT_PANEL_GOOGLE_OAUTH_CLIENT_SECRET)"
    )
    #expect(plist["LSBackgroundOnly"] as? Bool == true)
    #expect(plist["LSUIElement"] as? Bool == true)
}

private func loadEntitlements(_ path: String) throws -> [String: Any] {
    try loadInfoPlist(path)
}

private func loadInfoPlist(_ path: String) throws -> [String: Any] {
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: path)
    let data = try Data(contentsOf: url)
    let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    return try #require(plist as? [String: Any])
}

private func loadProjectYAML() throws -> ProjectYAML {
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appending(path: "project.yml")
    let text = try String(contentsOf: url, encoding: .utf8)
    return ProjectYAML(text: text)
}

private struct ProjectYAML {
    private let lines: [String]

    init(text: String) {
        lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
    }

    func targetSettings(named targetName: String) -> [String: Any]? {
        guard let targetLine = firstLineIndex(matching: "  \(targetName):") else {
            return nil
        }
        guard let settingsLine = firstLineIndex(
            after: targetLine,
            matching: "    settings:",
            beforeIndentLessThan: 4
        ) else {
            return nil
        }
        guard let baseLine = firstLineIndex(
            after: settingsLine,
            matching: "      base:",
            beforeIndentLessThan: 6
        ) else {
            return nil
        }
        return mapping(after: baseLine, indentation: 8)
    }

    private func firstLineIndex(matching text: String) -> Int? {
        lines.firstIndex { $0 == text }
    }

    private func firstLineIndex(
        after startIndex: Int,
        matching text: String,
        beforeIndentLessThan minimumIndent: Int
    ) -> Int? {
        var index = startIndex + 1
        while index < lines.count {
            let line = lines[index]
            let indent = indentation(of: line)
            if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                if indent < minimumIndent { return nil }
                if line == text { return index }
            }
            index += 1
        }
        return nil
    }

    private func mapping(after startIndex: Int, indentation: Int) -> [String: Any] {
        var result: [String: Any] = [:]
        var index = startIndex + 1
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = self.indentation(of: line)
            guard !trimmed.isEmpty else {
                index += 1
                continue
            }
            if indent < indentation { break }
            if indent == indentation,
               let colonIndex = trimmed.firstIndex(of: ":") {
                let key = String(trimmed[..<colonIndex])
                let valueStart = trimmed.index(after: colonIndex)
                let rawValue = trimmed[valueStart...].trimmingCharacters(in: .whitespaces)
                result[key] = normalizedValue(rawValue, nextLineIndex: index + 1)
            }
            index += 1
        }
        return result
    }

    private func normalizedValue(_ rawValue: String, nextLineIndex: Int) -> String {
        if rawValue == ">-", nextLineIndex < lines.count {
            return lines[nextLineIndex].trimmingCharacters(in: .whitespaces)
        }
        return rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    private func indentation(of line: String) -> Int {
        line.prefix { $0 == " " }.count
    }
}
