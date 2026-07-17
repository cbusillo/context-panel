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
    expectProductionCloudKitEnvironment(appEntitlements)

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
    expectProductionCloudKitEnvironment(refreshAgentEntitlements)
}

@Test func debugAppEntitlementsDoNotRequireOAuthCallbackServer() throws {
    let entitlements = try loadEntitlements("Config/ContextPanel.entitlements")
    #expect(entitlements["com.apple.security.network.server"] == nil)
    try expectICloudDocumentAndCloudKitEntitlements(entitlements)
    expectDevelopmentCloudKitEnvironment(entitlements)

    let refreshAgentEntitlements = try loadEntitlements("Config/ContextPanelRefreshAgent.entitlements")
    #expect(refreshAgentEntitlements["com.apple.security.network.server"] == nil)
    try expectICloudDocumentAndCloudKitEntitlements(refreshAgentEntitlements)
    expectDevelopmentCloudKitEnvironment(refreshAgentEntitlements)
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
        expectProductionCloudKitEnvironment(entitlements)
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

@Test func watchAppAndWidgetReadCloudKitWithoutSharedAppGroupStorage() throws {
    let appEntitlements = try loadEntitlements("Config/ContextPanelWatch.entitlements")
    let iCloudContainers = try #require(
        appEntitlements["com.apple.developer.icloud-container-identifiers"] as? [String]
    )
    #expect(iCloudContainers == ["iCloud.com.shinycomputers.contextpanel"])
    let services = try #require(appEntitlements["com.apple.developer.icloud-services"] as? [String])
    #expect(services == ["CloudKit"])
    #expect(appEntitlements["com.apple.developer.icloud-container-environment"] as? String == "Development")
    #expect(appEntitlements["com.apple.security.application-groups"] == nil)
    #expect(appEntitlements["aps-environment"] == nil)
    #expect(appEntitlements["keychain-access-groups"] == nil)
    #expect(appEntitlements["com.apple.developer.ubiquity-container-identifiers"] == nil)

    let widgetEntitlements = try loadEntitlements("Config/ContextPanelWatchWidget.entitlements")
    #expect(widgetEntitlements["com.apple.security.application-groups"] == nil)
    #expect(
        widgetEntitlements["com.apple.developer.icloud-container-identifiers"] as? [String]
            == ["iCloud.com.shinycomputers.contextpanel"]
    )
    #expect(widgetEntitlements["com.apple.developer.icloud-services"] as? [String] == ["CloudKit"])
    #expect(widgetEntitlements["com.apple.developer.icloud-container-environment"] as? String == "Development")
    #expect(widgetEntitlements["aps-environment"] == nil)
    #expect(widgetEntitlements["keychain-access-groups"] == nil)
    #expect(widgetEntitlements["com.apple.developer.ubiquity-container-identifiers"] == nil)

    let appStoreAppEntitlements = try loadEntitlements("Config/ContextPanelWatchAppStore.entitlements")
    #expect(
        appStoreAppEntitlements["com.apple.developer.icloud-container-environment"] as? String
            == "Production"
    )
    #expect(appStoreAppEntitlements["com.apple.security.application-groups"] == nil)

    let appStoreWidgetEntitlements = try loadEntitlements(
        "Config/ContextPanelWatchWidgetAppStore.entitlements"
    )
    #expect(
        appStoreWidgetEntitlements["com.apple.developer.icloud-container-environment"] as? String
            == "Production"
    )
    #expect(appStoreWidgetEntitlements["com.apple.security.application-groups"] == nil)
}

