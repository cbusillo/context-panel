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
        self.assertIn(".companionApp(for: companionRuntimeDeviceClass())", app)
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
        self.assertIn("presentationDigest", receipt.split("var rateLimitKey", 1)[1])


if __name__ == "__main__":
    unittest.main()
