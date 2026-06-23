import Foundation
import Testing

@Test func appStoreEntitlementsSupportSandboxedProviderRefreshes() throws {
    let appEntitlements = try loadEntitlements("Config/ContextPanelAppStore.entitlements")
    #expect(appEntitlements["com.apple.security.app-sandbox"] as? Bool == true)
    #expect(appEntitlements["com.apple.security.network.client"] as? Bool == true)
    #expect(appEntitlements["com.apple.security.network.server"] == nil)
    #expect(appEntitlements["com.apple.security.files.user-selected.read-only"] as? Bool == true)
    #expect(appEntitlements["com.apple.security.files.bookmarks.app-scope"] as? Bool == true)
    #expect(appEntitlements["com.apple.security.files.bookmarks.document-scope"] == nil)
    let appGroups = try #require(appEntitlements["com.apple.security.application-groups"] as? [String])
    #expect(appGroups == ["MM5YXC7T6E.group.com.shinycomputers.contextpanel"])
    let keychainGroups = try #require(appEntitlements["keychain-access-groups"] as? [String])
    #expect(keychainGroups == ["MM5YXC7T6E.com.shinycomputers.contextpanel.provider-credentials"])
    try expectICloudDocumentAndCloudKitEntitlements(appEntitlements)

    let refreshAgentEntitlements = try loadEntitlements("Config/ContextPanelRefreshAgentAppStore.entitlements")
    #expect(refreshAgentEntitlements["com.apple.security.app-sandbox"] as? Bool == true)
    #expect(refreshAgentEntitlements["com.apple.security.network.client"] as? Bool == true)
    #expect(refreshAgentEntitlements["com.apple.security.network.server"] == nil)
    #expect(refreshAgentEntitlements["com.apple.security.files.user-selected.read-only"] as? Bool == true)
    #expect(refreshAgentEntitlements["com.apple.security.files.bookmarks.app-scope"] as? Bool == true)
    #expect(refreshAgentEntitlements["com.apple.security.files.bookmarks.document-scope"] == nil)
    let refreshAgentAppGroups = try #require(refreshAgentEntitlements["com.apple.security.application-groups"] as? [String])
    #expect(refreshAgentAppGroups == ["MM5YXC7T6E.group.com.shinycomputers.contextpanel"])
    let refreshAgentKeychainGroups = try #require(refreshAgentEntitlements["keychain-access-groups"] as? [String])
    #expect(refreshAgentKeychainGroups == ["MM5YXC7T6E.com.shinycomputers.contextpanel.provider-credentials"])
    try expectICloudDocumentAndCloudKitEntitlements(refreshAgentEntitlements)
}

@Test func debugAppEntitlementsDoNotRequireOAuthCallbackServer() throws {
    let entitlements = try loadEntitlements("Config/ContextPanel.entitlements")
    #expect(entitlements["com.apple.security.network.server"] == nil)
    try expectICloudDocumentAndCloudKitEntitlements(entitlements)

    let refreshAgentEntitlements = try loadEntitlements("Config/ContextPanelRefreshAgent.entitlements")
    #expect(refreshAgentEntitlements["com.apple.security.network.server"] == nil)
    try expectICloudDocumentAndCloudKitEntitlements(refreshAgentEntitlements)
}

@Test func mainAppInfoPlistRegistersOnlyContextPanelURLScheme() throws {
    let plist = try loadInfoPlist("Config/ContextPanel-Info.plist")
    let urlTypes = try #require(plist["CFBundleURLTypes"] as? [[String: Any]])
    let schemes = urlTypes.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }

    #expect(schemes == ["contextpanel"])
}