@Test func tvEntitlementsSupportCloudKitPushAndTopShelfSharing() throws {
    let entitlements = try loadEntitlements("Config/ContextPanelTV.entitlements")

    let iCloudContainers = try #require(
        entitlements["com.apple.developer.icloud-container-identifiers"] as? [String]
    )
    #expect(iCloudContainers == ["iCloud.com.shinycomputers.contextpanel"])
    let services = try #require(entitlements["com.apple.developer.icloud-services"] as? [String])
    #expect(services == ["CloudKit"])
    #expect(entitlements["aps-environment"] as? String == "$(APS_ENVIRONMENT)")
    #expect(
        entitlements["com.apple.security.application-groups"] as? [String]
            == ["group.com.shinycomputers.contextpanel"]
    )
    #expect(
        entitlements["com.apple.developer.user-management"] as? [String]
            == ["runs-as-current-user-with-user-independent-keychain"]
    )
    #expect(entitlements["keychain-access-groups"] == nil)
    #expect(entitlements["com.apple.developer.ubiquity-container-identifiers"] == nil)
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
    #expect(appDependencies.contains("ContextPanelWatch"))

    let widgetDependencies = try #require(project.dependencies(named: "ContextPanelCompanionWidgetExtension"))
    #expect(widgetDependencies.contains("ContextPanelCoreCompanion"))
    #expect(widgetDependencies.contains("ContextPanelWidgetUICompanion"))
    #expect(widgetDependencies.contains("ContextPanelCompanionSupport"))
    #expect(!widgetDependencies.contains("ContextPanelCloudKitSyncCompanion"))

    let plist = try loadInfoPlist("Config/ContextPanelCompanion-Info.plist")
    let backgroundModes = try #require(plist["UIBackgroundModes"] as? [String])
    #expect(backgroundModes == ["remote-notification"])
    let sceneManifest = try #require(plist["UIApplicationSceneManifest"] as? [String: Any])
    #expect(sceneManifest["UIApplicationPreferredDefaultSceneSessionRole"] as? String == "UIWindowSceneSessionRoleApplication")
    #expect(sceneManifest["UIApplicationSupportsMultipleScenes"] as? Bool == true)
}

