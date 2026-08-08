from pathlib import Path
import re
import unittest


REPO_ROOT = Path(__file__).resolve().parents[2]
FIXTURE_SOURCE = REPO_ROOT / "Sources" / "ContextPanelValidationFixtures" / "ValidationFixtureCatalog.swift"
GALLERY_SOURCE_ROOT = REPO_ROOT / "Sources" / "ContextPanelValidationGalleryUI"
MAC_APP_SOURCE = REPO_ROOT / "Sources" / "ContextPanelApp" / "ContextPanelApp.swift"
COMPANION_APP_SOURCE = REPO_ROOT / "Sources" / "ContextPanelCompanion" / "ContextPanelCompanionApp.swift"
WATCH_APP_SOURCE = REPO_ROOT / "Sources" / "ContextPanelWatch" / "ContextPanelWatchApp.swift"
WATCH_GALLERY_SOURCE = REPO_ROOT / "Sources" / "ContextPanelWatch" / "WatchValidationGallery.swift"
WATCH_WIDGET_SOURCE = REPO_ROOT / "Sources" / "ContextPanelWatchWidget" / "ContextPanelWatchWidget.swift"
TV_APP_SOURCE = REPO_ROOT / "Sources" / "ContextPanelTV" / "ContextPanelTVApp.swift"
TV_GALLERY_SOURCE = REPO_ROOT / "Sources" / "ContextPanelTV" / "TVValidationGallery.swift"
TV_PREVIEW_SOURCE = REPO_ROOT / "Sources" / "ContextPanelTV" / "TVPreviewFixtures.swift"
TV_TOP_SHELF_SOURCE = (
    REPO_ROOT / "Sources" / "ContextPanelTVTopShelf" / "ContextPanelTVTopShelfProvider.swift"
)


