import unittest
from pathlib import Path
import subprocess
import re
import tempfile


REPO_ROOT = Path(__file__).resolve().parents[2]


class ReleaseWorkflowTests(unittest.TestCase):
    def read(self, relative_path: str) -> str:
        return (REPO_ROOT / relative_path).read_text()

    def run_companion_upload_script(self, args: list[str], cwd: Path | None = None) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", str(REPO_ROOT / "scripts/upload-app-store-connect-companion-app.sh"), *args],
            cwd=cwd or REPO_ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )

    def write_minimal_visionos_icon_stack(self, root: Path) -> None:
        icon_stack = root / "Resources/Assets.xcassets/AppIcon.solidimagestack"
        icon_stack.mkdir(parents=True, exist_ok=True)
        (icon_stack / "Contents.json").write_text(
            """{
  "info" : {
    "author" : "xcode",
    "version" : 1
  },
  "layers" : [
    { "filename" : "Front.solidimagestacklayer" },
    { "filename" : "Middle.solidimagestacklayer" },
    { "filename" : "Back.solidimagestacklayer" }
  ]
}
"""
        )
        for layer_name in ("Front", "Middle", "Back"):
            layer_dir = icon_stack / f"{layer_name}.solidimagestacklayer"
            image_set = layer_dir / "Content.imageset"
            image_set.mkdir(parents=True)
            (layer_dir / "Contents.json").write_text(
                """{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
"""
            )
            (image_set / "Contents.json").write_text(
                f"""{{
  "images" : [
    {{
      "filename" : "{layer_name}.png",
      "idiom" : "vision",
      "scale" : "2x"
    }}
  ],
  "info" : {{
    "author" : "xcode",
    "version" : 1
  }}
}}
"""
            )
            (image_set / f"{layer_name}.png").write_bytes(b"not-a-real-png")

    def run_runtime_preflight_fixture(self, profile: str, entitlements: str = "app-entitlements.plist") -> subprocess.CompletedProcess[str]:
        fixture_dir = REPO_ROOT / "Tests/ScriptsTests/fixtures/runtime-preflight"
        command = f"""
        source scripts/context-panel-runtime-baseline.sh --source-only
        check_profile_plist_covers_entitlements \
          "{fixture_dir / profile}" \
          "{fixture_dir / entitlements}" \
          fixture-app
        """
        return subprocess.run(
            ["bash", "-lc", command],
            cwd=REPO_ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )

    def test_ship_forwards_resolved_build_number_to_github_release(self):
        workflow = self.read(".github/workflows/ship.yml")

        self.assertIn("build_number: ${{ needs.validate.outputs.build_number }}", workflow)

    def test_ship_distributes_testflight_beta_without_app_review(self):
        workflow = self.read(".github/workflows/ship.yml")

        self.assertIn("testflight_beta:", workflow)
        self.assertIn("uses: ./.github/workflows/testflight-beta-distribution.yml", workflow)
        self.assertIn("companion_app_store_channel:", workflow)
        self.assertIn("testflight_beta_source:", workflow)
        self.assertIn("uses: ./.github/workflows/app-store-connect-companion-upload.yml", workflow)
        self.assertIn("needs.companion-app-store-upload.outputs.app_store_platform", workflow)
        self.assertIn("testflight_beta_source=companion requires companion_app_store_channel=upload", workflow)
        self.assertIn("testflight_beta_source=macos requires app_store_channel=upload", workflow)
        self.assertIn("Ship does not submit App Store Review.", workflow)
        self.assertIn("run Submit App Store Review separately; use dry_run=true first", workflow)
        self.assertNotIn("submit_app_review", workflow)
        self.assertNotIn("uses: ./.github/workflows/submit-app-store-review.yml", workflow)

    def test_companion_upload_workflow_uses_companion_script_and_profiles(self):
        workflow = self.read(".github/workflows/app-store-connect-companion-upload.yml")
        script = self.read("scripts/upload-app-store-connect-companion-app.sh")

        self.assertIn("name: App Store Connect Companion Build Upload", workflow)
        self.assertIn("scripts/upload-app-store-connect-companion-app.sh", workflow)
        self.assertIn("COMPANION_APP_STORE_APP_PROVISIONING_PROFILE_BASE64", workflow)
        self.assertIn("COMPANION_APP_STORE_WIDGET_PROVISIONING_PROFILE_BASE64", workflow)
        self.assertIn("ContextPanelCompanion", script)
        self.assertIn("generic/platform=iOS", script)
        self.assertIn("generic/platform=visionOS", script)
        self.assertIn("CONTEXT_PANEL_APP_STORE_COMPANION_PROFILE_SPECIFIER", script)
        self.assertIn("iCloud.com.shinycomputers.contextpanel", script)
        self.assertIn("group.com.shinycomputers.contextpanel", script)
        self.assertIn("'Entitlements:com.apple.developer.icloud-services' '*'", script)

    def test_app_store_upload_name_does_not_claim_testflight_distribution(self):
        workflow = self.read(".github/workflows/app-store-connect-upload.yml")

        self.assertIn("name: App Store Connect Build Upload", workflow)
        self.assertIn("TestFlight beta distribution: handled by the TestFlight Beta Distribution workflow", workflow)
        self.assertNotIn("TestFlight beta distribution: not requested by this workflow", workflow)

    def test_testflight_beta_distribution_workflow_uses_distribution_script(self):
        workflow = self.read(".github/workflows/testflight-beta-distribution.yml")
        script = self.read("scripts/distribute-testflight-beta.py")

        self.assertIn("name: TestFlight Beta Distribution", workflow)
        self.assertIn("scripts/distribute-testflight-beta.py", workflow)
        self.assertIn("--platform", workflow)
        self.assertIn("required: true", workflow)
        self.assertIn("/betaGroups/{group_id}/relationships/builds", script)
        self.assertIn("processingState", script)

    def test_ship_concurrency_does_not_block_reusable_release_workflow(self):
        ship_workflow = self.read(".github/workflows/ship.yml")
        release_workflow = self.read(".github/workflows/release.yml")

        self.assertIn("group: ship-v${{ inputs.version }}", ship_workflow)
        self.assertIn("format('release-v{0}', inputs.version)", release_workflow)
        self.assertNotIn("group: release-v${{ inputs.version }}", ship_workflow)

    def test_release_package_stamps_bundle_version_and_build_number(self):
        workflow = self.read(".github/workflows/release.yml")
        package_script = self.read("scripts/package-native-macos-app.sh")

        self.assertIn("build_number:", workflow)
        self.assertIn('--build-number "${{ steps.build.outputs.build_number }}"', workflow)
        self.assertIn('MARKETING_VERSION="$version"', package_script)
        self.assertIn('CURRENT_PROJECT_VERSION="$build_number"', package_script)

    def test_app_store_export_preserves_archived_build_number(self):
        upload_script = self.read("scripts/upload-app-store-connect-macos-app.sh")

        self.assertNotIn("manageAppVersionAndBuildNumber", upload_script)

    def test_app_store_upload_scripts_prefer_system_xcode_tools(self):
        for script_path in (
            "scripts/upload-app-store-connect-macos-app.sh",
            "scripts/upload-app-store-connect-companion-app.sh",
        ):
            with self.subTest(script_path=script_path):
                script = self.read(script_path)

                self.assertIn("xcodebuild_system_path()", script)
                self.assertIn("/usr/bin:/bin:/usr/sbin:/sbin", script)
                self.assertIn("PATH=\"$(xcodebuild_system_path)\" /usr/bin/xcodebuild", script)
                self.assertNotRegex(script, r"(?m)^xcodebuild \\")

    def test_companion_build_validation_supports_ios_and_visionos_without_signing(self):
        workflow = self.read(".github/workflows/ci.yml")
        script = self.read("scripts/validate-companion-builds.sh")

        self.assertIn("scripts/validate-companion-builds.sh ios", workflow)
        self.assertIn("platforms=(ios visionos)", script)
        self.assertIn("generic/platform=iOS", script)
        self.assertIn("generic/platform=visionOS", script)
        self.assertIn("CODE_SIGNING_ALLOWED=NO", script)
        self.assertIn("ContextPanelCompanion", script)
        self.assertIn("PATH=\"$(xcodebuild_system_path)\" /usr/bin/xcodebuild", script)

    def test_visionos_dogfood_script_uses_development_signing_and_devicectl(self):
        script = self.read("scripts/dogfood-visionos-companion.sh")

        self.assertIn("ContextPanelCompanion", script)
        self.assertIn("generic/platform=visionOS", script)
        self.assertIn('build_destination="platform=visionOS,id=$resolved_device_id"', script)
        self.assertIn('-destination "$build_destination"', script)
        self.assertIn("-allowProvisioningUpdates", script)
        self.assertIn("-allowProvisioningDeviceRegistration", script)
        self.assertIn("CODE_SIGN_STYLE=Automatic", script)
        self.assertIn("DEVELOPMENT_TEAM=\"$team_id\"", script)
        self.assertIn("xcrun devicectl list devices --json-output", script)
        self.assertIn("xcrun devicectl device install app", script)
        self.assertIn("xcrun devicectl \"${launch_args[@]}\"", script)
        self.assertIn("com.shinycomputers.contextpanel", script)
        self.assertIn('if [[ "$2" == /* ]]; then', script)
        self.assertIn('derived_data_path="$repo_root/${2#./}"', script)
        self.assertIn("if ! ((build_only)); then", script)
        self.assertIn('if [[ "$launch_identifier" == "unknown" ]]; then', script)
        self.assertIn('launch_identifier=""', script)
        self.assertNotIn("require_command python3", script)

    def test_visionos_dogfood_script_requires_available_physical_avp_for_install(self):
        script = self.read("scripts/dogfood-visionos-companion.sh")

        self.assertIn('.hardwareProperties.platform == "visionOS"', script)
        self.assertIn('.hardwareProperties.reality == "physical"', script)
        self.assertIn('.connectionProperties.pairingState == "paired"', script)
        self.assertIn("Developer Mode is not enabled", script)
        self.assertIn("Apple Vision Pro is paired but unavailable to CoreDevice", script)
        self.assertIn("Wake and unlock the headset", script)
        self.assertIn("This is not App Store Connect, TestFlight, or App Review release evidence", script)

    def test_companion_upload_preflights_profile_platforms(self):
        script = self.read("scripts/upload-app-store-connect-companion-app.sh")

        self.assertIn("assert_profile_platform_any()", script)
        self.assertIn("plist_array_contains_value \"$plist\" 'Platform'", script)
        self.assertIn("profile_platforms=(iOS)", script)
        self.assertIn("profile_platforms=(visionOS xrOS)", script)
        self.assertIn("assert_profile_platform_any \"$app_profile\" \"companion app\"", script)
        self.assertIn("assert_profile_platform_any \"$widget_profile\" \"companion widget\"", script)

    def test_companion_upload_blocks_visionos_without_layered_icon(self):
        script = self.read("scripts/upload-app-store-connect-companion-app.sh")

        self.assertIn("assert_visionos_packaging_ready()", script)
        self.assertIn("Resources/Assets.xcassets/AppIcon.solidimagestack", script)
        self.assertIn('icon_stack_contents="$icon_stack/Contents.json"', script)
        self.assertIn(".solidimagestacklayer", script)
        self.assertIn("Content.imageset/Contents.json", script)
        self.assertIn("json_array_count()", script)
        self.assertIn("does not declare the same number of layers", script)
        self.assertIn("declares a duplicate layer", script)
        self.assertIn("declares an invalid layer filename", script)
        self.assertIn("Every image entry must name a file", script)
        self.assertIn("has an invalid image filename", script)
        self.assertIn("declares a duplicate image filename", script)
        self.assertIn("visionOS companion packaging is blocked", script)

    def test_companion_upload_ios_does_not_require_visionos_layered_icon(self):
        result = self.run_companion_upload_script(
            [
                "--platform",
                "ios",
                "--version",
                "1.0.99",
                "--build-number",
                "168002",
                "--export-only",
                "--app-profile",
                ".build/missing-ios-app.provisionprofile",
                "--widget-profile",
                ".build/missing-ios-widget.provisionprofile",
            ]
        )

        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("companion app provisioning profile not found", result.stdout)
        self.assertNotIn("visionOS companion packaging is blocked", result.stdout)
        self.assertNotIn("AppIcon.solidimagestack", result.stdout)

    def test_companion_upload_fails_visionos_before_profiles_without_layered_icon(self):
        with tempfile.TemporaryDirectory() as working_dir:
            result = self.run_companion_upload_script(
                [
                    "--platform",
                    "visionos",
                    "--version",
                    "1.0.99",
                    "--build-number",
                    "168001",
                    "--export-only",
                ],
                cwd=Path(working_dir),
            )

        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("no visionOS layered app icon is present", result.stdout)
        self.assertIn("AppIcon.solidimagestack", result.stdout)
        self.assertNotIn("provisioning profile not found", result.stdout)
        self.assertNotIn("App Store Connect API credentials are required", result.stdout)

    def test_companion_upload_rejects_placeholder_visionos_icon_stack(self):
        with tempfile.TemporaryDirectory() as working_dir:
            working_root = Path(working_dir)
            icon_stack = working_root / "Resources/Assets.xcassets/AppIcon.solidimagestack"
            icon_stack.mkdir(parents=True)
            (icon_stack / "Contents.json").write_text("{}\n")

            result = self.run_companion_upload_script(
                [
                    "--platform",
                    "visionos",
                    "--version",
                    "1.0.99",
                    "--build-number",
                    "168004",
                    "--export-only",
                ],
                cwd=working_root,
            )

        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("must contain two or three solid image stack layers", result.stdout)
        self.assertNotIn("provisioning profile not found", result.stdout)
        self.assertNotIn("App Store Connect API credentials are required", result.stdout)

    def test_companion_upload_rejects_visionos_icon_stack_without_image_files(self):
        with tempfile.TemporaryDirectory() as working_dir:
            working_root = Path(working_dir)
            self.write_minimal_visionos_icon_stack(working_root)
            for image_file in working_root.glob(
                "Resources/Assets.xcassets/AppIcon.solidimagestack/*.solidimagestacklayer/Content.imageset/*.png"
            ):
                image_file.unlink()

            result = self.run_companion_upload_script(
                [
                    "--platform",
                    "visionos",
                    "--version",
                    "1.0.99",
                    "--build-number",
                    "168005",
                    "--export-only",
                ],
                cwd=working_root,
            )

        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("has a missing image file", result.stdout)
        self.assertNotIn("provisioning profile not found", result.stdout)
        self.assertNotIn("App Store Connect API credentials are required", result.stdout)

    def test_companion_upload_rejects_duplicate_visionos_layers(self):
        with tempfile.TemporaryDirectory() as working_dir:
            working_root = Path(working_dir)
            self.write_minimal_visionos_icon_stack(working_root)
            icon_stack = working_root / "Resources/Assets.xcassets/AppIcon.solidimagestack"
            (icon_stack / "Contents.json").write_text(
                """{
  "info" : {
    "author" : "xcode",
    "version" : 1
  },
  "layers" : [
    { "filename" : "Front.solidimagestacklayer" },
    { "filename" : "Front.solidimagestacklayer" },
    { "filename" : "Back.solidimagestacklayer" }
  ]
}
"""
            )
            result = self.run_companion_upload_script(
                [
                    "--platform",
                    "visionos",
                    "--version",
                    "1.0.99",
                    "--build-number",
                    "168006",
                    "--export-only",
                ],
                cwd=working_root,
            )

        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("declares a duplicate layer", result.stdout)
        self.assertNotIn("provisioning profile not found", result.stdout)
        self.assertNotIn("App Store Connect API credentials are required", result.stdout)

    def test_companion_upload_rejects_path_warped_visionos_layer_filename(self):
        with tempfile.TemporaryDirectory() as working_dir:
            working_root = Path(working_dir)
            self.write_minimal_visionos_icon_stack(working_root)
            icon_stack = working_root / "Resources/Assets.xcassets/AppIcon.solidimagestack"
            (icon_stack / "Contents.json").write_text(
                """{
  "info" : {
    "author" : "xcode",
    "version" : 1
  },
  "layers" : [
    { "filename" : "Front.solidimagestacklayer" },
    { "filename" : "../Back.solidimagestacklayer" },
    { "filename" : "Middle.solidimagestacklayer" }
  ]
}
"""
            )
            result = self.run_companion_upload_script(
                [
                    "--platform",
                    "visionos",
                    "--version",
                    "1.0.99",
                    "--build-number",
                    "168007",
                    "--export-only",
                ],
                cwd=working_root,
            )

        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("declares an invalid layer filename", result.stdout)
        self.assertNotIn("provisioning profile not found", result.stdout)
        self.assertNotIn("App Store Connect API credentials are required", result.stdout)

    def test_companion_upload_rejects_path_warped_visionos_image_filename(self):
        with tempfile.TemporaryDirectory() as working_dir:
            working_root = Path(working_dir)
            self.write_minimal_visionos_icon_stack(working_root)
            front_images = (
                working_root
                / "Resources/Assets.xcassets/AppIcon.solidimagestack/Front.solidimagestacklayer/Content.imageset"
            )
            (front_images / "Contents.json").write_text(
                """{
  "images" : [
    {
      "filename" : "../Front.png",
      "idiom" : "vision",
      "scale" : "2x"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
"""
            )
            result = self.run_companion_upload_script(
                [
                    "--platform",
                    "visionos",
                    "--version",
                    "1.0.99",
                    "--build-number",
                    "168008",
                    "--export-only",
                ],
                cwd=working_root,
            )

        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("has an invalid image filename", result.stdout)
        self.assertNotIn("provisioning profile not found", result.stdout)
        self.assertNotIn("App Store Connect API credentials are required", result.stdout)

    def test_companion_upload_rejects_duplicate_visionos_image_filenames(self):
        with tempfile.TemporaryDirectory() as working_dir:
            working_root = Path(working_dir)
            self.write_minimal_visionos_icon_stack(working_root)
            front_images = (
                working_root
                / "Resources/Assets.xcassets/AppIcon.solidimagestack/Front.solidimagestacklayer/Content.imageset"
            )
            (front_images / "Contents.json").write_text(
                """{
  "images" : [
    {
      "filename" : "Front.png",
      "idiom" : "vision",
      "scale" : "2x"
    },
    {
      "filename" : "Front.png",
      "idiom" : "vision",
      "scale" : "2x"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
"""
            )
            result = self.run_companion_upload_script(
                [
                    "--platform",
                    "visionos",
                    "--version",
                    "1.0.99",
                    "--build-number",
                    "168009",
                    "--export-only",
                ],
                cwd=working_root,
            )

        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("declares a duplicate image filename", result.stdout)
        self.assertNotIn("provisioning profile not found", result.stdout)
        self.assertNotIn("App Store Connect API credentials are required", result.stdout)

    def test_companion_upload_allows_leading_dash_visionos_icon_filenames(self):
        with tempfile.TemporaryDirectory() as working_dir:
            working_root = Path(working_dir)
            icon_stack = working_root / "Resources/Assets.xcassets/AppIcon.solidimagestack"
            icon_stack.mkdir(parents=True)
            (icon_stack / "Contents.json").write_text(
                """{
  "info" : {
    "author" : "xcode",
    "version" : 1
  },
  "layers" : [
    { "filename" : "-Front.solidimagestacklayer" },
    { "filename" : "-Back.solidimagestacklayer" }
  ]
}
"""
            )
            for layer_name in ("-Front", "-Back"):
                layer_dir = icon_stack / f"{layer_name}.solidimagestacklayer"
                image_set = layer_dir / "Content.imageset"
                image_set.mkdir(parents=True)
                (layer_dir / "Contents.json").write_text(
                    """{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
"""
                )
                (image_set / "Contents.json").write_text(
                    f"""{{
  "images" : [
    {{
      "filename" : "{layer_name}.png",
      "idiom" : "vision",
      "scale" : "2x"
    }}
  ],
  "info" : {{
    "author" : "xcode",
    "version" : 1
  }}
}}
"""
                )
                (image_set / f"{layer_name}.png").write_bytes(b"not-a-real-png")

            result = self.run_companion_upload_script(
                [
                    "--platform",
                    "visionos",
                    "--version",
                    "1.0.99",
                    "--build-number",
                    "168010",
                    "--export-only",
                    "--app-profile",
                    ".build/missing-visionos-app.provisionprofile",
                    "--widget-profile",
                    ".build/missing-visionos-widget.provisionprofile",
                ],
                cwd=working_root,
            )

        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("companion app provisioning profile not found", result.stdout)
        self.assertNotIn("visionOS companion packaging is blocked", result.stdout)

    def test_companion_upload_visionos_with_layered_icon_continues_to_profile_preflight(self):
        with tempfile.TemporaryDirectory() as working_dir:
            working_root = Path(working_dir)
            self.write_minimal_visionos_icon_stack(working_root)
            result = self.run_companion_upload_script(
                [
                    "--platform",
                    "visionos",
                    "--version",
                    "1.0.99",
                    "--build-number",
                    "168003",
                    "--export-only",
                    "--app-profile",
                    ".build/missing-visionos-app.provisionprofile",
                    "--widget-profile",
                    ".build/missing-visionos-widget.provisionprofile",
                ],
                cwd=working_root,
            )

        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("companion app provisioning profile not found", result.stdout)
        self.assertNotIn("visionOS companion packaging is blocked", result.stdout)
        self.assertNotIn("no visionOS layered app icon is present", result.stdout)

    def test_companion_upload_preflights_widget_icloud_documents_profile(self):
        script = self.read("scripts/upload-app-store-connect-companion-app.sh")

        self.assertIn("assert_profile_icloud_documents()", script)
        self.assertIn("assert_profile_icloud_documents \"$app_profile\" \"companion app\"", script)
        self.assertIn("assert_profile_icloud_documents \"$widget_profile\" \"companion widget\"", script)

    def test_runtime_baseline_does_not_require_google_oauth_build_settings(self):
        script = self.read("scripts/context-panel-runtime-baseline.sh")

        build_function = re.search(r"build_checkout_app\(\) \{(?P<body>.*?)\n\}", script, re.S)

        self.assertIsNotNone(build_function)
        assert build_function is not None
        body = build_function.group("body")
        self.assertIn("xcodebuild \\", body)
        self.assertNotIn("CONTEXT_PANEL_GOOGLE_", script)
        self.assertNotIn("runtime-baseline-local-oauth.xcconfig", script)
        self.assertNotIn('-xcconfig "$local_oauth_xcconfig_path"', script)
        self.assertNotIn("check_debug_google_oauth_config", script)
        self.assertNotIn("require_local_google_oauth_config", script)

    def test_runtime_baseline_local_env_file_is_ignored_but_example_is_tracked(self):
        gitignore = self.read(".gitignore")
        example = self.read(".local/context-panel-runtime.env.example")

        self.assertIn("!.local/context-panel-runtime.env.example", gitignore)
        self.assertIn(".local/context-panel-runtime.env", gitignore)
        self.assertNotIn("runtime-baseline-local-oauth.xcconfig", gitignore)
        self.assertNotIn("CONTEXT_PANEL_GOOGLE_", example)
        self.assertIn("Antigravity", example)

    def test_runtime_baseline_build_allows_xcode_to_update_explicit_profiles(self):
        script = self.read("scripts/context-panel-runtime-baseline.sh")
        build_function = re.search(r"build_checkout_app\(\) \{(?P<body>.*?)\n\}", script, re.S)

        self.assertIsNotNone(build_function)
        assert build_function is not None
        self.assertIn("-allowProvisioningUpdates", build_function.group("body"))
        self.assertNotIn("CODE_SIGNING_ALLOWED=NO", build_function.group("body"))

    def test_runtime_baseline_preflights_profiles_before_install_mutates_applications(self):
        script = self.read("scripts/context-panel-runtime-baseline.sh")
        install_runtime = re.search(r"install_runtime\(\) \{(?P<body>.*?)\n\}", script, re.S)
        reset_runtime = re.search(r"reset_runtime\(\) \{(?P<body>.*?)\n\}", script, re.S)

        self.assertIsNotNone(install_runtime)
        self.assertIsNotNone(reset_runtime)
        assert install_runtime is not None
        assert reset_runtime is not None
        for function in (install_runtime, reset_runtime):
            body = function.group("body")
            self.assertLess(body.index("preflight_built_runtime_profiles"), body.index("install_checkout_app"))

    def test_runtime_baseline_install_and_reset_share_stale_bundle_cleanup(self):
        script = self.read("scripts/context-panel-runtime-baseline.sh")
        install_runtime = re.search(r"install_runtime\(\) \{(?P<body>.*?)\n\}", script, re.S)
        reset_runtime = re.search(r"reset_runtime\(\) \{(?P<body>.*?)\n\}", script, re.S)

        self.assertIsNotNone(install_runtime)
        self.assertIsNotNone(reset_runtime)
        assert install_runtime is not None
        assert reset_runtime is not None
        self.assertIn("quarantine_stale_runtime_bundles", install_runtime.group("body"))
        self.assertIn("quarantine_stale_runtime_bundles", reset_runtime.group("body"))
        self.assertNotIn("done < <(discoverable_bundles)", reset_runtime.group("body"))
        self.assertNotIn('find_context_panel_bundles "$HOME/.code/working/context-panel"', reset_runtime.group("body"))
        self.assertIn('find_context_panel_bundles "${TMPDIR:-/tmp}"', script)
        self.assertIn('find_context_panel_bundles "/tmp"', script)

    def test_runtime_baseline_omits_historical_local_cleanup_paths(self):
        script = self.read("scripts/context-panel-runtime-baseline.sh")

        self.assertNotIn("context-panel-clean-main", script)
        self.assertNotIn("context-panel-baseline-main-20260512", script)

    def test_runtime_baseline_profile_fixture_accepts_matching_explicit_profile(self):
        result = self.run_runtime_preflight_fixture("profile-good.plist")

        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("fixture-app provisioning profile covers signed entitlements", result.stdout)

    def test_runtime_baseline_profile_fixture_accepts_development_wildcard_grants(self):
        result = self.run_runtime_preflight_fixture("profile-development-wildcard-grants.plist")

        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("fixture-app provisioning profile covers signed entitlements", result.stdout)

    def test_runtime_baseline_profile_fixture_rejects_wildcard_profile(self):
        result = self.run_runtime_preflight_fixture("profile-wildcard.plist")

        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("does not authorize application identifier", result.stdout)


if __name__ == "__main__":
    unittest.main()
