import unittest
from pathlib import Path
import subprocess
import re
import tempfile
import os
import json


REPO_ROOT = Path(__file__).resolve().parents[2]


class ReleaseWorkflowTests(unittest.TestCase):
    def read(self, relative_path: str) -> str:
        return (REPO_ROOT / relative_path).read_text()

    def run_companion_upload_script(self, args: list[str], cwd: Path | None = None) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["/bin/bash", str(REPO_ROOT / "scripts/upload-app-store-connect-companion-app.sh"), *args],
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

    def run_package_script_preflight(self, args: list[str], profiles: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            tool_dir = root / "tools"
            tool_dir.mkdir()
            self.write_fake_release_tools(tool_dir)
            profile_paths: dict[str, Path] = {}
            for name, contents in (profiles or {}).items():
                path = root / name
                path.write_text(contents)
                profile_paths[name] = path
            expanded_args = [str(profile_paths.get(arg, arg)) for arg in args]
            env = os.environ.copy()
            env["PATH"] = f"{tool_dir}:{env['PATH']}"
            return subprocess.run(
                ["/bin/bash", str(REPO_ROOT / "scripts/package-native-macos-app.sh"), *expanded_args],
                cwd=REPO_ROOT,
                env=env,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                check=False,
            )

    def write_fake_release_tools(self, tool_dir: Path) -> None:
        fake_security = """#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "cms" && "${2:-}" == "-D" && "${3:-}" == "-i" ]]; then
  cat "${4:?profile path required}"
  exit 0
fi
if [[ "${1:-}" == "find-identity" ]]; then
  exit 0
fi
echo "unexpected fake security invocation: $*" >&2
exit 42
"""
        (tool_dir / "security").write_text(fake_security)
        for name in ("xcodegen", "xcodebuild", "codesign", "ditto", "xcrun"):
            (tool_dir / name).write_text(
                f"#!/usr/bin/env bash\necho 'unexpected fake {name} invocation' >&2\nexit 42\n"
            )
        for path in tool_dir.iterdir():
            path.chmod(0o755)

    def cloudkit_profile_plist(
        self,
        bundle_id: str,
        services: list[str] | None = None,
        cloudkit_environment: str = "Production",
    ) -> str:
        team_id = "MM5YXC7T6E"
        service_items = "\n".join(
            f"        <string>{service}</string>" for service in (services or ["CloudDocuments", "CloudKit"])
        )
        return f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Name</key>
  <string>Test Profile {bundle_id}</string>
  <key>TeamIdentifier</key>
  <array>
    <string>{team_id}</string>
  </array>
  <key>Entitlements</key>
  <dict>
    <key>application-identifier</key>
    <string>{team_id}.{bundle_id}</string>
    <key>com.apple.application-identifier</key>
    <string>{team_id}.{bundle_id}</string>
    <key>com.apple.developer.team-identifier</key>
    <string>{team_id}</string>
    <key>com.apple.developer.icloud-container-identifiers</key>
    <array>
      <string>iCloud.com.shinycomputers.contextpanel</string>
    </array>
    <key>com.apple.developer.icloud-services</key>
    <array>
{service_items}
    </array>
    <key>com.apple.developer.icloud-container-environment</key>
    <string>{cloudkit_environment}</string>
    <key>com.apple.developer.ubiquity-container-identifiers</key>
    <array>
      <string>iCloud.com.shinycomputers.contextpanel</string>
    </array>
    <key>com.apple.security.application-groups</key>
    <array>
      <string>{team_id}.group.com.shinycomputers.contextpanel</string>
    </array>
    <key>keychain-access-groups</key>
    <array>
      <string>{team_id}.com.shinycomputers.contextpanel.provider-credentials</string>
    </array>
  </dict>
</dict>
</plist>
"""

    def run_cloudkit_schema_validator_with_fake_cktool(
        self,
        live_schema: str,
        *,
        management_token: str | None = None,
        require_token: bool = False,
    ) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            tool_dir = root / "tools"
            tool_dir.mkdir()
            live_schema_path = root / "live.ckdb"
            live_schema_path.write_text(live_schema)
            fake_xcrun = """#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" != "cktool" || "${2:-}" != "export-schema" ]]; then
  echo "unexpected fake xcrun invocation: $*" >&2
  exit 42
fi
output_file=""
token=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-file)
      output_file="${2:?--output-file requires a value}"
      shift 2
      ;;
    --token)
      token="${2:?--token requires a value}"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