@Test func watchProjectTargetUsesDistinctReadOnlyCompanionSurface() throws {
    let project = try loadProjectYAML()

    let coreTarget = try #require(project.target(named: "ContextPanelCoreWatch"))
    #expect(coreTarget["platform"] as? String == "watchOS")
    let coreSettings = try #require(project.targetSettings(named: "ContextPanelCoreWatch"))
    #expect(coreSettings["PRODUCT_MODULE_NAME"] as? String == "ContextPanelCore")
    #expect(coreSettings["WATCHOS_DEPLOYMENT_TARGET"] as? String == "10.0")

    let cloudKitTarget = try #require(project.target(named: "ContextPanelCloudKitSyncWatch"))
    #expect(cloudKitTarget["platform"] as? String == "watchOS")
    let cloudKitDependencies = try #require(project.dependencies(named: "ContextPanelCloudKitSyncWatch"))
    #expect(cloudKitDependencies == ["ContextPanelCoreWatch"])

    let appTarget = try #require(project.target(named: "ContextPanelWatch"))
    #expect(appTarget["platform"] as? String == "watchOS")
    #expect(appTarget["deploymentTarget"] as? String == "10.0")

    let appSettings = try #require(project.targetSettings(named: "ContextPanelWatch"))
    #expect(appSettings["PRODUCT_BUNDLE_IDENTIFIER"] as? String == "com.shinycomputers.contextpanel.watch")
    #expect(appSettings["CODE_SIGN_ENTITLEMENTS"] as? String == "Config/ContextPanelWatch.entitlements")
    #expect(appSettings["INFOPLIST_FILE"] as? String == "Config/ContextPanelWatch-Info.plist")
    #expect(appSettings["WATCHOS_DEPLOYMENT_TARGET"] as? String == "10.0")
    #expect(appSettings["ASSETCATALOG_COMPILER_APPICON_NAME"] as? String == "AppIcon")
    #expect(appSettings["SKIP_INSTALL"] as? String == "true")
    #expect(appSettings["TARGETED_DEVICE_FAMILY"] == nil)
    #expect(appSettings["APS_ENVIRONMENT"] == nil)

    let appReleaseSettings = try #require(project.releaseTargetSettings(named: "ContextPanelWatch"))
    #expect(appReleaseSettings["CODE_SIGN_IDENTITY"] as? String == "Apple Distribution")
    #expect(
        appReleaseSettings["CODE_SIGN_ENTITLEMENTS"] as? String
            == "Config/ContextPanelWatchAppStore.entitlements"
    )
    #expect(
        appReleaseSettings["PROVISIONING_PROFILE_SPECIFIER"] as? String
            == "$(CONTEXT_PANEL_APP_STORE_WATCH_PROFILE_SPECIFIER)"
    )

    let appDependencies = try #require(project.dependencies(named: "ContextPanelWatch"))
    #expect(appDependencies == [
        "ContextPanelCoreWatch",
        "ContextPanelCloudKitSyncWatch",
        "ContextPanelWatchWidgetExtension",
    ])
    #expect(!appDependencies.contains("ContextPanelCompanionSupport"))
    #expect(!appDependencies.contains("ContextPanelCompanionWidgetExtension"))

    let watchWidgetTarget = try #require(project.target(named: "ContextPanelWatchWidgetExtension"))
    #expect(watchWidgetTarget["platform"] as? String == "watchOS")
    #expect(watchWidgetTarget["type"] as? String == "app-extension")
    let watchWidgetSettings = try #require(project.targetSettings(named: "ContextPanelWatchWidgetExtension"))
    #expect(
        watchWidgetSettings["PRODUCT_BUNDLE_IDENTIFIER"] as? String
            == "com.shinycomputers.contextpanel.watch.widget"
    )
    #expect(
        watchWidgetSettings["CODE_SIGN_ENTITLEMENTS"] as? String
            == "Config/ContextPanelWatchWidget.entitlements"
    )
    #expect(watchWidgetSettings["WATCHOS_DEPLOYMENT_TARGET"] as? String == "10.0")
    #expect(watchWidgetSettings["SKIP_INSTALL"] as? String == "true")
    let watchWidgetReleaseSettings = try #require(
        project.releaseTargetSettings(named: "ContextPanelWatchWidgetExtension")
    )
    #expect(watchWidgetReleaseSettings["CODE_SIGN_IDENTITY"] as? String == "Apple Distribution")
    #expect(
        watchWidgetReleaseSettings["CODE_SIGN_ENTITLEMENTS"] as? String
            == "Config/ContextPanelWatchWidgetAppStore.entitlements"
    )
    #expect(
        watchWidgetReleaseSettings["PROVISIONING_PROFILE_SPECIFIER"] as? String
            == "$(CONTEXT_PANEL_APP_STORE_WATCH_WIDGET_PROFILE_SPECIFIER)"
    )
    let watchWidgetDependencies = try #require(project.dependencies(named: "ContextPanelWatchWidgetExtension"))
    #expect(watchWidgetDependencies == ["ContextPanelCoreWatch", "ContextPanelCloudKitSyncWatch"])

    let watchWidgetPlist = try loadInfoPlist("Config/ContextPanelWatchWidget-Info.plist")
    let watchWidgetExtension = try #require(watchWidgetPlist["NSExtension"] as? [String: Any])
    #expect(
        watchWidgetExtension["NSExtensionPointIdentifier"] as? String
            == "com.apple.widgetkit-extension"
    )

    let plist = try loadInfoPlist("Config/ContextPanelWatch-Info.plist")
    #expect(plist["WKApplication"] as? Bool == true)
    #expect(plist["WKCompanionAppBundleIdentifier"] as? String == "com.shinycomputers.contextpanel")
    #expect(plist["UIApplicationSceneManifest"] == nil)
    #expect(plist["UIBackgroundModes"] == nil)
}

