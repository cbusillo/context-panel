from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class RuntimeReceiptIntegrationTests(unittest.TestCase):
    def read(self, relative_path: str) -> str:
        return (ROOT / relative_path).read_text()

    def test_each_macos_process_authors_its_own_receipt(self) -> None:
        app = self.read("Sources/ContextPanelApp/ContextPanelApp.swift")
        widget = self.read("Sources/ContextPanelWidget/ContextPanelWidget.swift")
        refresh_agent = self.read(
            "Sources/ContextPanelRefreshAgent/ContextPanelRefreshAgent.swift"
        )

        self.assertIn(".appDefault(surface: .macOSApp)", app)
        self.assertIn("trigger: .appSnapshotLoad", app)
        self.assertIn(".appDefault(surface: .macOSWidget)", widget)
        self.assertIn("trigger: .widgetSnapshot", widget)
        self.assertIn("trigger: .widgetTimeline", widget)
        self.assertIn(".appDefault(surface: .macOSRefreshAgent)", refresh_agent)
        self.assertIn("runner.refreshWithEvidence()", refresh_agent)
        self.assertIn("runner.refreshIfNeededWithEvidence()", refresh_agent)
        self.assertIn("trigger: .refreshOnce", refresh_agent)
        self.assertIn("trigger: .backgroundRefresh", refresh_agent)

    def test_companion_app_and_widget_author_real_process_receipts(self) -> None:
        app = self.read("Sources/ContextPanelCompanion/ContextPanelCompanionApp.swift")
        widget = self.read(
            "Sources/ContextPanelCompanionWidget/ContextPanelCompanionWidget.swift"
        )
        store = self.read("Sources/ContextPanelCore/RuntimeReceiptStore.swift")

        self.assertIn(".appGroupRequired(", app)
        self.assertIn("let appSurface = RuntimeSurface.companionApp(for: deviceClass)", app)
        self.assertIn("ContextPanelLocations.companionAppGroupID", app)
        self.assertIn("CompanionRuntimeReceiptEvidence(", app)
        self.assertIn("trigger: .appSnapshotLoad", app)

        self.assertIn(".appGroupRequired(", widget)
        self.assertIn(".companionWidget(for: companionRuntimeDeviceClass())", widget)
        self.assertIn("ContextPanelLocations.companionAppGroupID", widget)
        self.assertIn("trigger: .widgetSnapshot", widget)
        self.assertIn("trigger: .widgetTimeline", widget)
        self.assertIn("case .systemExtraLarge", widget)
        self.assertIn("result: selection.result", widget)

        self.assertIn("sharedRuntimeValidationDirectory", store)
        self.assertIn("return RuntimeReceiptRecorder()", store)

    def test_watch_and_tv_surfaces_author_real_process_receipts(self) -> None:
        watch_app = self.read("Sources/ContextPanelWatch/ContextPanelWatchApp.swift")
        watch_widget = self.read(
            "Sources/ContextPanelWatchWidget/ContextPanelWatchWidget.swift"
        )
        tv_app = self.read("Sources/ContextPanelTV/ContextPanelTVApp.swift")
        top_shelf = self.read(
            "Sources/ContextPanelTVTopShelf/ContextPanelTVTopShelfProvider.swift"
        )
        companion_store = self.read("Sources/ContextPanelCore/CompanionSnapshot.swift")

        self.assertIn("surface: .watchOSApp", watch_app)
        self.assertIn("ContextPanelLocations.watchAppGroupID", watch_app)
        self.assertIn("loaded: loaded", watch_app)
        self.assertIn("presentationMode: .watchApp", watch_app)
        self.assertIn("loaded.disposition == .deadlineExceeded", watch_app)

        self.assertIn("surface: .watchOSComplication", watch_widget)
        self.assertIn("trigger: .widgetSnapshot", watch_widget)
        self.assertIn("trigger: .widgetTimeline", watch_widget)
        self.assertIn("loaded: loaded", watch_widget)
        self.assertIn("selection.current", watch_widget)
        self.assertIn("selection.loaded.disposition == .deadlineExceeded", watch_widget)
        self.assertIn("case .accessoryCircular", watch_widget)
        self.assertIn("case .accessoryRectangular", watch_widget)
        self.assertIn("case .accessoryInline", watch_widget)
        self.assertIn("case .accessoryCorner", watch_widget)

        self.assertIn("surface: .tvOSApp", tv_app)
        self.assertIn("result: model.displayResult", tv_app)
        self.assertIn("tvPresentationMode: publication.mode.runtimeTVPresentationMode", tv_app)
        self.assertIn("hasVisibleError: visibleNoticeMessage != nil", tv_app)
        self.assertIn(".onChange(of: runtimeReceiptPresentation", tv_app)
        self.assertIn("source: .localCache", tv_app)
        visible_notice = tv_app.split("private var visibleNoticeMessage", 1)[1].split(
            "private var backgroundUpdateNoticeMessage", 1
        )[0]
        self.assertIn("model.syncNoticeMessage", visible_notice)
        self.assertIn("backgroundUpdateNoticeMessage", visible_notice)
        self.assertIn("model.systemSurfaceNoticeMessage", visible_notice)
        self.assertIn("private let source: CompanionSyncSource?", companion_store)

        self.assertIn("surface: .tvOSTopShelf", top_shelf)
        self.assertIn("override func loadTopShelfContent()", top_shelf)
        self.assertIn("TVTopShelfRuntimeReceiptEvidence(", top_shelf)
        self.assertIn("trigger: .topShelfContentLoad", top_shelf)
        self.assertIn("contentReturned: false", top_shelf)
        self.assertIn("guard !Task.isCancelled else { return nil }", top_shelf)

    def test_receipt_schema_cannot_claim_visual_or_placement_evidence(self) -> None:
        receipt = self.read("Sources/ContextPanelCore/RuntimeReceipt.swift")

        self.assertIn('case actualRuntime = "actual-runtime"', receipt)
        self.assertNotIn("case sharedView", receipt)
        self.assertNotIn("case osCompositedPlacement", receipt)
        self.assertNotIn("localizedDescription", receipt)

    def test_receipt_transport_uses_only_the_canonical_app_group(self) -> None:
        store = self.read("Sources/ContextPanelCore/RuntimeReceiptStore.swift")

        self.assertIn("ContextPanelLocations.appGroupID", store)
        self.assertNotIn('group.com.shinycomputers.contextpanel"', store)

    def test_receipts_bind_loaded_code_and_reject_tampering(self) -> None:
        receipt = self.read("Sources/ContextPanelCore/RuntimeReceipt.swift")
        store = self.read("Sources/ContextPanelCore/RuntimeReceiptStore.swift")

        self.assertIn("_dyld_get_image_header(0)", receipt)
        self.assertIn("LC_UUID", receipt)
        self.assertIn("executableUUIDs", receipt)
        self.assertIn("receipt.isStructurallyValid", store)
        rate_limit_key = receipt.split("var rateLimitKey", 1)[1]
        self.assertIn("presentationDigest", rate_limit_key)
        self.assertIn("executableUUIDs", rate_limit_key)

    def test_entitled_hosts_relay_receipts_without_extension_upload_loops(self) -> None:
        app = self.read("Sources/ContextPanelApp/ContextPanelApp.swift")
        refresh_agent = self.read(
            "Sources/ContextPanelRefreshAgent/ContextPanelRefreshAgent.swift"
        )
        companion_app = self.read(
            "Sources/ContextPanelCompanion/ContextPanelCompanionApp.swift"
        )
        watch_app = self.read("Sources/ContextPanelWatch/ContextPanelWatchApp.swift")
        tv_app = self.read("Sources/ContextPanelTV/ContextPanelTVApp.swift")
        tv_delegate = self.read("Sources/ContextPanelTV/TVSystemSurfaces.swift")
        extensions = [
            self.read("Sources/ContextPanelWidget/ContextPanelWidget.swift"),
            self.read("Sources/ContextPanelCompanionWidget/ContextPanelCompanionWidget.swift"),
            self.read("Sources/ContextPanelWatchWidget/ContextPanelWatchWidget.swift"),
            self.read("Sources/ContextPanelTVTopShelf/ContextPanelTVTopShelfProvider.swift"),
        ]

        self.assertIn("RuntimeReceiptCloudKitStoreFactory.make()", app)
        self.assertIn("runtimeReceiptRelay.synchronize()", app)
        self.assertIn('"--sync-runtime-receipts"', refresh_agent)
        self.assertIn("RuntimeReceiptCloudKitStoreFactory.make()", refresh_agent)
        self.assertIn("runtimeReceiptRelay.synchronize()", refresh_agent)
        self.assertIn("RuntimeReceiptCloudKitStoreFactory.make()", companion_app)
        self.assertIn("synchronizeSession(now: now)", companion_app)
        self.assertIn("relayReceipts(now: Date())", companion_app)
        self.assertIn("RuntimeReceiptCloudKitStoreFactory.make()", watch_app)
        self.assertIn("eligibleSurfaces: [.watchOSApp, .watchOSComplication]", watch_app)
        self.assertIn("RuntimeReceiptCloudKitStoreFactory.make()", tv_app)
        self.assertIn("eligibleSurfaces: [.tvOSApp, .tvOSTopShelf]", tv_app)
        self.assertIn("runtimeReceiptRelay?.synchronize()", tv_delegate)
        for extension in extensions:
            self.assertNotIn("RuntimeReceiptCloudKitStoreFactory", extension)
            self.assertNotIn("relayReceipts", extension)

    def test_runtime_receipts_use_dedicated_cloudkit_records_without_subscriptions(self) -> None:
        relay = self.read(
            "Sources/ContextPanelCloudKitSync/RuntimeReceiptCloudKitSyncStore.swift"
        )
        core = self.read("Sources/ContextPanelCore/RuntimeReceiptRemoteSync.swift")
        companion = self.read(
            "Sources/ContextPanelCloudKitSync/CompanionCloudKitSyncStore.swift"
        )

        self.assertIn('cloudKitSessionRecordType = "RuntimeValidationSession"', core)
        self.assertIn('cloudKitReceiptRecordType = "RuntimeReceipt"', core)
        self.assertIn('recordName: "runtime-receipt-\\(receipt.id)"', relay)
        self.assertIn("retentionExpiresAtFieldName", relay)
        self.assertIn("allowsTruncatedResults: true", relay)
        self.assertNotIn("CKQuerySubscription", relay)
        self.assertIn("CKQuerySubscription", companion)


if __name__ == "__main__":
    unittest.main()