if [[ -z "$output_file" ]]; then
  echo "missing --output-file" >&2
  exit 42
fi
if [[ "${FAKE_REQUIRE_TOKEN:-}" == "1" && "$token" != "${FAKE_EXPECTED_TOKEN:-}" ]]; then
  echo "missing expected --token" >&2
  exit 42
fi
cp "$FAKE_CKDB_SCHEMA" "$output_file"
"""
            (tool_dir / "xcrun").write_text(fake_xcrun)
            (tool_dir / "xcrun").chmod(0o755)
            env = os.environ.copy()
            env["PATH"] = f"{tool_dir}:{env['PATH']}"
            env["FAKE_CKDB_SCHEMA"] = str(live_schema_path)
            if management_token is not None:
                env["CLOUDKIT_MANAGEMENT_TOKEN"] = management_token
            if require_token:
                env["FAKE_REQUIRE_TOKEN"] = "1"
                env["FAKE_EXPECTED_TOKEN"] = management_token or ""
            return subprocess.run(
                [
                    "/bin/bash",
                    str(REPO_ROOT / "scripts/validate-cloudkit-companion-schema.sh"),
                    "--live",
                    "--environment",
                    "production",
                ],
                cwd=REPO_ROOT,
                env=env,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                check=False,
            )

    def test_ship_forwards_resolved_build_number_to_github_release(self):
        workflow = self.read(".github/workflows/ship.yml")

        self.assertIn("build_number: ${{ needs.validate.outputs.build_number }}", workflow)

    def test_ship_preflights_app_store_versions_before_release_channels(self):
        workflow = self.read(".github/workflows/ship.yml")

        validate_index = workflow.index("Validate Inputs")
        guard_index = workflow.index("scripts/app-store-version-guard.py")
        github_release_index = workflow.index("github-release:")
        app_store_upload_index = workflow.index("app-store-upload:")
        mac_upload_condition_index = workflow.index('if [[ "${app_store_channel}" == "upload" ]]; then')
        companion_upload_condition_index = workflow.index('if [[ "${companion_app_store_channel}" == "upload" ]]; then')
        build_number_index = workflow.index('build_number="${{ inputs.build_number }}"')

        self.assertGreater(guard_index, validate_index)
        self.assertLess(guard_index, github_release_index)
        self.assertLess(guard_index, app_store_upload_index)
        self.assertLess(mac_upload_condition_index, build_number_index)
        self.assertLess(companion_upload_condition_index, build_number_index)
        mac_upload_block = workflow[mac_upload_condition_index:companion_upload_condition_index]
        companion_upload_block = workflow[companion_upload_condition_index:build_number_index]

        self.assertIn("preflight_app_store_version MAC_OS", workflow)
        self.assertIn("preflight_app_store_version MAC_OS", mac_upload_block)
        self.assertIn("preflight_app_store_version IOS", workflow)
        self.assertIn("preflight_app_store_version VISION_OS", workflow)
        self.assertIn("preflight_app_store_version IOS", companion_upload_block)
        self.assertIn("preflight_app_store_version VISION_OS", companion_upload_block)
        self.assertIn("APP_STORE_CONNECT_API_KEY_P8_BASE64", workflow)
        self.assertIn("App Store Connect API credentials are required for Ship App Store version preflight", workflow)

    def test_ship_distributes_testflight_beta_without_app_review(self):
        workflow = self.read(".github/workflows/ship.yml")

        self.assertIn("testflight_beta:", workflow)
        self.assertIn("uses: ./.github/workflows/testflight-beta-distribution.yml", workflow)
        self.assertIn("companion_app_store_channel:", workflow)
        self.assertIn("testflight_beta_source:", workflow)
        self.assertIn("uses: ./.github/workflows/app-store-connect-companion-upload.yml", workflow)
        self.assertIn("needs.companion-app-store-upload.outputs.app_store_platform", workflow)
        self.assertIn("default: macos", workflow)
        self.assertIn("testflight_beta_source=companion requires companion_app_store_channel=upload", workflow)
        self.assertIn("testflight_beta_source=macos requires app_store_channel=upload", workflow)
        self.assertIn(
            "companion_app_store_channel=upload with testflight_beta=true requires testflight_beta_source=companion",
            workflow,
        )
        self.assertIn(
            "inputs.testflight_beta_source == 'companion' && needs.companion-app-store-upload.outputs.app_store_platform || 'MAC_OS'",
            workflow,
        )
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
        self.assertIn("group: testflight-beta-${{ inputs.version }}-${{ inputs.build_number }}-${{ inputs.platform }}", workflow)
        self.assertIn('args+=(--platform "${INPUT_PLATFORM}")', workflow)
        self.assertNotIn("${INPUT_PLATFORM:-any}", workflow)
        self.assertIn("/betaGroups/{group_id}/relationships/builds", script)
        self.assertIn("processingState", script)
        self.assertIn('required=True,\n        choices=("IOS", "MAC_OS", "TV_OS", "VISION_OS")', script)

    def test_app_store_screenshot_upload_workflow_uses_safe_defaults(self):
        workflow = self.read(".github/workflows/upload-app-store-screenshots.yml")
        script = self.read("scripts/upload-app-store-screenshots.py")

        self.assertIn("name: Upload App Store Screenshots", workflow)
        self.assertIn("default: true", workflow)
        self.assertIn("scripts/upload-app-store-screenshots.py", workflow)
        self.assertIn("--dry-run", workflow)
        self.assertIn("APP_STORE_CONNECT_API_KEY_P8_BASE64", workflow)
        self.assertIn("default: \"\"", workflow)
        self.assertIn("type: string", workflow)
        self.assertNotIn("- MAC_OS", workflow)
        self.assertIn("options:", workflow)
        self.assertIn("- macos", workflow)
        self.assertIn("- ios", workflow)
        self.assertIn("- iphone", workflow)
        self.assertIn("- ipad", workflow)
        self.assertIn("- watch", workflow)
        self.assertIn("- visionpro", workflow)
        self.assertIn('"ipad": "IOS"', script)
        self.assertIn('"watch": "IOS"', script)
        self.assertIn("APP_IPAD_PRO_3GEN_129", script)
        self.assertIn("APP_WATCH_ULTRA", script)
        self.assertIn("APP_APPLE_VISION_PRO", script)
        self.assertIn("context-panel-appstore-5-glance-detail-redacted.png", script)

    def test_app_store_review_workflow_supports_prepare_only(self):
        workflow = self.read(".github/workflows/submit-app-store-review.yml")
        script = self.read("scripts/submit-app-store-review.py")

        self.assertIn("prepare_only:", workflow)
        self.assertIn("INPUT_PREPARE_ONLY", workflow)
        self.assertIn("args+=(--prepare-only)", workflow)
        self.assertIn("or prepare_only is true", workflow)
        self.assertIn("- Prepare only: ${INPUT_PREPARE_ONLY}", workflow)
        self.assertIn("--prepare-only", script)
        self.assertIn("Prepare only: review submission was not created or submitted", script)
        self.assertIn("--prepare-only and --cancel-review-only are mutually exclusive", script)

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

    def test_release_package_signing_preserves_profile_application_identifier(self):
        package_script = self.read("scripts/package-native-macos-app.sh")

        self.assertIn("merge_profile_application_entitlements()", package_script)
        self.assertIn("profile_entitlement_value \"$profile_plist\" com.apple.application-identifier", package_script)
        self.assertIn("Add :com.apple.application-identifier string $application_identifier", package_script)
        self.assertIn("Add :com.apple.developer.team-identifier string $team_identifier", package_script)
        self.assertIn("require_profile_for_cloudkit_entitlements", package_script)
        self.assertIn("uses CloudKit entitlements and requires an embedded provisioning profile", package_script)
        self.assertIn("require_command security", package_script)
        self.assertIn("prepared_entitlements()", package_script)
        self.assertIn('prepared_entitlements "$app_entitlements" "$app_provisioning_profile"', package_script)
        self.assertIn('prepared_entitlements "$refresh_agent_entitlements" "$refresh_agent_provisioning_profile"', package_script)
        self.assertIn('assert_entitlement_present "$app_path" "Context Panel app" "com.apple.application-identifier"', package_script)
        self.assertIn('assert_entitlement_present "$refresh_agent_path" "Context Panel refresh agent" "com.apple.application-identifier"', package_script)

    def test_release_package_rejects_cloudkit_without_profiles_before_building(self):
        result = self.run_package_script_preflight([
            "--identity",
            "Apple Development: Test",
        ])

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Context Panel app uses CloudKit entitlements and requires an embedded provisioning profile", result.stdout)
        self.assertNotIn("unexpected fake xcodegen invocation", result.stdout)

    def test_release_package_allows_ad_hoc_validation_without_cloudkit_profiles(self):
        result = self.run_package_script_preflight([
            "--identity",
            "-",
        ])

        self.assertEqual(result.returncode, 42)
        self.assertIn("unexpected fake xcodegen invocation", result.stdout)
        self.assertNotIn("uses CloudKit entitlements and requires an embedded provisioning profile", result.stdout)

    def test_release_package_rejects_ad_hoc_cloudkit_profiles_before_building(self):
        result = self.run_package_script_preflight(
            [
                "--identity",
                "-",
                "--app-provisioning-profile",
                "app.plist",
                "--refresh-agent-provisioning-profile",
                "refresh.plist",
            ],
            profiles={
                "app.plist": self.cloudkit_profile_plist("com.shinycomputers.contextpanel"),
                "refresh.plist": self.cloudkit_profile_plist("com.shinycomputers.contextpanel.refresh-agent"),
            },
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("requires a non-ad-hoc signing identity", result.stdout)
        self.assertNotIn("unexpected fake xcodegen invocation", result.stdout)

    def test_release_package_rejects_swapped_cloudkit_profile_before_building(self):
        result = self.run_package_script_preflight(
            [
                "--identity",
                "Apple Development: Test",
                "--app-provisioning-profile",
                "app.plist",
                "--refresh-agent-provisioning-profile",
                "app.plist",
            ],
            profiles={
                "app.plist": self.cloudkit_profile_plist("com.shinycomputers.contextpanel"),
            },
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn(
            "Context Panel refresh agent provisioning profile does not authorize application identifier: "
            "MM5YXC7T6E.com.shinycomputers.contextpanel.refresh-agent",
            result.stdout,
        )
        self.assertNotIn("unexpected fake xcodegen invocation", result.stdout)

    def test_release_package_rejects_profile_without_cloudkit_service_before_building(self):
        result = self.run_package_script_preflight(
            [
                "--identity",
                "Apple Development: Test",
                "--app-provisioning-profile",
                "app.plist",
                "--refresh-agent-provisioning-profile",
                "refresh.plist",
            ],
            profiles={
                "app.plist": self.cloudkit_profile_plist(
                    "com.shinycomputers.contextpanel",
                    services=["CloudDocuments"],
                ),
                "refresh.plist": self.cloudkit_profile_plist("com.shinycomputers.contextpanel.refresh-agent"),
            },
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn(
            "Context Panel app provisioning profile does not authorize com.apple.developer.icloud-services: CloudKit",
            result.stdout,
        )
        self.assertNotIn("unexpected fake xcodegen invocation", result.stdout)

    def test_release_package_rejects_wrong_cloudkit_environment_before_building(self):
        result = self.run_package_script_preflight(
            [
                "--identity",
                "Apple Development: Test",
                "--app-provisioning-profile",
                "app.plist",
                "--refresh-agent-provisioning-profile",
                "refresh.plist",
            ],
            profiles={
                "app.plist": self.cloudkit_profile_plist(
                    "com.shinycomputers.contextpanel",
                    cloudkit_environment="Development",
                ),
                "refresh.plist": self.cloudkit_profile_plist("com.shinycomputers.contextpanel.refresh-agent"),
            },
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn(
            "Context Panel app provisioning profile does not authorize "
            "com.apple.developer.icloud-container-environment: Production",
            result.stdout,
        )
        self.assertNotIn("unexpected fake xcodegen invocation", result.stdout)

    def test_cloudkit_companion_schema_contract_matches_app_constants(self):
        schema = json.loads(self.read("CloudKit/companion-sync.schema.json"))
        remote_sync = self.read("Sources/ContextPanelCore/CompanionRemoteSync.swift")

        self.assertEqual(schema["containerIdentifier"], "iCloud.com.shinycomputers.contextpanel")
        self.assertEqual(schema["database"], "private")
        record_types = {record["name"]: record for record in schema["recordTypes"]}
        record = record_types["CompanionSyncDocument"]
        self.assertEqual(record["recordName"], "current")
        fields = {field["name"]: field["type"] for field in record["fields"]}
        self.assertEqual(fields["payload"], "BYTES")
        self.assertEqual(fields["schemaVersion"], "INT64")
        self.assertEqual(fields["documentSchemaVersion"], "INT64")
        self.assertEqual(fields["snapshotSchemaVersion"], "INT64")
        self.assertEqual(fields["generatedAt"], "TIMESTAMP")
        self.assertEqual(fields["publishedAt"], "TIMESTAMP")
        self.assertEqual(fields["payloadByteCount"], "INT64")
        for field_name in fields:
            self.assertIn(f'= "{field_name}"', remote_sync)

    def test_cloudkit_companion_schema_validator_documents_live_cktool_gate(self):
        script = self.read("scripts/validate-cloudkit-companion-schema.sh")
        release_docs = self.read("docs/release.md")

        self.assertIn("cktool export-schema", script)
        self.assertIn("CLOUDKIT_MANAGEMENT_TOKEN", script)
        self.assertIn("live_schema_has_field_type", script)
        self.assertIn("CompanionSyncDocument", script)
        self.assertIn("iCloud.com.shinycomputers.contextpanel", script)
        self.assertIn("CloudKit Production Schema Gate", release_docs)
        self.assertIn("scripts/validate-cloudkit-companion-schema.sh --live --environment production", release_docs)
        self.assertIn("CompanionSyncDocumentV2", release_docs)

    def test_cloudkit_companion_schema_validator_accepts_ckdb_export(self):
        result = self.run_cloudkit_schema_validator_with_fake_cktool(
            """RECORD TYPE CompanionSyncDocument {
  payload BYTES;
  schemaVersion INT64;
  documentSchemaVersion INT64;
  snapshotSchemaVersion INT64;
  generatedAt TIMESTAMP;
  publishedAt TIMESTAMP;
  payloadByteCount INT64;
}
"""
        )

        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("required field types in production", result.stdout)

    def test_cloudkit_companion_schema_validator_forwards_management_token(self):
        result = self.run_cloudkit_schema_validator_with_fake_cktool(
            """RECORD TYPE CompanionSyncDocument {
  payload BYTES;
  schemaVersion INT64;
  documentSchemaVersion INT64;
  snapshotSchemaVersion INT64;
  generatedAt TIMESTAMP;
  publishedAt TIMESTAMP;
  payloadByteCount INT64;
}
""",
            management_token="test-management-token",
            require_token=True,
        )

        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertNotIn("test-management-token", result.stdout)

    def test_cloudkit_companion_schema_validator_rejects_wrong_ckdb_field_type(self):
        result = self.run_cloudkit_schema_validator_with_fake_cktool(
            """RECORD TYPE CompanionSyncDocument {
  payload STRING;
  schemaVersion INT64;
  documentSchemaVersion INT64;
  snapshotSchemaVersion INT64;
  generatedAt TIMESTAMP;
  publishedAt TIMESTAMP;
  payloadByteCount INT64;
}
"""
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("CompanionSyncDocument.payload BYTES", result.stdout)

    def test_app_store_export_preserves_archived_build_number(self):
        upload_script = self.read("scripts/upload-app-store-connect-macos-app.sh")

        self.assertNotIn("manageAppVersionAndBuildNumber", upload_script)

    def test_upload_scripts_guard_against_app_store_marketing_version_regression(self):
        for script_path, expected_platform in (
            ("scripts/upload-app-store-connect-macos-app.sh", "--platform MAC_OS"),
            ("scripts/upload-app-store-connect-companion-app.sh", '--platform "$app_store_platform"'),
        ):
            with self.subTest(script_path=script_path):
                script = self.read(script_path)
                guard_index = script.index("scripts/app-store-version-guard.py")
                xcodegen_index = script.index("xcodegen generate --spec project.yml")

                self.assertLess(guard_index, xcodegen_index)
                self.assertIn("require_command python3", script)
                self.assertIn('if [[ "$upload" == "true" ]]; then', script)
                self.assertIn("--bundle-id com.shinycomputers.contextpanel", script)
                self.assertIn(expected_platform, script)
                self.assertIn('--version "$marketing_version"', script)
                self.assertIn('--api-key "$api_key_path"', script)

    def test_companion_upload_maps_release_platform_to_app_store_connect_platform(self):
        script = self.read("scripts/upload-app-store-connect-companion-app.sh")

        self.assertIn('app_store_platform="IOS"', script)
        self.assertIn('app_store_platform="VISION_OS"', script)

    def test_companion_upload_does_not_hard_code_closed_initial_marketing_version(self):
        script = self.read("scripts/upload-app-store-connect-companion-app.sh")

        self.assertIn("scripts/app-store-version-guard.py", script)
        self.assertNotIn('marketing_version" == "1.0"', script)
        self.assertNotIn("App Store marketing version 1.0 is closed", script)

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

    def test_companion_build_validation_supports_ios_visionos_and_watchos_without_signing(self):
        workflow = self.read(".github/workflows/ci.yml")
        script = self.read("scripts/validate-companion-builds.sh")

        self.assertIn("scripts/validate-companion-builds.sh", workflow)
        self.assertIn("--configuration Release --archive ios", workflow)
        self.assertIn("scripts/validate-companion-builds.sh --configuration Release watchos", workflow)
        self.assertIn("--archive", script)
        self.assertIn("archive validation is not supported for standalone watchOS", script)
        self.assertIn("Validating $scheme archive for $destination", script)
        self.assertIn("-archivePath \"$archive_path\"", script)
        self.assertIn("validate_archive_contents()", script)
        self.assertIn("iOS companion archive is missing embedded watch app", script)
        self.assertIn("iOS companion archive is missing embedded watch widget", script)
        self.assertIn("visionOS companion archive unexpectedly contains watch content", script)
        self.assertIn("Products/Applications/Context Panel.app", script)
        self.assertIn("Watch/Context Panel.app", script)
        self.assertIn("PlugIns/ContextPanelWatchWidgetExtension.appex", script)
        self.assertIn("platforms=(ios visionos watchos)", script)
        self.assertIn("generic/platform=iOS", script)
        self.assertIn("generic/platform=visionOS", script)
        self.assertIn("generic/platform=watchOS", script)
        self.assertIn("CODE_SIGNING_ALLOWED=NO", script)
        self.assertIn("ContextPanelCompanion", script)
        self.assertIn("ContextPanelWatch", script)
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
        self.assertIn("cleanup_stale_context_panel_profiles", script)
        self.assertIn("scripts/cleanup-context-panel-device-profiles.sh", script)
        self.assertIn("--preserve-app \"$app_path\"", script)
        self.assertIn("--no-profile-cleanup", script)
        self.assertIn("xcrun devicectl \"${launch_args[@]}\"", script)
        self.assertIn("com.shinycomputers.contextpanel", script)
        self.assertIn('if [[ "$2" == /* ]]; then', script)
        self.assertIn('derived_data_path="$repo_root/${2#./}"', script)
        self.assertIn("if ! ((build_only)); then", script)
        self.assertIn('if [[ "$launch_identifier" == "unknown" ]]; then', script)
        self.assertIn('launch_identifier=""', script)
        self.assertNotIn("require_command python3", script)

    def test_device_profile_cleanup_preserves_current_profiles_and_skips_app_store_profiles(self):
        script = self.read("scripts/cleanup-context-panel-device-profiles.sh")

        self.assertIn("embedded_profile_uuids", script)
        self.assertIn("find \"$app\" -name embedded.mobileprovision", script)
        self.assertIn("uuid_is_preserved", script)
        self.assertIn("--allow-without-preserve", script)
        self.assertIn("xcrun devicectl device profile list", script)
        self.assertIn("xcrun devicectl device profile remove", script)
        self.assertIn("matches_context_panel_bundle", script)
        self.assertIn("application-identifier", script)
        self.assertIn("get-task-allow", script)
        self.assertIn("iOS Team Provisioning Profile: ", script)
        self.assertIn("com.shinycomputers.contextpanel", script)
        self.assertIn("Mac Team Provisioning Profile: ", script)
        self.assertNotIn("Context Panel Companion App Store Profile", script)

    def test_device_profile_cleanup_matches_renamed_development_profiles_by_bundle(self):
        query = self.read("scripts/cleanup-context-panel-device-profiles.sh").split("jq -r --arg team_id \"$team_id\" '", 1)[1].split("' \"$profiles_json\"", 1)[0]
        profiles = {
            "result": {
                "provisioningProfiles": [
                    {
                        "uuid": "remove-renamed-app",
                        "name": "Chris Local Debug Profile",
                        "teamIdentifier": "MM5YXC7T6E",
                        "entitlements": {
                            "application-identifier": "MM5YXC7T6E.com.shinycomputers.contextpanel",
                            "get-task-allow": True,
                        },
                    },
                    {
                        "uuid": "keep-app-store-app",
                        "name": "Context Panel App Store Profile",
                        "teamIdentifier": "MM5YXC7T6E",
                        "entitlements": {
                            "application-identifier": "MM5YXC7T6E.com.shinycomputers.contextpanel",
                            "get-task-allow": False,
                        },
                    },
                    {
                        "uuid": "keep-other-app",
                        "name": "Other App Debug Profile",
                        "teamIdentifier": "MM5YXC7T6E",
                        "entitlements": {
                            "application-identifier": "MM5YXC7T6E.com.example.other",
                            "get-task-allow": True,
                        },
                    },
                    {
                        "uuid": "keep-other-team",
                        "name": "Context Panel Debug Other Team",
                        "teamIdentifier": "OTHERTEAM",
                        "entitlements": {
                            "application-identifier": "OTHERTEAM.com.shinycomputers.contextpanel",
                            "get-task-allow": True,
                        },
                    },
                    {
                        "uuid": "remove-widget-field",
                        "name": "Renamed Widget Debug",
                        "teamIdentifier": "MM5YXC7T6E",
                        "bundleIdentifier": "com.shinycomputers.contextpanel.widget",
                        "entitlements": {"get-task-allow": True},
                    },
                    {
                        "uuid": "remove-live-ios-name",
                        "name": "iOS Team Provisioning Profile: com.shinycomputers.contextpanel.widget",
                        "teamIdentifier": "MM5YXC7T6E",
                        "appIdentifier": "Context Panel Widget",
                        "entitlements": ["application-identifier", "get-task-allow"],
                    },
                    {
                        "uuid": "remove-mac-team-name",
                        "name": "Mac Team Provisioning Profile: com.shinycomputers.contextpanel",
                        "teamIdentifier": "MM5YXC7T6E",
                        "appIdentifier": "Context Panel",
                        "entitlements": ["application-identifier"],
                    },
                    {
                        "uuid": "keep-wildcard",
                        "name": "iOS Team Provisioning Profile: *",
                        "teamIdentifier": "MM5YXC7T6E",
                        "appIdentifier": "XC Wildcard",
                        "entitlements": ["application-identifier", "get-task-allow"],
                    },
                ]
            }
        }

        result = subprocess.run(
            ["jq", "-r", "--arg", "team_id", "MM5YXC7T6E", query],
            input=json.dumps(profiles),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(
            result.stdout.splitlines(),
            [
                "remove-renamed-app\tChris Local Debug Profile",
                "remove-widget-field\tRenamed Widget Debug",
                "remove-live-ios-name\tiOS Team Provisioning Profile: com.shinycomputers.contextpanel.widget",
                "remove-mac-team-name\tMac Team Provisioning Profile: com.shinycomputers.contextpanel",
            ],
        )

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

    def test_companion_upload_preflights_cloudkit_app_and_local_mirror_widget_profiles(self):
        script = self.read("scripts/upload-app-store-connect-companion-app.sh")

        self.assertIn("assert_profile_icloud_service()", script)
        self.assertIn("assert_profile_ubiquity_container()", script)
        self.assertIn("assert_profile_push_notifications()", script)
        self.assertIn("assert_profile_icloud_service \"$app_profile\" \"companion app\" \"CloudDocuments\"", script)
        self.assertIn("assert_profile_icloud_service \"$app_profile\" \"companion app\" \"CloudKit\"", script)
        self.assertIn("assert_profile_ubiquity_container \"$app_profile\" \"companion app\"", script)
        self.assertIn("assert_profile_push_notifications \"$app_profile\" \"companion app\" \"production\"", script)
        self.assertIn("--watch-profile PATH", script)
        self.assertIn("--watch-widget-profile PATH", script)
        self.assertIn("companion watch provisioning profile not found", script)
        self.assertIn("companion watch widget provisioning profile not found", script)
        self.assertIn(
            "assert_profile_bundle_id \"$watch_profile\" \"companion watch\" \"com.shinycomputers.contextpanel.watch\"",
            script,
        )
        self.assertIn(
            "assert_profile_bundle_id \"$watch_widget_profile\" \"companion watch widget\" \"com.shinycomputers.contextpanel.watch.widget\"",
            script,
        )
        self.assertIn("assert_profile_platform_any \"$watch_profile\" \"companion watch\" iOS watchOS", script)
        self.assertIn(
            "assert_profile_platform_any \"$watch_widget_profile\" \"companion watch widget\" iOS watchOS",
            script,
        )
        self.assertIn("assert_profile_icloud_service \"$watch_profile\" \"companion watch\" \"CloudKit\"", script)
        self.assertIn(
            "assert_profile_icloud_service \"$watch_widget_profile\" \"companion watch widget\" \"CloudKit\"",
            script,
        )
        self.assertIn('if [[ "$profile" == "$destination" ]]; then', script)
        self.assertIn("CONTEXT_PANEL_APP_STORE_WATCH_PROFILE_SPECIFIER=\"$watch_profile_uuid\"", script)
        self.assertIn(
            "CONTEXT_PANEL_APP_STORE_WATCH_WIDGET_PROFILE_SPECIFIER=\"$watch_widget_profile_uuid\"",
            script,
        )
        self.assertIn("<key>com.shinycomputers.contextpanel.watch</key>", script)
        self.assertIn("<key>com.shinycomputers.contextpanel.watch.widget</key>", script)
        self.assertNotIn("assert_profile_icloud_service \"$widget_profile\"", script)
        self.assertNotIn("assert_profile_ubiquity_container \"$widget_profile\"", script)
        self.assertNotIn("assert_profile_push_notifications \"$widget_profile\"", script)

    def test_release_docs_describe_cloudkit_companion_testflight_validation(self):
        release_docs = self.read("docs/release.md")

        self.assertIn("Use this path for issue #274", release_docs)
        self.assertIn("`testflight_beta_source=companion`", release_docs)
        self.assertIn("--platform MAC_OS", release_docs)
        self.assertIn("--version <active-companion-app-store-version>", release_docs)
        self.assertIn("--build-number <yyyymmddHHMM>", release_docs)
        self.assertIn("Mac-to-companion CloudKit dependency", release_docs)
        self.assertIn("CloudKit-backed companion snapshot", release_docs)
        self.assertIn("run that as separate `Ship` dispatches", release_docs)
        self.assertIn("widget reads the companion app's app-group mirror", release_docs)
        self.assertNotIn("issue #174", release_docs)
        self.assertNotIn("Mac-published iCloud companion document", release_docs)
        self.assertNotIn("companion app and widget profiles to authorize the Context Panel iCloud", release_docs)
        self.assertNotIn("read-only companion surfaces can sync fresh snapshots", release_docs)
        self.assertNotIn("--version 1.0.32", release_docs)

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

    def test_runtime_baseline_scans_and_cleans_companion_validation_artifact_cache(self):
        script = self.read("scripts/context-panel-runtime-baseline.sh")
        companion_validator = self.read("scripts/validate-companion-builds.sh")
        cleanup_function = re.search(r"quarantine_stale_runtime_bundles\(\) \{(?P<body>.*?)\n\}", script, re.S)
        local_builds_function = re.search(r"local_build_bundles\(\) \{(?P<body>.*?)\n\}", script, re.S)
        check_function = re.search(r"check_runtime\(\) \{(?P<body>.*?)\n\}", script, re.S)

        self.assertIsNotNone(cleanup_function)
        self.assertIsNotNone(local_builds_function)
        self.assertIsNotNone(check_function)
        assert cleanup_function is not None
        assert local_builds_function is not None
        assert check_function is not None
        self.assertIn("CONTEXT_PANEL_ARTIFACT_CACHE_ROOT", script)
        self.assertIn("/Volumes/Developer-Artifacts/github-actions/cache/cbusillo/context-panel", script)
        self.assertIn("artifact_cache_companion_build_validation_bundles", local_builds_function.group("body"))
        self.assertIn("artifact_cache_companion_build_validation_root", cleanup_function.group("body"))
        self.assertIn("derived-data/companion-build-validation", script)
        self.assertIn("derived-data/companion-build-validation", companion_validator)
        self.assertNotIn("quarantine_stale_runtime_bundles", check_function.group("body"))

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