@Test func tvProjectTargetUsesDistinctReadOnlyCompanionSurface() throws {
    let project = try loadProjectYAML()

    let coreTarget = try #require(project.target(named: "ContextPanelCoreTV"))
    #expect(coreTarget["platform"] as? String == "tvOS")
    #expect(coreTarget["deploymentTarget"] as? String == "17.0")
    let coreSettings = try #require(project.targetSettings(named: "ContextPanelCoreTV"))
    #expect(coreSettings["PRODUCT_MODULE_NAME"] as? String == "ContextPanelCore")
    #expect(coreSettings["TVOS_DEPLOYMENT_TARGET"] as? String == "17.0")

    let cloudKitTarget = try #require(project.target(named: "ContextPanelCloudKitSyncTV"))
    #expect(cloudKitTarget["platform"] as? String == "tvOS")
    let cloudKitDependencies = try #require(project.dependencies(named: "ContextPanelCloudKitSyncTV"))
    #expect(cloudKitDependencies == ["ContextPanelCoreTV"])

    let supportTarget = try #require(project.target(named: "ContextPanelTVSupport"))
    #expect(supportTarget["platform"] as? String == "tvOS")
    let supportDependencies = try #require(project.dependencies(named: "ContextPanelTVSupport"))
    #expect(supportDependencies == ["ContextPanelCoreTV"])

    let appTarget = try #require(project.target(named: "ContextPanelTV"))
    #expect(appTarget["platform"] as? String == "tvOS")
    #expect(appTarget["deploymentTarget"] as? String == "17.0")

    let appSettings = try #require(project.targetSettings(named: "ContextPanelTV"))
    #expect(appSettings["PRODUCT_BUNDLE_IDENTIFIER"] as? String == "com.shinycomputers.contextpanel")
    #expect(appSettings["CODE_SIGN_ENTITLEMENTS"] as? String == "Config/ContextPanelTV.entitlements")
    #expect(appSettings["INFOPLIST_FILE"] as? String == "Config/ContextPanelTV-Info.plist")
    #expect(appSettings["TVOS_DEPLOYMENT_TARGET"] as? String == "17.0")
    #expect(appSettings["TARGETED_DEVICE_FAMILY"] as? String == "3")
    #expect(appSettings["ASSETCATALOG_COMPILER_APPICON_NAME"] as? String == "App Icon & Top Shelf Image")
    #expect(appSettings["APS_ENVIRONMENT"] as? String == "development")

    let appReleaseSettings = try #require(project.releaseTargetSettings(named: "ContextPanelTV"))
    #expect(appReleaseSettings["APS_ENVIRONMENT"] as? String == "production")
    #expect(appReleaseSettings["CODE_SIGN_IDENTITY"] as? String == "Apple Distribution")
    #expect(
        appReleaseSettings["PROVISIONING_PROFILE_SPECIFIER"] as? String
            == "$(CONTEXT_PANEL_APP_STORE_TV_PROFILE_SPECIFIER)"
    )

    let appDependencies = try #require(project.dependencies(named: "ContextPanelTV"))
    #expect(appDependencies == [
        "ContextPanelCoreTV",
        "ContextPanelCloudKitSyncTV",
        "ContextPanelTVSupport",
        "ContextPanelTVTopShelfExtension",
    ])
    #expect(!appDependencies.contains("ContextPanelWidgetUICompanion"))
    #expect(!appDependencies.contains("ContextPanelSettingsUICompanion"))
    #expect(!appDependencies.contains("ContextPanelCompanionWidgetExtension"))
    #expect(!appDependencies.contains("ContextPanelWatch"))
    let topShelfDependencySettings = try #require(
        project.dependencySettings(
            named: "ContextPanelTVTopShelfExtension",
            in: "ContextPanelTV"
        )
    )
    #expect(topShelfDependencySettings["embed"] as? String == "true")

    let plist = try loadInfoPlist("Config/ContextPanelTV-Info.plist")
    let urlTypes = try #require(plist["CFBundleURLTypes"] as? [[String: Any]])
    let schemes = urlTypes.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
    #expect(schemes == ["contextpaneltv"])
    #expect(plist["UIBackgroundModes"] as? [String] == ["remote-notification"])
    #expect(plist["UISupportedInterfaceOrientations"] == nil)
    #expect(plist["WKApplication"] == nil)

    let appEntitlements = try loadEntitlements("Config/ContextPanelTV.entitlements")
    #expect(appEntitlements["aps-environment"] as? String == "$(APS_ENVIRONMENT)")
    #expect(
        appEntitlements["com.apple.developer.icloud-container-identifiers"] as? [String]
            == ["iCloud.com.shinycomputers.contextpanel"]
    )
    #expect(appEntitlements["com.apple.developer.icloud-services"] as? [String] == ["CloudKit"])
    #expect(
        appEntitlements["com.apple.developer.user-management"] as? [String]
            == ["runs-as-current-user-with-user-independent-keychain"]
    )
    #expect(
        appEntitlements["com.apple.security.application-groups"] as? [String]
            == ["group.com.shinycomputers.contextpanel"]
    )
    #expect(appEntitlements["com.apple.developer.ubiquity-container-identifiers"] == nil)
    #expect(appEntitlements["keychain-access-groups"] == nil)

    let topShelfTarget = try #require(project.target(named: "ContextPanelTVTopShelfExtension"))
    #expect(topShelfTarget["type"] as? String == "app-extension")
    #expect(topShelfTarget["platform"] as? String == "tvOS")
    #expect(topShelfTarget["deploymentTarget"] as? String == "17.0")
    let topShelfSettings = try #require(project.targetSettings(named: "ContextPanelTVTopShelfExtension"))
    #expect(
        topShelfSettings["PRODUCT_BUNDLE_IDENTIFIER"] as? String
            == "com.shinycomputers.contextpanel.topshelf"
    )
    #expect(
        topShelfSettings["CODE_SIGN_ENTITLEMENTS"] as? String
            == "Config/ContextPanelTVTopShelf.entitlements"
    )
    #expect(
        topShelfSettings["INFOPLIST_FILE"] as? String
            == "Config/ContextPanelTVTopShelf-Info.plist"
    )
    #expect(topShelfSettings["TVOS_DEPLOYMENT_TARGET"] as? String == "17.0")
    #expect(topShelfSettings["TARGETED_DEVICE_FAMILY"] as? String == "3")
    #expect(topShelfSettings["SKIP_INSTALL"] as? String == "true")
    #expect(topShelfSettings["APPLICATION_EXTENSION_API_ONLY"] as? String == "true")
    let topShelfDependencies = try #require(project.dependencies(named: "ContextPanelTVTopShelfExtension"))
    #expect(topShelfDependencies == ["ContextPanelCoreTV", "ContextPanelTVSupport"])
    #expect(!topShelfDependencies.contains("ContextPanelCloudKitSyncTV"))

    let topShelfReleaseSettings = try #require(
        project.releaseTargetSettings(named: "ContextPanelTVTopShelfExtension")
    )
    #expect(topShelfReleaseSettings["CODE_SIGN_IDENTITY"] as? String == "Apple Distribution")
    #expect(
        topShelfReleaseSettings["PROVISIONING_PROFILE_SPECIFIER"] as? String
            == "$(CONTEXT_PANEL_APP_STORE_TV_TOP_SHELF_PROFILE_SPECIFIER)"
    )

    let topShelfPlist = try loadInfoPlist("Config/ContextPanelTVTopShelf-Info.plist")
    let topShelfExtension = try #require(topShelfPlist["NSExtension"] as? [String: Any])
    #expect(
        topShelfExtension["NSExtensionPointIdentifier"] as? String
            == "com.apple.tv-top-shelf"
    )
    #expect(
        topShelfExtension["NSExtensionPrincipalClass"] as? String
            == "$(PRODUCT_MODULE_NAME).ContextPanelTVTopShelfProvider"
    )
    #expect(topShelfPlist["UIRequiredDeviceCapabilities"] as? [String] == ["arm64"])

    let topShelfEntitlements = try loadEntitlements("Config/ContextPanelTVTopShelf.entitlements")
    #expect(
        topShelfEntitlements["com.apple.security.application-groups"] as? [String]
            == ["group.com.shinycomputers.contextpanel"]
    )
    #expect(
        topShelfEntitlements["com.apple.developer.user-management"] as? [String]
            == ["runs-as-current-user-with-user-independent-keychain"]
    )
    #expect(topShelfEntitlements["aps-environment"] == nil)
    #expect(topShelfEntitlements["com.apple.developer.icloud-container-identifiers"] == nil)
    #expect(topShelfEntitlements["com.apple.developer.icloud-services"] == nil)
}

