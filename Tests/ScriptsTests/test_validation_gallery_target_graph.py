from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

from context_panel_validation.shared_view_evidence import (
    COMPANION_GALLERY_PRESENTATIONS,
    FIXTURE_IDS,
    GALLERY_APPEARANCES,
    GALLERY_FAMILIES,
    GALLERY_PRESENTATIONS,
    MAC_GALLERY_PRESENTATIONS,
    TV_GALLERY_SURFACES,
    TV_PRESENTATIONS,
    WATCH_COMPLICATION_FAMILIES,
)


FIXTURE_SOURCE = REPO_ROOT / "Sources" / "ContextPanelValidationFixtures" / "ValidationFixtureCatalog.swift"
GALLERY_SOURCE_ROOT = REPO_ROOT / "Sources" / "ContextPanelValidationGalleryUI"
GALLERY_ROUTE_SOURCE = GALLERY_SOURCE_ROOT / "ValidationGalleryRoute.swift"
MAC_APP_SOURCE = REPO_ROOT / "Sources" / "ContextPanelApp" / "ContextPanelApp.swift"
COMPANION_APP_SOURCE = REPO_ROOT / "Sources" / "ContextPanelCompanion" / "ContextPanelCompanionApp.swift"
WATCH_APP_SOURCE = REPO_ROOT / "Sources" / "ContextPanelWatch" / "ContextPanelWatchApp.swift"
WATCH_GALLERY_SOURCE = REPO_ROOT / "Sources" / "ContextPanelWatch" / "WatchValidationGallery.swift"
WATCH_WIDGET_SOURCE = REPO_ROOT / "Sources" / "ContextPanelWatchWidget" / "ContextPanelWatchWidget.swift"
TV_APP_SOURCE = REPO_ROOT / "Sources" / "ContextPanelTV" / "ContextPanelTVApp.swift"
TV_GALLERY_SOURCE = REPO_ROOT / "Sources" / "ContextPanelTV" / "TVValidationGallery.swift"
TV_PREVIEW_SOURCE = REPO_ROOT / "Sources" / "ContextPanelTV" / "TVPreviewFixtures.swift"
TV_RUNWAY_PRESENTATION_SOURCE = (
    REPO_ROOT / "Sources" / "ContextPanelTVSupport" / "TVRunwayPresentation.swift"
)
TV_TOP_SHELF_SOURCE = (
    REPO_ROOT / "Sources" / "ContextPanelTVTopShelf" / "ContextPanelTVTopShelfProvider.swift"
)
SHARED_VIEW_EVIDENCE_SOURCE = REPO_ROOT / "scripts" / "context_panel_validation" / "shared_view_evidence.py"
VALIDATION_CLI_SOURCE = REPO_ROOT / "scripts" / "context_panel_validation" / "cli.py"
VALIDATION_ENTRY_POINT = REPO_ROOT / "scripts" / "context-panel-validation.py"


