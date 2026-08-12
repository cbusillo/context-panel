import Darwin
import Foundation
import Testing

@Test func appStoreEntitlementsSupportSandboxedProviderRefreshes() throws {
    try expectAppStoreProviderRefreshEntitlements("Config/ContextPanelAppStore.entitlements")
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
    try expectAppStoreProviderRefreshEntitlements(
        "Config/ContextPanelRefreshAgentAppStore.entitlements"
    )
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

@Test func companionEntitlementsSupportCloudKitAndSharedMirror() throws {
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
    #expect(
        widgetEntitlements["com.apple.developer.icloud-container-identifiers"] as? [String]
            == ["iCloud.com.shinycomputers.contextpanel"]
    )
    #expect(widgetEntitlements["com.apple.developer.icloud-services"] as? [String] == ["CloudKit"])
    #expect(
        widgetEntitlements["com.apple.developer.icloud-container-environment"] as? String
            == "Development"
    )
    #expect(widgetEntitlements["com.apple.developer.ubiquity-container-identifiers"] == nil)
    #expect(widgetEntitlements["aps-environment"] == nil)

    let appStoreWidgetEntitlements = try loadEntitlements(
        "Config/ContextPanelCompanionWidgetAppStore.entitlements"
    )
    #expect(
        appStoreWidgetEntitlements["com.apple.security.application-groups"] as? [String]
            == ["group.com.shinycomputers.contextpanel"]
    )
    #expect(
        appStoreWidgetEntitlements["com.apple.developer.icloud-container-identifiers"] as? [String]
            == ["iCloud.com.shinycomputers.contextpanel"]
    )
    #expect(
        appStoreWidgetEntitlements["com.apple.developer.icloud-services"] as? [String]
            == ["CloudKit"]
    )
    #expect(
        appStoreWidgetEntitlements["com.apple.developer.icloud-container-environment"] as? String
            == "Production"
    )
    #expect(appStoreWidgetEntitlements["com.apple.developer.ubiquity-container-identifiers"] == nil)
    #expect(appStoreWidgetEntitlements["aps-environment"] == nil)
}