@Test func appStoreEntitlementsSupportSandboxedRefreshAgent() throws {
    for path in [
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
        try expectICloudDocumentAndCloudKitEntitlements(entitlements)
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

@Test func companionEntitlementsMirrorICloudIntoIOSSuite() throws {
    let appEntitlements = try loadEntitlements("Config/ContextPanelCompanion.entitlements")
    try expectICloudDocumentAndCloudKitEntitlements(appEntitlements)
    #expect(appEntitlements["aps-environment"] as? String == "$(APS_ENVIRONMENT)")
    let appGroups = try #require(appEntitlements["com.apple.security.application-groups"] as? [String])
    #expect(appGroups == ["group.com.shinycomputers.contextpanel"])
    #expect(appEntitlements["com.apple.security.app-sandbox"] == nil)
    #expect(appEntitlements["com.apple.security.network.client"] == nil)
    #expect(appEntitlements["keychain-access-groups"] == nil)

    let widgetEntitlements = try loadEntitlements("Config/ContextPanelCompanionWidget.entitlements")
    let widgetAppGroups = try #require(widgetEntitlements["com.apple.security.application-groups"] as? [String])
    #expect(widgetAppGroups == ["group.com.shinycomputers.contextpanel"])
    #expect(widgetEntitlements["com.apple.security.app-sandbox"] == nil)
    #expect(widgetEntitlements["com.apple.security.network.client"] == nil)
    #expect(widgetEntitlements["keychain-access-groups"] == nil)
    #expect(widgetEntitlements["com.apple.developer.icloud-container-identifiers"] == nil)
    #expect(widgetEntitlements["com.apple.developer.icloud-services"] == nil)
    #expect(widgetEntitlements["com.apple.developer.ubiquity-container-identifiers"] == nil)
}

@Test func companionProjectTargetsUseSharedSyncAndWidgetModules() throws {
    let project = try loadProjectYAML()

    let appTarget = try #require(project.target(named: "ContextPanelCompanion"))
    #expect(appTarget["supportedDestinations"] as? String == "[iOS, visionOS]")

    let appSettings = try #require(project.targetSettings(named: "ContextPanelCompanion"))
    #expect(appSettings["PRODUCT_BUNDLE_IDENTIFIER"] as? String == "com.shinycomputers.contextpanel")
    #expect(appSettings["CODE_SIGN_ENTITLEMENTS"] as? String == "Config/ContextPanelCompanion.entitlements")
    #expect(appSettings["TARGETED_DEVICE_FAMILY"] as? String == "1,2,7")
    #expect(appSettings["XROS_DEPLOYMENT_TARGET"] as? String == "26.0")
    #expect(appSettings["APS_ENVIRONMENT"] as? String == "development")
    let appReleaseSettings = try #require(project.releaseTargetSettings(named: "ContextPanelCompanion"))
    #expect(appReleaseSettings["APS_ENVIRONMENT"] as? String == "production")
    #expect(appReleaseSettings["CODE_SIGN_IDENTITY"] as? String == "Apple Distribution")
    #expect(
        appReleaseSettings["PROVISIONING_PROFILE_SPECIFIER"] as? String
            == "$(CONTEXT_PANEL_APP_STORE_COMPANION_PROFILE_SPECIFIER)"
    )

    let widgetTarget = try #require(project.target(named: "ContextPanelCompanionWidgetExtension"))
    #expect(widgetTarget["supportedDestinations"] as? String == "[iOS, visionOS]")

    let widgetSettings = try #require(project.targetSettings(named: "ContextPanelCompanionWidgetExtension"))
    #expect(
        widgetSettings["PRODUCT_BUNDLE_IDENTIFIER"] as? String
            == "com.shinycomputers.contextpanel.widget"
    )
    #expect(
        widgetSettings["CODE_SIGN_ENTITLEMENTS"] as? String
            == "Config/ContextPanelCompanionWidget.entitlements"
    )
    #expect(widgetSettings["TARGETED_DEVICE_FAMILY"] as? String == "1,2,7")
    #expect(widgetSettings["XROS_DEPLOYMENT_TARGET"] as? String == "26.0")
    let widgetReleaseSettings = try #require(
        project.releaseTargetSettings(named: "ContextPanelCompanionWidgetExtension")
    )
    #expect(widgetReleaseSettings["CODE_SIGN_IDENTITY"] as? String == "Apple Distribution")
    #expect(
        widgetReleaseSettings["PROVISIONING_PROFILE_SPECIFIER"] as? String
            == "$(CONTEXT_PANEL_APP_STORE_COMPANION_WIDGET_PROFILE_SPECIFIER)"
    )

    let appDependencies = try #require(project.dependencies(named: "ContextPanelCompanion"))
    #expect(appDependencies.contains("ContextPanelCoreCompanion"))
    #expect(appDependencies.contains("ContextPanelWidgetUICompanion"))
    #expect(appDependencies.contains("ContextPanelCompanionSupport"))
    #expect(appDependencies.contains("ContextPanelCloudKitSyncCompanion"))
    #expect(appDependencies.contains("ContextPanelCompanionWidgetExtension"))

    let widgetDependencies = try #require(project.dependencies(named: "ContextPanelCompanionWidgetExtension"))
    #expect(widgetDependencies.contains("ContextPanelCoreCompanion"))
    #expect(widgetDependencies.contains("ContextPanelWidgetUICompanion"))
    #expect(widgetDependencies.contains("ContextPanelCompanionSupport"))
    #expect(!widgetDependencies.contains("ContextPanelCloudKitSyncCompanion"))

    let plist = try loadInfoPlist("Config/ContextPanelCompanion-Info.plist")
    let backgroundModes = try #require(plist["UIBackgroundModes"] as? [String])
    #expect(backgroundModes == ["remote-notification"])
}