@Test func refreshAgentDoesNotReferenceRetiredGoogleCredentialPaths() throws {
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appending(path: "Sources/ContextPanelRefreshAgent/ContextPanelRefreshAgent.swift")
    let source = try String(contentsOf: url, encoding: .utf8)

    #expect(source.contains("--ingest-antigravity-status-line"))
    #expect(source.contains("GoogleAntigravityStatusLineBridge.ingest"))
    #expect(!source.contains("allowsExternalGoogleKeychain"))
    #expect(!source.contains("GeminiQuotaProbe"))
    #expect(!source.contains("allowsLegacyGeminiOAuth"))
    #expect(!source.contains("antigravityCredentialSource"))
    #expect(!source.contains("oauth_creds.json"))
    #expect(!source.contains("daily-cloudcode-pa.googleapis.com"))
}

@Test func appAndRefreshAgentDoNotWriteRawErrorsToPublicLogs() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let appSource = try String(
        contentsOf: root.appending(path: "Sources/ContextPanelApp/ContextPanelApp.swift"),
        encoding: .utf8
    )
    let refreshAgentSource = try String(
        contentsOf: root.appending(path: "Sources/ContextPanelRefreshAgent/ContextPanelRefreshAgent.swift"),
        encoding: .utf8
    )

    #expect(!appSource.contains("error.localizedDescription, privacy: .public"))
    #expect(!refreshAgentSource.contains(#"\(error.localizedDescription)\n\", stderr"#))
    #expect(appSource.contains("ConnectorRedactor.safeErrorDescription(error)"))
    #expect(refreshAgentSource.contains("ConnectorRedactor.safeErrorDescription(error)"))
}