@Test func watchAppAndWidgetShareLocalCacheAndReadCloudKit() throws {
    let appEntitlements = try loadEntitlements("Config/ContextPanelWatch.entitlements")
    let iCloudContainers = try #require(
        appEntitlements["com.apple.developer.icloud-container-identifiers"] as? [String]
    )
    #expect(iCloudContainers == ["iCloud.com.shinycomputers.contextpanel"])
    let services = try #require(appEntitlements["com.apple.developer.icloud-services"] as? [String])
    #expect(services == ["CloudKit"])
    #expect(appEntitlements["com.apple.developer.icloud-container-environment"] as? String == "Development")
    #expect(
        appEntitlements["com.apple.security.application-groups"] as? [String]
            == ["group.com.shinycomputers.contextpanel"]
    )
    #expect(appEntitlements["aps-environment"] == nil)
    #expect(appEntitlements["keychain-access-groups"] == nil)
    #expect(appEntitlements["com.apple.developer.ubiquity-container-identifiers"] == nil)

    let widgetEntitlements = try loadEntitlements("Config/ContextPanelWatchWidget.entitlements")
    #expect(
        widgetEntitlements["com.apple.security.application-groups"] as? [String]
            == ["group.com.shinycomputers.contextpanel"]
    )
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
    #expect(
        appStoreAppEntitlements["com.apple.security.application-groups"] as? [String]
            == ["group.com.shinycomputers.contextpanel"]
    )

    let appStoreWidgetEntitlements = try loadEntitlements(
        "Config/ContextPanelWatchWidgetAppStore.entitlements"
    )
    #expect(
        appStoreWidgetEntitlements["com.apple.developer.icloud-container-environment"] as? String
            == "Production"
    )
    #expect(
        appStoreWidgetEntitlements["com.apple.security.application-groups"] as? [String]
            == ["group.com.shinycomputers.contextpanel"]
    )
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
    let project = try loadProjectSpec()

    let appTarget = try #require(project.target(named: "ContextPanelCompanion"))
    #expect(appTarget["supportedDestinations"]?.stringArray == ["iOS", "visionOS"])

    let appSettings = try #require(project.targetSettings(named: "ContextPanelCompanion"))
    #expect(appSettings["PRODUCT_BUNDLE_IDENTIFIER"]?.string == "com.shinycomputers.contextpanel")
    #expect(appSettings["CODE_SIGN_ENTITLEMENTS"]?.string == "Config/ContextPanelCompanion.entitlements")
    #expect(appSettings["TARGETED_DEVICE_FAMILY"]?.string == "1,2,7")
    #expect(appSettings["XROS_DEPLOYMENT_TARGET"]?.string == "26.0")
    #expect(appSettings["APS_ENVIRONMENT"]?.string == "development")
    let appReleaseSettings = try #require(project.releaseTargetSettings(named: "ContextPanelCompanion"))
    #expect(appReleaseSettings["APS_ENVIRONMENT"]?.string == "production")
    #expect(appReleaseSettings["CODE_SIGN_IDENTITY"]?.string == "Apple Distribution")
    #expect(
        appReleaseSettings["PROVISIONING_PROFILE_SPECIFIER"]?.string
            == "$(CONTEXT_PANEL_APP_STORE_COMPANION_PROFILE_SPECIFIER)"
    )

    let widgetTarget = try #require(project.target(named: "ContextPanelCompanionWidgetExtension"))
    #expect(widgetTarget["supportedDestinations"]?.stringArray == ["iOS", "visionOS"])

    let widgetSettings = try #require(project.targetSettings(named: "ContextPanelCompanionWidgetExtension"))
    #expect(
        widgetSettings["PRODUCT_BUNDLE_IDENTIFIER"]?.string
            == "com.shinycomputers.contextpanel.widget"
    )
    #expect(
        widgetSettings["CODE_SIGN_ENTITLEMENTS"]?.string
            == "Config/ContextPanelCompanionWidget.entitlements"
    )
    #expect(widgetSettings["TARGETED_DEVICE_FAMILY"]?.string == "1,2,7")
    #expect(widgetSettings["XROS_DEPLOYMENT_TARGET"]?.string == "26.0")
    let widgetReleaseSettings = try #require(
        project.releaseTargetSettings(named: "ContextPanelCompanionWidgetExtension")
    )
    #expect(widgetReleaseSettings["CODE_SIGN_IDENTITY"]?.string == "Apple Distribution")
    #expect(
        widgetReleaseSettings["CODE_SIGN_ENTITLEMENTS"]?.string
            == "Config/ContextPanelCompanionWidgetAppStore.entitlements"
    )
    #expect(
        widgetReleaseSettings["PROVISIONING_PROFILE_SPECIFIER"]?.string
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
    #expect(widgetDependencies.contains("ContextPanelCloudKitSyncCompanion"))

    let plist = try loadInfoPlist("Config/ContextPanelCompanion-Info.plist")
    let backgroundModes = try #require(plist["UIBackgroundModes"] as? [String])
    #expect(backgroundModes == ["remote-notification"])
    let sceneManifest = try #require(plist["UIApplicationSceneManifest"] as? [String: Any])
    #expect(sceneManifest["UIApplicationPreferredDefaultSceneSessionRole"] as? String == "UIWindowSceneSessionRoleApplication")
    #expect(sceneManifest["UIApplicationSupportsMultipleScenes"] as? Bool == true)
}