@Test func refreshAgentDoesNotReferenceRetiredGoogleCredentialPaths() throws {
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appending(path: "Sources/ContextPanelRefreshAgent/ContextPanelRefreshAgent.swift")
    let source = try String(contentsOf: url, encoding: .utf8)

    #expect(source.contains("allowsExternalGoogleKeychain: false"))
    #expect(!source.contains("GeminiQuotaProbe"))
    #expect(!source.contains("allowsLegacyGeminiOAuth"))
    #expect(!source.contains("antigravityCredentialSource"))
    #expect(!source.contains("oauth_creds.json"))
}

@Test func appAndRefreshAgentTargetsDoNotCarryGoogleOAuthBuildSettings() throws {
    let project = try loadProjectYAML()

    for targetName in ["ContextPanel", "ContextPanelRefreshAgent"] {
        let settings = try #require(project.targetSettings(named: targetName))
        #expect(settings.keys.allSatisfy { !$0.hasPrefix("CONTEXT_PANEL_GOOGLE_") })
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
    #expect(plist.keys.allSatisfy { !$0.hasPrefix("CONTEXT_PANEL_GOOGLE_") })
    #expect(plist["LSBackgroundOnly"] as? Bool == true)
    #expect(plist["LSUIElement"] as? Bool == true)
}

private func loadEntitlements(_ path: String) throws -> [String: Any] {
    try loadInfoPlist(path)
}

private func expectICloudDocumentEntitlements(_ entitlements: [String: Any]) throws {
    let iCloudContainers = try #require(
        entitlements["com.apple.developer.icloud-container-identifiers"] as? [String]
    )
    #expect(iCloudContainers == ["iCloud.com.shinycomputers.contextpanel"])
    let ubiquityContainers = try #require(
        entitlements["com.apple.developer.ubiquity-container-identifiers"] as? [String]
    )
    #expect(ubiquityContainers == ["iCloud.com.shinycomputers.contextpanel"])
    let services = try #require(entitlements["com.apple.developer.icloud-services"] as? [String])
    #expect(services == ["CloudDocuments"])
    #expect(entitlements["com.apple.developer.ubiquity-kvstore-identifier"] == nil)
}

private func expectICloudDocumentAndCloudKitEntitlements(_ entitlements: [String: Any]) throws {
    let iCloudContainers = try #require(
        entitlements["com.apple.developer.icloud-container-identifiers"] as? [String]
    )
    #expect(iCloudContainers == ["iCloud.com.shinycomputers.contextpanel"])
    let ubiquityContainers = try #require(
        entitlements["com.apple.developer.ubiquity-container-identifiers"] as? [String]
    )
    #expect(ubiquityContainers == ["iCloud.com.shinycomputers.contextpanel"])
    let services = try #require(entitlements["com.apple.developer.icloud-services"] as? [String])
    #expect(services == ["CloudDocuments", "CloudKit"])
    #expect(entitlements["com.apple.developer.ubiquity-kvstore-identifier"] == nil)
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

    func target(named targetName: String) -> [String: Any]? {
        guard let targetLine = firstLineIndex(matching: "  \(targetName):") else {
            return nil
        }
        return mapping(after: targetLine, indentation: 4)
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

    func releaseTargetSettings(named targetName: String) -> [String: Any]? {
        guard let targetLine = firstLineIndex(matching: "  \(targetName):") else {
            return nil
        }
        guard let configsLine = firstLineIndex(
            after: targetLine,
            matching: "      configs:",
            beforeIndentLessThan: 4
        ) else {
            return nil
        }
        guard let releaseLine = firstLineIndex(
            after: configsLine,
            matching: "        Release:",
            beforeIndentLessThan: 8
        ) else {
            return nil
        }
        return mapping(after: releaseLine, indentation: 10)
    }

    func dependencies(named targetName: String) -> [String]? {
        guard let targetLine = firstLineIndex(matching: "  \(targetName):") else {
            return nil
        }
        guard let dependenciesLine = firstLineIndex(
            after: targetLine,
            matching: "    dependencies:",
            beforeIndentLessThan: 4
        ) else {
            return []
        }

        var dependencies: [String] = []
        var index = dependenciesLine + 1
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = indentation(of: line)
            guard !trimmed.isEmpty else {
                index += 1
                continue
            }
            if indent <= 4 { break }
            if indent == 6, trimmed.hasPrefix("- target: ") {
                dependencies.append(String(trimmed.dropFirst("- target: ".count)))
            }
            index += 1
        }
        return dependencies
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
