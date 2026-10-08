"""Exercise the actual Mac helper with fake tools and isolated profile storage.

Only Xcode orchestration is under test. Fingerprint generation and expected-build
collection are fixture collaborators, as in the companion upload fixtures.
"""

import plistlib
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/upload-app-store-connect-macos-app.sh"
VERSION = "9.9.9"
BUILD = "999"
FINGERPRINT = "fixture-source-fingerprint"

FAKE_XCODEBUILD = r"""#!/bin/bash
set -euo pipefail
printf '%s\x1f' "$@" >>"$FIXTURE_ROOT/xcodebuild.log"
printf '\n' >>"$FIXTURE_ROOT/xcodebuild.log"
arguments=("$@")
for ((index = 0; index < ${#arguments[@]}; index++)); do
    case "${arguments[index]}" in
    -archivePath) archive_path="${arguments[index + 1]}" ;;
    -exportPath) export_path="${arguments[index + 1]}" ;;
    -exportOptionsPlist) export_options="${arguments[index + 1]}" ;;
    esac
done
if [[ "${arguments[${#arguments[@]} - 1]}" == archive ]]; then
    [[ ! -e "$archive_path" ]] || exit 70
    exec /bin/cp -R "$FIXTURE_ROOT/archive-template" "$archive_path"
fi
[[ -d "$archive_path/Products" && -f "$export_options" ]] || exit 70
[[ "$(/usr/libexec/PlistBuddy -c 'Print :destination' "$export_options")" == export ]] || exit 71
/bin/mkdir -p "$export_path"
[[ -e "$FIXTURE_ROOT/no-pkg" ]] || echo 'fresh fixture package' >"$export_path/Context Panel.pkg"
exit 0
"""


class MacUploadScriptTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.checkout = self.root / "checkout"
        self.tools = self.root / "tools"
        scripts = self.checkout / "scripts"
        scripts.mkdir(parents=True)
        self.tools.mkdir()
        # An allowlist avoids inherited operator credentials, receipts or hooks.
        self.environment = {
            "HOME": str(self.root / "home"),
            "PATH": f"{self.tools}:/usr/bin:/bin:/usr/sbin:/sbin",
            "FIXTURE_ROOT": str(self.root),
            "CONTEXT_PANEL_UPLOAD_FIXTURE_TOOLS_DIR": str(self.tools),
        }
        self.write_tool(self.tools / "xcodebuild", FAKE_XCODEBUILD)
        self.write_tool(self.tools / "security", """#!/bin/bash
[[ "$1 $2 $3" == 'cms -D -i' && "$5" == -o ]] || exit 64
exec /bin/cp "$4" "$6"
""")
        self.write_tool(self.tools / "xcodegen", """#!/bin/bash
echo xcodegen >>"$FIXTURE_ROOT/xcodegen.log"
""")
        self.write_tool(scripts / "context-panel-build-fingerprint.sh",
                        f"#!/bin/bash\nprintf '%s\\n' '{FINGERPRINT}'\n")
        self.write_tool(scripts / "context-panel-write-expected-build.sh", """#!/bin/bash
printf '%s\n' "$@" >>"$FIXTURE_ROOT/expected-build.log"
""")
        self.archive = self.root / "fixture.xcarchive"
        self.export = self.root / "export"
        self.options = self.root / "ExportOptions.plist"
        self.template = self.root / "archive-template"
        contents = self.template / "Products/Applications/Context Panel.app/Contents"
        (contents / "Resources").mkdir(parents=True)
        (contents / "Resources/ContextPanelBuildFingerprint.txt").write_text(FINGERPRINT)
        (contents / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleShortVersionString": VERSION,
            "CFBundleVersion": BUILD,
        }))
        key = self.root / "AuthKey.p8"
        key.write_text("not a key")
        self.arguments = [
            "--team-id", "FIXTURETEAM", "--version", VERSION, "--build-number", BUILD,
            "--api-key", str(key), "--api-key-id", "FIXTUREKEY",
            "--api-issuer-id", "fixture-issuer", "--archive-path", str(self.archive),
            "--derived-data-path", str(self.root / "derived"),
            "--export-path", str(self.export), "--export-options-path", str(self.options),
        ]
        base = "com.shinycomputers.contextpanel"
        for name, identifier in (("app", base), ("widget", f"{base}.widget"),
                                 ("refresh-agent", f"{base}.refresh-agent")):
            profile = self.root / f"{name}.provisionprofile"
            profile.write_bytes(plistlib.dumps({
                "UUID": f"FIXTURE-{name}",
                "Entitlements": {
                    "com.apple.application-identifier": f"FIXTURETEAM.{identifier}",
                    "com.apple.security.application-groups": [f"FIXTURETEAM.group.{base}"],
                },
            }))
            self.arguments += [f"--{name}-profile", str(profile)]

    @staticmethod
    def write_tool(path, body):
        path.write_text(body)
        path.chmod(0o755)

    def run_helper(self, *flags, export_only=True):
        return subprocess.run(
            ["/bin/bash", str(SCRIPT), *self.arguments,
             *(["--export-only"] if export_only else []), *flags],
            cwd=self.checkout, env=self.environment, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30, check=False,
        )

    def calls(self):
        log = self.root / "xcodebuild.log"
        return [line.rstrip("\x1f").split("\x1f") for line in log.read_text().splitlines()] if log.exists() else []

    def reuse_archive(self, **info):
        shutil.copytree(self.template, self.archive)
        path = self.archive / "Products/Applications/Context Panel.app/Contents/Info.plist"
        path.write_bytes(plistlib.dumps({**plistlib.loads(path.read_bytes()), **info}))

    def test_archive_only_verifies_without_export_or_upload(self):
        result = self.run_helper("--archive-only")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(len(self.calls()), 1)
        self.assertEqual(self.calls()[0][-1], "archive")
        self.assertIn(f"MARKETING_VERSION={VERSION}", self.calls()[0])
        self.assertIn(f"CURRENT_PROJECT_VERSION={BUILD}", self.calls()[0])
        self.assertFalse(self.export.exists())
        self.assertTrue((self.root / "expected-build.log").exists())
        self.assertEqual(plistlib.loads(self.options.read_bytes())["destination"], "export")

    def test_resume_exports_existing_archive_without_rebuilding(self):
        archived = self.run_helper("--archive-only")
        self.assertEqual(archived.returncode, 0, archived.stdout)
        marker = self.archive / "preserve-me"
        marker.write_text("same archive")
        result = self.run_helper("--skip-archive")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(len(self.calls()), 2)
        self.assertEqual(self.calls()[0][-1], "archive")
        self.assertIn("-exportArchive", self.calls()[1])
        self.assertEqual(marker.read_text(), "same archive")
        self.assertTrue((self.export / "Context Panel.pkg").exists())

    def assert_mismatched_archive_refused(self, **info):
        self.reuse_archive(**info)
        result = self.run_helper("--skip-archive")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("version/build does not match", result.stdout)
        self.assertEqual(self.calls(), [])
        self.assertFalse((self.root / "expected-build.log").exists())

    def test_resume_refuses_version_mismatch_before_export(self):
        self.assert_mismatched_archive_refused(CFBundleShortVersionString="8.8.8")

    def test_resume_refuses_build_mismatch_before_export(self):
        self.assert_mismatched_archive_refused(CFBundleVersion="998")

    def test_resume_refuses_missing_archive_without_rebuilding(self):
        result = self.run_helper("--skip-archive")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("missing the build fingerprint", result.stdout)
        self.assertEqual(self.calls(), [])

    def test_archive_only_still_refuses_wrong_source_fingerprint(self):
        fingerprint = self.template / "Products/Applications/Context Panel.app/Contents/Resources/ContextPanelBuildFingerprint.txt"
        fingerprint.write_text("other source")
        result = self.run_helper("--archive-only")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("fingerprint does not match", result.stdout)
        self.assertEqual(len(self.calls()), 1)
        self.assertFalse(self.export.exists())
        self.assertFalse((self.root / "expected-build.log").exists())

    def test_old_package_cannot_replace_missing_new_export(self):
        self.reuse_archive()
        self.export.mkdir()
        stale = self.export / "Stale.pkg"
        stale.write_text("old package")
        (self.root / "no-pkg").touch()
        result = self.run_helper("--skip-archive")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("export did not produce a pkg", result.stdout)
        self.assertEqual(len(self.calls()), 1)
        self.assertIn("-exportArchive", self.calls()[0])
        self.assertFalse(stale.exists())

    def test_upload_refuses_fixture_tools_before_any_work(self):
        for flags in ((), ("--archive-only",), ("--skip-archive",)):
            with self.subTest(flags=flags):
                result = self.run_helper(*flags, export_only=False)
                self.assertEqual(result.returncode, 2, result.stdout)
                self.assertIn("cannot be used for an upload", result.stdout)
                self.assertEqual(self.calls(), [])
                self.assertFalse((self.root / "xcodegen.log").exists())
                self.assertFalse((self.root / "home").exists())
                self.assertFalse(self.options.exists())

    def test_conflicting_phase_flags_refused_before_tools(self):
        result = self.run_helper("--archive-only", "--skip-archive")
        self.assertEqual(result.returncode, 2, result.stdout)
        self.assertIn("cannot be combined", result.stdout)
        self.assertEqual(self.calls(), [])


if __name__ == "__main__":
    unittest.main()