@Test func watchProjectTargetUsesDistinctReadOnlyCompanionSurface() throws {
    let project = try loadProjectSpec()

    let coreTarget = try #require(project.target(named: "ContextPanelCoreWatch"))
    #expect(coreTarget["platform"]?.string == "watchOS")
    let coreSettings = try #require(project.targetSettings(named: "ContextPanelCoreWatch"))
    #expect(coreSettings["PRODUCT_MODULE_NAME"]?.string == "ContextPanelCore")
    #expect(coreSettings["WATCHOS_DEPLOYMENT_TARGET"]?.string == "10.0")

    let cloudKitTarget = try #require(project.target(named: "ContextPanelCloudKitSyncWatch"))
    #expect(cloudKitTarget["platform"]?.string == "watchOS")
    let cloudKitDependencies = try #require(project.dependencies(named: "ContextPanelCloudKitSyncWatch"))
    #expect(cloudKitDependencies == ["ContextPanelCoreWatch"])

    let appTarget = try #require(project.target(named: "ContextPanelWatch"))
    #expect(appTarget["platform"]?.string == "watchOS")
    #expect(appTarget["deploymentTarget"]?.string == "10.0")

    let appSettings = try #require(project.targetSettings(named: "ContextPanelWatch"))
    #expect(appSettings["PRODUCT_BUNDLE_IDENTIFIER"]?.string == "com.shinycomputers.contextpanel.watch")
    #expect(appSettings["CODE_SIGN_ENTITLEMENTS"]?.string == "Config/ContextPanelWatch.entitlements")
    #expect(appSettings["INFOPLIST_FILE"]?.string == "Config/ContextPanelWatch-Info.plist")
    #expect(appSettings["WATCHOS_DEPLOYMENT_TARGET"]?.string == "10.0")
    #expect(appSettings["ASSETCATALOG_COMPILER_APPICON_NAME"]?.string == "AppIcon")
    #expect(appSettings["SKIP_INSTALL"]?.bool == true)
    #expect(appSettings["TARGETED_DEVICE_FAMILY"] == nil)
    #expect(appSettings["APS_ENVIRONMENT"] == nil)

    let appReleaseSettings = try #require(project.releaseTargetSettings(named: "ContextPanelWatch"))
    #expect(appReleaseSettings["CODE_SIGN_IDENTITY"]?.string == "Apple Distribution")
    #expect(
        appReleaseSettings["CODE_SIGN_ENTITLEMENTS"]?.string
            == "Config/ContextPanelWatchAppStore.entitlements"
    )
    #expect(
        appReleaseSettings["PROVISIONING_PROFILE_SPECIFIER"]?.string
            == "$(CONTEXT_PANEL_APP_STORE_WATCH_PROFILE_SPECIFIER)"
    )

    let appDependencies = try #require(project.dependencies(named: "ContextPanelWatch"))
    #expect(appDependencies == [
        "ContextPanelCoreWatch",
        "ContextPanelCloudKitSyncWatch",
        "ContextPanelValidationFixturesWatch",
        "ContextPanelWatchWidgetExtension",
    ])
    #expect(!appDependencies.contains("ContextPanelCompanionSupport"))
    #expect(!appDependencies.contains("ContextPanelCompanionWidgetExtension"))

    let watchWidgetTarget = try #require(project.target(named: "ContextPanelWatchWidgetExtension"))
    #expect(watchWidgetTarget["platform"]?.string == "watchOS")
    #expect(watchWidgetTarget["type"]?.string == "app-extension")
    let watchWidgetSettings = try #require(project.targetSettings(named: "ContextPanelWatchWidgetExtension"))
    #expect(
        watchWidgetSettings["PRODUCT_BUNDLE_IDENTIFIER"]?.string
            == "com.shinycomputers.contextpanel.watch.widget"
    )
    #expect(
        watchWidgetSettings["CODE_SIGN_ENTITLEMENTS"]?.string
            == "Config/ContextPanelWatchWidget.entitlements"
    )
    #expect(watchWidgetSettings["WATCHOS_DEPLOYMENT_TARGET"]?.string == "10.0")
    #expect(watchWidgetSettings["SKIP_INSTALL"]?.bool == true)
    let watchWidgetReleaseSettings = try #require(
        project.releaseTargetSettings(named: "ContextPanelWatchWidgetExtension")
    )
    #expect(watchWidgetReleaseSettings["CODE_SIGN_IDENTITY"]?.string == "Apple Distribution")
    #expect(
        watchWidgetReleaseSettings["CODE_SIGN_ENTITLEMENTS"]?.string
            == "Config/ContextPanelWatchWidgetAppStore.entitlements"
    )
    #expect(
        watchWidgetReleaseSettings["PROVISIONING_PROFILE_SPECIFIER"]?.string
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
    let project = try loadProjectSpec()

    let coreTarget = try #require(project.target(named: "ContextPanelCoreTV"))
    #expect(coreTarget["platform"]?.string == "tvOS")
    #expect(coreTarget["deploymentTarget"]?.string == "17.0")
    let coreSettings = try #require(project.targetSettings(named: "ContextPanelCoreTV"))
    #expect(coreSettings["PRODUCT_MODULE_NAME"]?.string == "ContextPanelCore")
    #expect(coreSettings["TVOS_DEPLOYMENT_TARGET"]?.string == "17.0")

    let cloudKitTarget = try #require(project.target(named: "ContextPanelCloudKitSyncTV"))
    #expect(cloudKitTarget["platform"]?.string == "tvOS")
    let cloudKitDependencies = try #require(project.dependencies(named: "ContextPanelCloudKitSyncTV"))
    #expect(cloudKitDependencies == ["ContextPanelCoreTV"])

    let supportTarget = try #require(project.target(named: "ContextPanelTVSupport"))
    #expect(supportTarget["platform"]?.string == "tvOS")
    let supportDependencies = try #require(project.dependencies(named: "ContextPanelTVSupport"))
    #expect(supportDependencies == ["ContextPanelCoreTV"])

    let validationTarget = try #require(project.target(named: "ContextPanelValidationFixturesTV"))
    #expect(validationTarget["platform"]?.string == "tvOS")
    #expect(project.dependencies(named: "ContextPanelValidationFixturesTV") == [])

    let appTarget = try #require(project.target(named: "ContextPanelTV"))
    #expect(appTarget["platform"]?.string == "tvOS")
    #expect(appTarget["deploymentTarget"]?.string == "17.0")

    let appSettings = try #require(project.targetSettings(named: "ContextPanelTV"))
    #expect(appSettings["PRODUCT_BUNDLE_IDENTIFIER"]?.string == "com.shinycomputers.contextpanel")
    #expect(appSettings["CODE_SIGN_ENTITLEMENTS"]?.string == "Config/ContextPanelTV.entitlements")
    #expect(appSettings["INFOPLIST_FILE"]?.string == "Config/ContextPanelTV-Info.plist")
    #expect(appSettings["TVOS_DEPLOYMENT_TARGET"]?.string == "17.0")
    #expect(appSettings["TARGETED_DEVICE_FAMILY"]?.string == "3")
    #expect(appSettings["ASSETCATALOG_COMPILER_APPICON_NAME"]?.string == "App Icon & Top Shelf Image")
    #expect(appSettings["APS_ENVIRONMENT"]?.string == "development")

    let appReleaseSettings = try #require(project.releaseTargetSettings(named: "ContextPanelTV"))
    #expect(appReleaseSettings["APS_ENVIRONMENT"]?.string == "production")
    #expect(appReleaseSettings["CODE_SIGN_IDENTITY"]?.string == "Apple Distribution")
    #expect(
        appReleaseSettings["PROVISIONING_PROFILE_SPECIFIER"]?.string
            == "$(CONTEXT_PANEL_APP_STORE_TV_PROFILE_SPECIFIER)"
    )

    let appDependencies = try #require(project.dependencies(named: "ContextPanelTV"))
    #expect(appDependencies == [
        "ContextPanelCoreTV",
        "ContextPanelCloudKitSyncTV",
        "ContextPanelTVSupport",
        "ContextPanelValidationFixturesTV",
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
    #expect(topShelfDependencySettings["embed"]?.bool == true)

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
    #expect(topShelfTarget["type"]?.string == "app-extension")
    #expect(topShelfTarget["platform"]?.string == "tvOS")
    #expect(topShelfTarget["deploymentTarget"]?.string == "17.0")
    let topShelfSettings = try #require(project.targetSettings(named: "ContextPanelTVTopShelfExtension"))
    #expect(
        topShelfSettings["PRODUCT_BUNDLE_IDENTIFIER"]?.string
            == "com.shinycomputers.contextpanel.topshelf"
    )
    #expect(
        topShelfSettings["CODE_SIGN_ENTITLEMENTS"]?.string
            == "Config/ContextPanelTVTopShelf.entitlements"
    )
    #expect(
        topShelfSettings["INFOPLIST_FILE"]?.string
            == "Config/ContextPanelTVTopShelf-Info.plist"
    )
    #expect(topShelfSettings["TVOS_DEPLOYMENT_TARGET"]?.string == "17.0")
    #expect(topShelfSettings["TARGETED_DEVICE_FAMILY"]?.string == "3")
    #expect(topShelfSettings["SKIP_INSTALL"]?.bool == true)
    #expect(topShelfSettings["APPLICATION_EXTENSION_API_ONLY"]?.bool == true)
    #expect(
        topShelfSettings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"]?.string?
            .contains("CONTEXT_PANEL_TV_TOP_SHELF_EXTENSION") == true
    )
    #expect(
        topShelfSettings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"]?.string?
            .contains("$(inherited)") == true
    )
    let topShelfDependencies = try #require(project.dependencies(named: "ContextPanelTVTopShelfExtension"))
    #expect(topShelfDependencies == ["ContextPanelCoreTV", "ContextPanelTVSupport"])
    #expect(!topShelfDependencies.contains("ContextPanelCloudKitSyncTV"))

    let topShelfReleaseSettings = try #require(
        project.releaseTargetSettings(named: "ContextPanelTVTopShelfExtension")
    )
    #expect(topShelfReleaseSettings["CODE_SIGN_IDENTITY"]?.string == "Apple Distribution")
    #expect(
        topShelfReleaseSettings["PROVISIONING_PROFILE_SPECIFIER"]?.string
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
    let appSource = try FileManager.default.contentsOfDirectory(
        at: root.appending(path: "Sources/ContextPanelApp"),
        includingPropertiesForKeys: nil
    )
    .filter { $0.pathExtension == "swift" }
    .map { try String(contentsOf: $0, encoding: .utf8) }
    .joined(separator: "\n")
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
    let project = try loadProjectSpec()

    for targetName in ["ContextPanel", "ContextPanelRefreshAgent"] {
        let configurations = try #require(project.allTargetSettings(named: targetName))
        for settings in configurations {
            #expect(settings.keys.allSatisfy { !$0.hasPrefix("CONTEXT_PANEL_GOOGLE_") })
        }
    }

    let refreshAgentSettings = try #require(
        project.targetSettings(named: "ContextPanelRefreshAgent")
    )
    #expect(refreshAgentSettings["GENERATE_INFOPLIST_FILE"]?.bool == false)
    #expect(
        refreshAgentSettings["INFOPLIST_FILE"]?.string
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