@Test func appRefreshRoutesWebhookWarningsAndProtectsActiveClaudeExchange() throws {
    let source = try String(
        contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: "Sources/ContextPanelApp/ContextPanelApp.swift"),
        encoding: .utf8
    )

    #expect(source.contains("let webhookService: LimitWarningWebhookDeliveryService"))
    #expect(source.contains("webhookService: .appDefault()"))
    #expect(source.contains("await webhookService.deliverIfNeeded(decision: decision)"))
    #expect(source.contains("recordWebhookDiagnostics(webhookResults"))
    #expect(source.contains(".interactiveDismissDisabled(model.isCompletingClaudeOAuth)"))
    #expect(source.contains("claudeOAuthCompletionTask?.cancel()"))
    #expect(source.contains("exchangeService.exchangeAndCommit("))
    #expect(source.contains("commitClaudeOAuthCredentials("))
    #expect(source.contains("deleteOAuthCredentials("))
    #expect(source.contains("service.updateConfiguration"))
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

private func expectProductionCloudKitEnvironment(_ entitlements: [String: Any]) {
    #expect(entitlements["com.apple.developer.icloud-container-environment"] as? String == "Production")
}

private func expectDevelopmentCloudKitEnvironment(_ entitlements: [String: Any]) {
    #expect(entitlements["com.apple.developer.icloud-container-environment"] as? String == "Development")
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

    func dependencySettings(named dependencyName: String, in targetName: String) -> [String: Any]? {
        guard let targetLine = firstLineIndex(matching: "  \(targetName):") else {
            return nil
        }
        guard let dependenciesLine = firstLineIndex(
            after: targetLine,
            matching: "    dependencies:",
            beforeIndentLessThan: 4
        ) else {
            return nil
        }

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
            if indent == 6, trimmed == "- target: \(dependencyName)" {
                return mapping(after: index, indentation: 8)
            }
            index += 1
        }
        return nil
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