class ValidationGalleryTargetGraphTests(unittest.TestCase):
    def test_fixture_source_is_foundation_only(self):
        source = FIXTURE_SOURCE.read_text()
        imports = re.findall(r"^import\s+(\S+)$", source, flags=re.MULTILINE)

        self.assertEqual(imports, ["Foundation"])
        for forbidden in (
            "CloudKit",
            "ContextPanelCore",
            "ContextPanelLocations",
            "ProviderCredentialStore",
            "RuntimeReceipt",
            "WidgetCenter",
        ):
            self.assertNotIn(forbidden, source)

    def test_fixture_targets_have_no_product_dependencies(self):
        package = (REPO_ROOT / "Package.swift").read_text()
        project = (REPO_ROOT / "project.yml").read_text()

        self.assertIn('.target(name: "ContextPanelValidationFixtures")', package)
        for target in (
            "ContextPanelValidationFixtures",
            "ContextPanelValidationFixturesCompanion",
            "ContextPanelValidationFixturesWatch",
            "ContextPanelValidationFixturesTV",
        ):
            block = self.yaml_target_block(project, target)
            self.assertNotIn("dependencies:", block)

    def test_gallery_targets_are_host_app_only(self):
        project = (REPO_ROOT / "project.yml").read_text()

        for target in (
            "ContextPanelWidgetExtension",
            "ContextPanelCompanionWidgetExtension",
            "ContextPanelWatchWidgetExtension",
            "ContextPanelTVTopShelfExtension",
        ):
            block = self.yaml_target_block(project, target)
            self.assertNotIn("ContextPanelValidation", block)

        mac_gallery = self.yaml_target_block(project, "ContextPanelValidationGalleryUI")
        companion_gallery = self.yaml_target_block(project, "ContextPanelValidationGalleryUICompanion")
        self.assertIn("ContextPanelValidationFixtures", mac_gallery)
        self.assertIn("ContextPanelValidationFixturesCompanion", companion_gallery)

    def test_gallery_adapter_has_no_live_storage_or_publication_imports(self):
        source = "\n".join(path.read_text() for path in sorted(GALLERY_SOURCE_ROOT.glob("*.swift")))

        for forbidden in (
            "import CloudKit",
            "import ContextPanelCloudKitSync",
            "ContextPanelLocations",
            "ProviderCredentialStore",
            "RuntimeReceiptRecorder",
            "WidgetCenter.shared",
        ):
            self.assertNotIn(forbidden, source)

    def test_host_galleries_reuse_production_presentations_and_disable_actions(self):
        gallery = "\n".join(path.read_text() for path in sorted(GALLERY_SOURCE_ROOT.glob("*.swift")))
        mac_app = MAC_APP_SOURCE.read_text()
        companion_app = COMPANION_APP_SOURCE.read_text()

        self.assertEqual(gallery.count(".allowsHitTesting(false)"), 2)
        self.assertIn("OverviewDashboard(", mac_app)
        self.assertIn("MainLimitDetail(", mac_app)
        self.assertIn("ReconnectDashboardLayout(", mac_app)
        self.assertIn("MacValidationDiagnosticsPreview", mac_app)
        self.assertIn("ContextPanelWidgetContentView(", companion_app)
        self.assertIn("CompanionKeepWorkingCard(", companion_app)
        self.assertIn("CompanionSyncStatusView(", companion_app)
        self.assertIn("CompanionWidgetMainLimitsSettingsView(", companion_app)
        self.assertIn("CompanionRefreshSettingsView(", companion_app)
        self.assertIn("supportedPresentations: [.overview, .settings, .diagnostics, .widget]", companion_app)

    def test_watch_gallery_reuses_shipping_views_without_live_loaders(self):
        project = (REPO_ROOT / "project.yml").read_text()
        watch_app = WATCH_APP_SOURCE.read_text()
        watch_gallery = WATCH_GALLERY_SOURCE.read_text()
        watch_widget = WATCH_WIDGET_SOURCE.read_text()
        watch_target = self.yaml_target_block(project, "ContextPanelWatch")
        watch_widget_target = self.yaml_target_block(project, "ContextPanelWatchWidgetExtension")

        self.assertIn("ContextPanelValidationFixturesWatch", watch_target)
        self.assertIn("ValidationGalleryFixtureAdapter.swift", watch_target)
        self.assertIn("WatchValidationFixtureAdapter.swift", watch_target)
        self.assertIn("ContextPanelWatchWidget.swift", watch_target)
        self.assertNotIn("CONTEXT_PANEL_WATCH_WIDGET_EXTENSION", watch_target)
        self.assertIn("WatchUsageContent(", watch_app)
        self.assertIn("ContextPanelWatchWidgetView(", watch_gallery)
        self.assertIn("family: family.widgetFamily", watch_gallery)
        self.assertIn("presentationDate: context.presentationDate", watch_gallery)
        self.assertIn("now: presentationDate", watch_app)
        self.assertIn("WatchValidationSampleContainer", watch_gallery)
        self.assertIn("ForEach(ContextPanelWatchComplicationFamily.allCases)", watch_gallery)
        self.assertIn("#if CONTEXT_PANEL_WATCH_WIDGET_EXTENSION", watch_widget)
        self.assertIn("CONTEXT_PANEL_WATCH_WIDGET_EXTENSION", watch_widget_target)
        self.assertIn(
            ".supportedFamilies(ContextPanelWatchWidgetView.supportedFamilies)",
            watch_widget,
        )

        guarded_regions = re.findall(
            r"#if CONTEXT_PANEL_WATCH_WIDGET_EXTENSION\n(.*?)#endif",
            watch_widget,
            flags=re.DOTALL,
        )
        guarded_source = "\n".join(guarded_regions)
        unguarded_source = re.sub(
            r"#if CONTEXT_PANEL_WATCH_WIDGET_EXTENSION\n.*?#endif",
            "",
            watch_widget,
            flags=re.DOTALL,
        )
        for protected_symbol in (
            "ContextPanelWatchWidgetProvider",
            "WatchWidgetLoadQueue",
            "CompanionCloudKitSyncStoreFactory",
            "RuntimeReceiptRecorder",
            "@main",
            "ContextPanelWatchWidgetBundle",
        ):
            self.assertIn(protected_symbol, guarded_source)
            self.assertNotIn(protected_symbol, unguarded_source)

        for forbidden in (
            "WatchSyncModel(",
            "WatchCompanionLoader(",
            "WatchCompanionCache(",
            "CompanionCloudKitSyncStoreFactory",
            "RuntimeReceiptRecorder",
            "WidgetCenter.shared",
        ):
            self.assertNotIn(forbidden, watch_gallery)

    def test_tv_gallery_reuses_shipping_views_without_publication_paths(self):
        project = (REPO_ROOT / "project.yml").read_text()
        tv_app = TV_APP_SOURCE.read_text()
        tv_gallery = TV_GALLERY_SOURCE.read_text()
        tv_preview = TV_PREVIEW_SOURCE.read_text()
        top_shelf = TV_TOP_SHELF_SOURCE.read_text()
        tv_target = self.yaml_target_block(project, "ContextPanelTV")
        top_shelf_target = self.yaml_target_block(project, "ContextPanelTVTopShelfExtension")

        self.assertIn("ContextPanelValidationFixturesTV", tv_target)
        self.assertIn("ValidationGalleryFixtureAdapter.swift", tv_target)
        self.assertIn("TVValidationFixtureAdapter.swift", tv_target)
        self.assertIn("ContextPanelTVTopShelfProvider.swift", tv_target)
        self.assertNotIn("CONTEXT_PANEL_TV_TOP_SHELF_EXTENSION", tv_target)
        self.assertIn("CONTEXT_PANEL_TV_TOP_SHELF_EXTENSION", top_shelf_target)
        self.assertNotIn("ContextPanelValidation", top_shelf_target)

        self.assertIn("TVRunwayContent(", tv_app)
        self.assertIn("TVRunwayContent(", tv_gallery)
        self.assertIn("TVProviderDetailView(", tv_gallery)
        self.assertIn("TVTopShelfRenderer()", tv_gallery)
        self.assertIn(".imageData(", tv_gallery)
        self.assertIn("presentationDate: context.presentationDate", tv_gallery)
        self.assertIn("SAMPLE DATA", tv_gallery)
        self.assertIn("READ ONLY", tv_gallery)
        self.assertIn("detailActionMode: .readOnly", tv_gallery)
        self.assertIn(".accessibilityElement(children: .contain)", tv_gallery)
        self.assertNotIn(".disabled(true)", tv_gallery)
        self.assertNotIn("@AppStorage", tv_gallery)

        for forbidden in (
            "TVSyncModel(",
            "CompanionCloudKitSyncStoreFactory",
            "CompanionSyncStore(",
            "TVSyncReceiptStore(",
            "TVSystemSurfaceCoordinator",
            "TVTopShelfDocumentStore",
            "TVTopShelfSharedLocations",
            "RuntimeReceiptRecorder",
            "RuntimeReceiptRelayCoordinator",
            "topShelfContentDidChange",
            "TVLocalCacheLocations",
        ):
            self.assertNotIn(forbidden, tv_gallery)

        guard_pattern = re.compile(
            r"#if CONTEXT_PANEL_TV_TOP_SHELF_EXTENSION\n"
            r"(.*?)(?:#else\n(.*?))?#endif",
            flags=re.DOTALL,
        )
        guarded_regions = [
            match.group(1)
            for match in guard_pattern.finditer(top_shelf)
        ]
        guarded_source = "\n".join(guarded_regions)
        unguarded_source = guard_pattern.sub(
            lambda match: match.group(2) or "",
            top_shelf,
        )
        for protected_symbol in (
            "ContextPanelTVTopShelfProvider",
            "TVTopShelfDocumentStore",
            "TVTopShelfSharedLocations",
            "RuntimeReceiptRecorder",
            "setImageURL",
            "write(to:",
        ):
            self.assertIn(protected_symbol, guarded_source)
            self.assertNotIn(protected_symbol, unguarded_source)
        for shared_symbol in ("imageData", "render(", "semanticTitle"):
            self.assertIn(shared_symbol, unguarded_source)

        self.assertNotRegex(
            tv_preview,
            r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b",
        )
        self.assertIn("Sample OpenAI Personal", tv_preview)

    @staticmethod
    def yaml_target_block(project: str, target: str) -> str:
        lines = project.splitlines()
        marker = f"  {target}:"
        start = lines.index(marker)
        end = len(lines)
        for index in range(start + 1, len(lines)):
            line = lines[index]
            if line.startswith("  ") and len(line) > 2 and not line[2].isspace():
                end = index
                break
        return "\n".join(lines[start:end])


if __name__ == "__main__":
    unittest.main()