private func expectAppStoreProviderRefreshEntitlements(_ path: String) throws {
    let entitlements = try loadEntitlements(path)
    #expect(entitlements["com.apple.security.app-sandbox"] as? Bool == true)
    #expect(entitlements["com.apple.security.network.client"] as? Bool == true)
    #expect(entitlements["com.apple.security.network.server"] == nil)
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

private func loadProjectSpec() throws -> ProjectSpec {
    try ProjectSpecCache.outcome.get()
}

private enum ProjectSpecCache {
    static let outcome: Result<ProjectSpec, ProjectSpecError> = {
        do {
            return .success(try ProjectSpec.load())
        } catch let error as ProjectSpecError {
            return .failure(error)
        } catch {
            return .failure(.unexpected(String(describing: error)))
        }
    }()
}

private struct ProjectSpec: Sendable {
    private static let readerTimeout: TimeInterval = 15
    private let targets: [String: ProjectSpecValue]

    static func load(timeout: TimeInterval = readerTimeout) throws -> ProjectSpec {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let projectURL = root.appending(path: "project.yml")
        let readerURL = root.appending(path: "scripts/context-panel-project-spec-json.rb")
        guard FileManager.default.fileExists(atPath: projectURL.path) else {
            throw ProjectSpecError.missingFile("project.yml")
        }
        guard FileManager.default.fileExists(atPath: readerURL.path) else {
            throw ProjectSpecError.missingFile("scripts/context-panel-project-spec-json.rb")
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appending(path: "context-panel-project-spec-\(UUID().uuidString).json")
        let errorURL = FileManager.default.temporaryDirectory
            .appending(path: "context-panel-project-spec-\(UUID().uuidString).err")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        defer {
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: errorURL)
        }

        let outputHandle = try FileHandle(forWritingTo: outputURL)
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        defer {
            try? outputHandle.close()
            try? errorHandle.close()
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ruby")
        process.arguments = [readerURL.path, "--project", projectURL.path]
        process.currentDirectoryURL = root
        process.standardOutput = outputHandle
        process.standardError = errorHandle

        let completion = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completion.signal() }
        do {
            try process.run()
        } catch {
            throw ProjectSpecError.launchFailed(String(describing: error))
        }

        if completion.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if completion.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = completion.wait(timeout: .now() + 1)
            }
            throw ProjectSpecError.timedOut(timeout)
        }

        let errorData = try Data(contentsOf: errorURL)
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let errorText = String(decoding: errorData.prefix(2_000), as: UTF8.self)
                .replacingOccurrences(of: root.path, with: "<repo>")
            throw ProjectSpecError.readerFailed(process.terminationStatus, errorText)
        }

        let outputData = try Data(contentsOf: outputURL)
        let payload: ProjectSpecPayload
        do {
            payload = try JSONDecoder().decode(ProjectSpecPayload.self, from: outputData)
        } catch {
            throw ProjectSpecError.invalidJSON(String(describing: error))
        }
        guard payload.schemaVersion == 1 else {
            throw ProjectSpecError.unsupportedSchema(payload.schemaVersion)
        }
        guard case let .object(targets)? = payload.project["targets"] else {
            throw ProjectSpecError.missingTargets
        }
        return ProjectSpec(targets: targets)
    }

    func target(named targetName: String) -> [String: ProjectSpecValue]? {
        targets[targetName]?.object
    }

    func targetSettings(named targetName: String) -> [String: ProjectSpecValue]? {
        settings(named: targetName)?["base"]?.object
    }

    func releaseTargetSettings(named targetName: String) -> [String: ProjectSpecValue]? {
        settings(named: targetName)?["configs"]?.object?["Release"]?.object
    }

    func allTargetSettings(named targetName: String) -> [[String: ProjectSpecValue]]? {
        guard let settings = settings(named: targetName) else { return nil }
        let supportedKeys = Set(["base", "configs"])
        guard Set(settings.keys).isSubset(of: supportedKeys) else { return nil }
        var configurations = settings["base"]?.object.map { [$0] } ?? []
        if let configuredValues = settings["configs"]?.object?.values {
            let configured = configuredValues.compactMap(\.object)
            guard configured.count == configuredValues.count else { return nil }
            configurations.append(contentsOf: configured)
        }
        return configurations
    }

    func dependencies(named targetName: String) -> [String]? {
        guard let target = target(named: targetName) else { return nil }
        guard let dependencies = target["dependencies"]?.array else { return [] }
        let names = dependencies.compactMap { $0.object?["target"]?.string }
        return names.count == dependencies.count ? names : nil
    }

    func dependencySettings(
        named dependencyName: String,
        in targetName: String
    ) -> [String: ProjectSpecValue]? {
        target(named: targetName)?["dependencies"]?.array?
            .compactMap(\.object)
            .first { $0["target"]?.string == dependencyName }
    }

    private func settings(named targetName: String) -> [String: ProjectSpecValue]? {
        target(named: targetName)?["settings"]?.object
    }
}