class ValidationGalleryTargetGraphTests(unittest.TestCase):
    def test_shared_view_vocabularies_match_swift_gallery_contracts(self):
        fixture_source = FIXTURE_SOURCE.read_text()
        route_source = GALLERY_ROUTE_SOURCE.read_text()
        watch_widget_source = WATCH_WIDGET_SOURCE.read_text()
        tv_gallery_source = TV_GALLERY_SOURCE.read_text()
        tv_presentation_source = TV_RUNWAY_PRESENTATION_SOURCE.read_text()

        self.assertEqual(
            FIXTURE_IDS,
            self.swift_enum_raw_values(fixture_source, "ValidationFixtureID"),
        )
        self.assertEqual(
            GALLERY_FAMILIES,
            self.swift_enum_raw_values(route_source, "ValidationGalleryFamily"),
        )
        self.assertEqual(
            GALLERY_APPEARANCES,
            self.swift_enum_raw_values(route_source, "ValidationGalleryAppearance"),
        )
        self.assertEqual(
            GALLERY_PRESENTATIONS,
            self.swift_enum_raw_values(route_source, "ValidationGalleryPresentation"),
        )
        self.assertEqual(
            MAC_GALLERY_PRESENTATIONS,
            self.swift_array_case_values(MAC_APP_SOURCE.read_text(), "supportedPresentations"),
        )
        self.assertEqual(
            COMPANION_GALLERY_PRESENTATIONS,
            self.swift_array_case_values(
                COMPANION_APP_SOURCE.read_text(),
                "supportedPresentations",
            ),
        )
        self.assertLessEqual(set(MAC_GALLERY_PRESENTATIONS), set(GALLERY_PRESENTATIONS))
        self.assertLessEqual(set(COMPANION_GALLERY_PRESENTATIONS), set(GALLERY_PRESENTATIONS))
        self.assertEqual(
            WATCH_COMPLICATION_FAMILIES,
            self.swift_enum_raw_values(
                watch_widget_source,
                "ContextPanelWatchComplicationFamily",
            ),
        )
        self.assertEqual(
            TV_GALLERY_SURFACES,
            self.swift_enum_raw_values(tv_gallery_source, "TVValidationSurface"),
        )
        self.assertEqual(
            TV_PRESENTATIONS,
            self.swift_enum_raw_values(tv_presentation_source, "TVPresentationMode"),
        )

    def test_shared_view_planner_has_no_live_storage_or_publication_paths(self):
        planner = SHARED_VIEW_EVIDENCE_SOURCE.read_text()
        cli = VALIDATION_CLI_SOURCE.read_text()
        entry_point = VALIDATION_ENTRY_POINT.read_text()
        planner_imports = re.findall(r"^(?:from|import)\s+([^\s.]+)", planner, flags=re.MULTILINE)
        plan_start = cli.index("def run_plan_shared_view_evidence")
        plan_end = cli.index("\ndef emit_session_state", plan_start)
        plan_function = cli[plan_start:plan_end]

        self.assertEqual(
            planner_imports,
            ["__future__", "dataclasses", "hashlib", "json", "os", "pathlib", "re", "tempfile", "typing", "context_panel_comparison_schema"],
        )
        self.assertIn("from context_panel_validation.cli import main", entry_point)
        for forbidden in (
            "CloudKit",
            "WidgetKit",
            "Keychain",
            "ProviderCredential",
            "AppGroup",
            "Snapshot",
            "Subscription",
            "Timeline",
            "RuntimeReceipt",
            "ContextPanelLocations",
            "current-snapshot",
            "publish",
        ):
            self.assertNotIn(forbidden, planner)
            self.assertNotIn(forbidden, plan_function)
        self.assertNotIn("SessionStateStore", plan_function)
        self.assertNotIn("RuntimeEvidenceStore", plan_function)

    def run_gallery_isolation_check(
        self,
        host_links_gallery: bool,
        extension_links_gallery: bool,
        *,
        debug_dylibs: bool = False,
    ):
        """Run the artifact check on a fixture bundle whose "binaries" are plain files.

        With debug_dylibs the executables are stubs and the code sits in
        <name>.debug.dylib, as Xcode lays out Debug builds.
        """
        gallery_code = "_$s30ContextPanelValidationGalleryUI0dE4ViewV\n"
        other_code = "_$s16ContextPanelCore10UsageLimitV\n"
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "Products" / "Release-iphoneos" / "Context Panel.app"
            extension = app / "PlugIns" / "ContextPanelCompanionWidgetExtension.appex"
            extension.mkdir(parents=True)
            host_code = gallery_code if host_links_gallery else other_code
            extension_code = gallery_code if extension_links_gallery else other_code
            if debug_dylibs:
                (app / "Context Panel").write_text("stub\n")
                (app / "Context Panel.debug.dylib").write_text(host_code)
                (extension / "ContextPanelCompanionWidgetExtension").write_text("stub\n")
                (extension / "ContextPanelCompanionWidgetExtension.debug.dylib").write_text(extension_code)
            else:
                (app / "Context Panel").write_text(host_code)
                (extension / "ContextPanelCompanionWidgetExtension").write_text(extension_code)
            return subprocess.run(
                [
                    str(REPO_ROOT / "scripts" / "check-validation-gallery-isolation.sh"),
                    "--products-root",
                    str(app.parents[1]),
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                check=False,
            )

    def test_gallery_code_is_accepted_only_in_the_host_app(self):
        result = self.run_gallery_isolation_check(host_links_gallery=True, extension_links_gallery=False)

        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("1 extensions carry no gallery code", result.stdout)

    def test_gallery_code_in_an_extension_fails_the_build_check(self):
        result = self.run_gallery_isolation_check(host_links_gallery=True, extension_links_gallery=True)

        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("linked into an extension", result.stdout)
        self.assertIn("ContextPanelCompanionWidgetExtension", result.stdout)

    def test_gallery_isolation_check_reads_debug_dylibs(self):
        clean = self.run_gallery_isolation_check(True, False, debug_dylibs=True)
        contaminated = self.run_gallery_isolation_check(True, True, debug_dylibs=True)

        self.assertEqual(clean.returncode, 0, clean.stdout)
        self.assertEqual(contaminated.returncode, 1, contaminated.stdout)
        self.assertIn("linked into an extension", contaminated.stdout)

    def test_mac_widget_target_does_not_depend_on_gallery_code(self):
        # The artifact check runs on companion builds only; until the macOS build
        # gate calls it too, keep the macOS widget's dependency list honest here.
        project = (REPO_ROOT / "project.yml").read_text()

        self.assertNotIn(
            "ContextPanelValidation",
            self.yaml_target_block(project, "ContextPanelWidgetExtension"),
        )

    def test_gallery_isolation_check_fails_when_it_cannot_see_gallery_code_at_all(self):
        result = self.run_gallery_isolation_check(host_links_gallery=False, extension_links_gallery=False)

        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("cannot verify gallery isolation", result.stdout)

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

    def test_gallery_activation_is_operator_only(self):
        mac_app = MAC_APP_SOURCE.read_text()
        companion_app = COMPANION_APP_SOURCE.read_text()
        watch_app = WATCH_APP_SOURCE.read_text()
        tv_app = TV_APP_SOURCE.read_text()

        self.assertNotIn('Label("Open Validation Gallery"', mac_app)
        self.assertNotIn('Label("Validation Gallery"', companion_app)
        self.assertNotIn('Label("Validation Gallery"', watch_app)
        self.assertNotIn('Label("Validation Gallery"', tv_app)
        self.assertNotIn("showsValidationGalleryEntry", tv_app)
        self.assertNotIn("TVValidationGalleryEntryLabel", tv_app)

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
    def swift_array_case_values(source: str, label: str) -> tuple[str, ...]:
        matches = re.findall(
            rf"{re.escape(label)}:\s*\[([^\]]+)\]",
            source,
        )
        if len(matches) != 1:
            raise AssertionError(f"Swift case array {label} must appear exactly once")
        return tuple(re.findall(r"\.([A-Za-z][A-Za-z0-9]*)", matches[0]))

    @staticmethod
    def swift_enum_raw_values(source: str, enum_name: str) -> tuple[str, ...]:
        match = re.search(
            rf"(?:public\s+|private\s+)?enum\s+{re.escape(enum_name)}\b[^{{]*{{(.*?)\n}}",
            source,
            flags=re.DOTALL,
        )
        if match is None:
            raise AssertionError(f"Swift enum {enum_name} was not found")
        cases = re.findall(
            r'^\s*case\s+([A-Za-z][A-Za-z0-9]*)(?:\s*=\s*"([^"]+)")?\s*$',
            match.group(1),
            flags=re.MULTILINE,
        )
        return tuple(raw_value or name for name, raw_value in cases)

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
