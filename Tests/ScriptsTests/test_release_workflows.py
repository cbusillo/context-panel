import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]


class ReleaseWorkflowTests(unittest.TestCase):
    def read(self, relative_path: str) -> str:
        return (REPO_ROOT / relative_path).read_text()

    def test_ship_forwards_resolved_build_number_to_github_release(self):
        workflow = self.read(".github/workflows/ship.yml")

        self.assertIn("build_number: ${{ needs.validate.outputs.build_number }}", workflow)

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
        upload_script = self.read("scripts/upload-testflight-macos-app.sh")

        self.assertNotIn("manageAppVersionAndBuildNumber", upload_script)

    def test_runtime_baseline_uses_local_oauth_xcconfig_without_echoing_secret(self):
        script = self.read("scripts/context-panel-runtime-baseline.sh")

        self.assertIn(".local/context-panel-runtime.env", script)
        self.assertIn("runtime-baseline-local-oauth.xcconfig", script)
        self.assertIn('-xcconfig "$local_oauth_xcconfig_path"', script)
        self.assertIn("check_debug_google_oauth_config", script)
        self.assertIn("embeds debug Google OAuth config", script)
        self.assertIn("redact_build_output", script)
        self.assertIn("<redacted>", script)
        self.assertNotIn('CONTEXT_PANEL_GOOGLE_OAUTH_CLIENT_SECRET="${CONTEXT_PANEL_GOOGLE_OAUTH_CLIENT_SECRET:-}"', script)

    def test_runtime_baseline_local_env_file_is_ignored_but_example_is_tracked(self):
        gitignore = self.read(".gitignore")
        example = self.read(".local/context-panel-runtime.env.example")

        self.assertIn("!.local/context-panel-runtime.env.example", gitignore)
        self.assertIn(".local/context-panel-runtime.env", gitignore)
        self.assertIn(".build/runtime-baseline-local-oauth.xcconfig", gitignore)
        self.assertIn("CONTEXT_PANEL_GOOGLE_OAUTH_CLIENT_ID=", example)
        self.assertIn("CONTEXT_PANEL_GOOGLE_OAUTH_CLIENT_SECRET=", example)


if __name__ == "__main__":
    unittest.main()