private struct ProjectSpecPayload: Decodable, Sendable {
    let schemaVersion: Int
    let project: [String: ProjectSpecValue]
}

private enum ProjectSpecValue: Decodable, Sendable {
    case string(String)
    case bool(Bool)
    case number(Double)
    case object([String: ProjectSpecValue])
    case array([ProjectSpecValue])
    case null

    var string: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    var bool: Bool? {
        guard case let .bool(value) = self else { return nil }
        return value
    }

    var object: [String: ProjectSpecValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    var array: [ProjectSpecValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    var stringArray: [String]? {
        guard let array else { return nil }
        let values = array.compactMap(\.string)
        return values.count == array.count ? values : nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode([String: ProjectSpecValue].self) {
            self = .object(value)
        } else {
            self = .array(try container.decode([ProjectSpecValue].self))
        }
    }
}

private enum ProjectSpecError: Error, CustomStringConvertible, Sendable {
    case missingFile(String)
    case launchFailed(String)
    case timedOut(TimeInterval)
    case readerFailed(Int32, String)
    case invalidJSON(String)
    case unsupportedSchema(Int)
    case missingTargets
    case unexpected(String)

    var description: String {
        switch self {
        case let .missingFile(path):
            "Project specification input is missing: \(path)"
        case let .launchFailed(message):
            "Project specification reader could not launch: \(message)"
        case let .timedOut(timeout):
            "Project specification reader exceeded the \(timeout)-second deadline"
        case let .readerFailed(status, errorText):
            "Project specification reader exited with status \(status): \(errorText)"
        case let .invalidJSON(message):
            "Project specification reader returned invalid JSON: \(message)"
        case let .unsupportedSchema(version):
            "Project specification reader returned unsupported schema \(version)"
        case .missingTargets:
            "Project specification reader returned no targets"
        case let .unexpected(message):
            "Project specification reader failed unexpectedly: \(message)"
        }
    }
}
