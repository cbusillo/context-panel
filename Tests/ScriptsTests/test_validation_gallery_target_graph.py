from pathlib import Path
import re
import sys
import unittest


REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

from context_panel_validation.shared_view_evidence import (
    FIXTURE_IDS,
    GALLERY_APPEARANCES,
    GALLERY_FAMILIES,
    GALLERY_PRESENTATIONS,
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
TV_SYSTEM_SURFACES_SOURCE = REPO_ROOT / "Sources" / "ContextPanelTV" / "TVSystemSurfaces.swift"
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

        self.assertIn("ValidationGalleryRoute(url: url)", mac_app)
        self.assertIn("ValidationGalleryRoute(url: url)", companion_app)
        self.assertIn("case .validationGallery:", tv_app)
        self.assertIn("--context-panel-validation-gallery", watch_app)
        self.assertIn(
            ".navigationDestination(isPresented: $isValidationGalleryPresented)",
            watch_app,
        )

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

    def test_tv_runway_header_and_forecast_stay_outside_focus_driven_scrolling(self):
        tv_app = TV_APP_SOURCE.read_text()
        runway_start = tv_app.index("struct TVRunwayContent: View")
        runway_end = tv_app.index("private struct TVKeepWorkingForecastCard", runway_start)
        runway = tv_app[runway_start:runway_end]

        header_start = runway.index("TVHeaderView(")
        forecast_start = runway.index("if let keepWorkingForecast")
        scroll_start = runway.index("ScrollView {")
        grid_start = runway.index("TVProviderOverviewGrid(")

        self.assertLess(header_start, forecast_start)
        self.assertLess(forecast_start, scroll_start)
        self.assertLess(scroll_start, grid_start)
        self.assertNotIn("TVHeaderView(", runway[scroll_start:])
        self.assertNotIn("TVKeepWorkingForecastCard", runway[scroll_start:])

    def test_tv_runway_top_aligns_a_compact_full_width_forecast(self):
        tv_app = TV_APP_SOURCE.read_text()
        runway_start = tv_app.index("struct TVRunwayContent: View")
        forecast_end = tv_app.index("private struct TVSystemSurfacePublication", runway_start)
        runway = tv_app[runway_start:forecast_end]

        self.assertIn("VStack(alignment: .leading, spacing: 28)", runway)
        self.assertIn(
            ".frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)",
            runway,
        )
        self.assertIn("HStack(alignment: .center, spacing: 32)", runway)
        self.assertIn("Divider()", runway)
        self.assertIn(".padding(.vertical, 20)", runway)
        self.assertIn(".frame(maxWidth: .infinity)", runway)

    def test_tv_full_screen_fixture_suppresses_unrelated_system_notices(self):
        tv_preview = TV_PREVIEW_SOURCE.read_text()
        tv_system_surfaces = TV_SYSTEM_SURFACES_SOURCE.read_text()

        self.assertIn("static var usesFixture: Bool", tv_preview)
        self.assertEqual(
            tv_system_surfaces.count("if preparePreviewFixtureRuntime()"),
            2,
        )
        self.assertIn("guard TVPreviewFixtures.usesFixture else", tv_system_surfaces)
        self.assertIn("TVPreferenceKeys.cloudKitSubscriptionError", tv_system_surfaces)
        self.assertIn("TVPreferenceKeys.remoteNotificationRegistrationError", tv_system_surfaces)

    def test_tv_full_screen_fixture_can_select_each_provider_focus_state(self):
        tv_app = TV_APP_SOURCE.read_text()
        tv_preview = TV_PREVIEW_SOURCE.read_text()

        self.assertIn("CONTEXT_PANEL_TV_INITIAL_FOCUS_PROVIDER", tv_preview)
        self.assertIn("@FocusState private var focusedProviderRawValue", tv_app)
        self.assertEqual(
            tv_app.count(".focused($focusedProviderRawValue, equals: section.provider.rawValue)"),
            2,
        )
        self.assertIn("TVPreviewFixtures.requestedFocusProviderRawValue", tv_app)

    def test_tv_provider_cards_reserve_focus_insets(self):
        tv_app = TV_APP_SOURCE.read_text()
        grid_start = tv_app.index("private struct TVProviderOverviewGrid: View")
        grid_end = tv_app.index("private struct TVProviderOverviewCard: View", grid_start)
        grid = tv_app[grid_start:grid_end]

        self.assertIn("private static let focusHorizontalInset: CGFloat = 32", grid)
        self.assertIn("private static let focusVerticalInset: CGFloat = 28", grid)
        self.assertIn(
            "Self.maximumCardWidth + (Self.focusHorizontalInset * 2)",
            grid,
        )
        self.assertIn("controlWidth - (Self.focusHorizontalInset * 2)", grid)
        self.assertEqual(
            grid.count("overviewCard(for: section, cardWidth: cardWidth)"),
            2,
        )
        self.assertEqual(
            grid.count(".padding(.horizontal, Self.focusHorizontalInset)"),
            2,
        )
        self.assertEqual(
            grid.count(".padding(.vertical, Self.focusVerticalInset)"),
            2,
        )
        self.assertNotIn(".padding(.vertical, 28)", grid)
        self.assertIn(".strokeBorder(", tv_app)

    def test_tv_stale_state_uses_quiet_global_status_and_warm_instruments(self):
        tv_app = TV_APP_SOURCE.read_text()

        self.assertIn("private var showsPerCardStatus: Bool", tv_app)
        self.assertIn("if showsStatus {", tv_app)
        self.assertIn("status == .stale ? TVTheme.staleInstrumentColor", tv_app)
        self.assertIn("static let staleInstrumentColor", tv_app)
        self.assertIn(".font(.title3.weight(.semibold))", tv_app)

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
