"""Runs the companion upload script against fixture provisioning profiles.

The script decodes each profile with `security cms -D`. A fake `security` on
PATH copies a plain property list through, so the script's real profile checks
run against profiles this test controls. A fake `xcodegen` stops the run at the
first step after the preflight, before anything is built.
"""

import copy
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts/upload-app-store-connect-companion-app.sh"

TEAM_ID = "FIXTURETEAM"
APP_GROUP = "group.com.shinycomputers.contextpanel"
CONTAINER = "iCloud.com.shinycomputers.contextpanel"
XCODEGEN_REACHED = 97

APPLICATION_GROUPS = "com.apple.security.application-groups"
ICLOUD_CONTAINERS = "com.apple.developer.icloud-container-identifiers"
ICLOUD_SERVICES = "com.apple.developer.icloud-services"
ICLOUD_ENVIRONMENT = "com.apple.developer.icloud-container-environment"
UBIQUITY_CONTAINERS = "com.apple.developer.ubiquity-container-identifiers"
USER_MANAGEMENT = "com.apple.developer.user-management"
APS_ENVIRONMENT = "aps-environment"


def profile(bundle_id: str, uuid: str, platforms: list[str], **entitlements) -> dict:
    return {
        "UUID": uuid,
        "Platform": platforms,
        "Entitlements": {
            "application-identifier": f"{TEAM_ID}.{bundle_id}",
            APPLICATION_GROUPS: [APP_GROUP],
            **entitlements,
        },
    }


def cloudkit(*services: str) -> dict:
    return {
        ICLOUD_CONTAINERS: [CONTAINER],
        ICLOUD_SERVICES: list(services),
        ICLOUD_ENVIRONMENT: ["Development", "Production"],
    }


def ios_profiles() -> dict[str, dict]:
    # Only the app carries a ubiquity container and an APNs environment, as in a
    # real release; the script must not demand either of the other profiles.
    base = "com.shinycomputers.contextpanel"
    return {
        "app": profile(
            base,
            "UUID-APP",
            ["iOS"],
            **cloudkit("CloudKit", "CloudDocuments"),
            **{UBIQUITY_CONTAINERS: [CONTAINER], APS_ENVIRONMENT: "production"},
        ),
        "widget": profile(f"{base}.widget", "UUID-WIDGET", ["iOS"], **cloudkit("CloudKit")),
        "watch": profile(f"{base}.watch", "UUID-WATCH", ["watchOS"], **cloudkit("CloudKit")),
        "watch-widget": profile(f"{base}.watch.widget", "UUID-WATCH-WIDGET", ["iOS"], **cloudkit("CloudKit")),
    }


def tvos_profiles() -> dict[str, dict]:
    base = "com.shinycomputers.contextpanel"
    isolation = {USER_MANAGEMENT: ["runs-as-current-user-with-user-independent-keychain"]}
    return {
        "app": profile(
            base, "UUID-TV", ["tvOS"], **cloudkit("CloudKit"), **isolation, **{APS_ENVIRONMENT: "production"}
        ),
        "tv-top-shelf": profile(f"{base}.topshelf", "UUID-TOP-SHELF", ["tvOS"], **isolation),
    }


class CompanionUploadProfilePreflightTests(unittest.TestCase):
    def run_preflight(self, platform: str, profiles: dict[str, dict]):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        home = root / "home"
        bin_path = root / "bin"
        for directory in (home, bin_path):
            directory.mkdir()

        fake_security = bin_path / "security"
        fake_security.write_text(
            "#!/bin/bash\n"
            '[[ "$1 $2 $3" == "cms -D -i" && "$5" == "-o" ]] || { echo "unexpected: $*" >&2; exit 64; }\n'
            'exec /bin/cp "$4" "$6"\n'
        )
        fake_xcodegen = bin_path / "xcodegen"
        fake_xcodegen.write_text(f"#!/bin/bash\nexit {XCODEGEN_REACHED}\n")
        for tool in (fake_security, fake_xcodegen):
            tool.chmod(0o755)

        api_key = root / "AuthKey.p8"
        api_key.write_text("not a key\n")
        export_options = root / "ExportOptions.plist"
        arguments = [
            "--platform", platform,
            "--version", "9.9.9",
            "--build-number", "999",
            "--export-only",
            "--team-id", TEAM_ID,
            "--api-key", str(api_key),
            "--api-key-id", "FIXTUREKEY",
            "--api-issuer-id", "fixture-issuer",
            "--export-options-path", str(export_options),
            "--archive-path", str(root / "fixture.xcarchive"),
            "--derived-data-path", str(root / "derived"),
            "--export-path", str(root / "export"),
        ]  # fmt: skip
        for name, content in profiles.items():
            path = root / f"{name}.provisionprofile"
            path.write_bytes(plistlib.dumps(content))
            arguments += [f"--{name}-profile", str(path)]

        environment = {
            key: value
            for key, value in os.environ.items()
            if not key.startswith(("APP_STORE_CONNECT_", "COMPANION_APP_STORE_", "CONTEXT_PANEL_"))
        }
        environment["HOME"] = str(home)
        environment["PATH"] = f"{bin_path}:{environment['PATH']}"
        result = subprocess.run(
            ["/bin/bash", str(SCRIPT), *arguments],
            cwd=REPO_ROOT,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )
        installed = home / "Library/MobileDevice/Provisioning Profiles"
        return (
            result,
            plistlib.loads(export_options.read_bytes()) if export_options.exists() else {},
            sorted(path.name for path in installed.glob("*")) if installed.exists() else [],
        )

    def assert_refused(self, platform: str, profiles: dict[str, dict], message: str) -> None:
        result, export_options, installed = self.run_preflight(platform, profiles)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn(message, result.stdout)
        # A refused profile set must not be installed or reach the export step.
        self.assertEqual(export_options, {})
        self.assertEqual(installed, [])

    def test_valid_ios_profiles_are_installed_and_mapped_to_every_bundle(self):
        result, export_options, installed = self.run_preflight("ios", ios_profiles())

        self.assertEqual(result.returncode, XCODEGEN_REACHED, result.stdout)
        self.assertEqual(
            export_options["provisioningProfiles"],
            {
                "com.shinycomputers.contextpanel": "UUID-APP",
                "com.shinycomputers.contextpanel.widget": "UUID-WIDGET",
                "com.shinycomputers.contextpanel.watch": "UUID-WATCH",
                "com.shinycomputers.contextpanel.watch.widget": "UUID-WATCH-WIDGET",
            },
        )
        self.assertEqual(export_options["teamID"], TEAM_ID)
        self.assertEqual(export_options["signingStyle"], "manual")
        self.assertEqual(
            installed,
            sorted(f"{uuid}.provisionprofile" for uuid in export_options["provisioningProfiles"].values()),
        )

    def test_valid_tvos_profiles_map_the_app_and_top_shelf_only(self):
        result, export_options, installed = self.run_preflight("tvos", tvos_profiles())

        self.assertEqual(result.returncode, XCODEGEN_REACHED, result.stdout)
        self.assertEqual(
            export_options["provisioningProfiles"],
            {
                "com.shinycomputers.contextpanel": "UUID-TV",
                "com.shinycomputers.contextpanel.topshelf": "UUID-TOP-SHELF",
            },
        )
        self.assertEqual(installed, ["UUID-TOP-SHELF.provisionprofile", "UUID-TV.provisionprofile"])

    def test_wildcard_icloud_service_and_scalar_environment_are_accepted(self):
        profiles = ios_profiles()
        profiles["widget"]["Entitlements"][ICLOUD_SERVICES] = ["*"]
        profiles["widget"]["Entitlements"][ICLOUD_ENVIRONMENT] = "Production"

        result, _, _ = self.run_preflight("ios", profiles)

        self.assertEqual(result.returncode, XCODEGEN_REACHED, result.stdout)

    def test_each_ios_profile_defect_is_refused(self):
        def without(name: str, key: str):
            def mutate(profiles):
                del profiles[name]["Entitlements"][key]

            return mutate

        def with_value(name: str, key: str, value):
            def mutate(profiles):
                profiles[name]["Entitlements"][key] = value

            return mutate

        def with_platform(name: str, platforms: list[str]):
            def mutate(profiles):
                profiles[name]["Platform"] = platforms

            return mutate

        other_app = f"{TEAM_ID}.com.example.other"
        cases = [
            (with_value("app", "application-identifier", other_app), "companion app provisioning profile has application identifier"),
            (with_value("widget", "application-identifier", other_app), "companion widget provisioning profile has application identifier"),
            (with_value("watch", "application-identifier", other_app), "companion watch provisioning profile has application identifier"),
            (with_value("watch-widget", "application-identifier", other_app), "companion watch widget provisioning profile has application identifier"),
            (with_platform("app", ["tvOS"]), "companion app provisioning profile does not support platform"),
            (with_platform("widget", ["tvOS"]), "companion widget provisioning profile does not support platform"),
            (with_platform("watch", ["tvOS"]), "companion watch provisioning profile does not support platform"),
            (with_platform("watch-widget", ["tvOS"]), "companion watch widget provisioning profile does not support platform"),
            (with_value("app", ICLOUD_SERVICES, ["CloudDocuments"]), "companion app provisioning profile does not authorize CloudKit"),
            (with_value("app", ICLOUD_SERVICES, ["CloudKit"]), "companion app provisioning profile does not authorize CloudDocuments"),
            (with_value("widget", ICLOUD_SERVICES, []), "companion widget provisioning profile does not authorize CloudKit"),
            (with_value("watch", ICLOUD_SERVICES, []), "companion watch provisioning profile does not authorize CloudKit"),
            (with_value("watch-widget", ICLOUD_SERVICES, []), "companion watch widget provisioning profile does not authorize CloudKit"),
            (with_value("app", ICLOUD_CONTAINERS, ["iCloud.com.example.other"]), "companion app provisioning profile does not authorize iCloud container"),
            (with_value("app", ICLOUD_ENVIRONMENT, ["Development"]), "companion app provisioning profile does not authorize iCloud environment: Production"),
            (with_value("widget", ICLOUD_ENVIRONMENT, "Development"), "companion widget provisioning profile does not authorize iCloud environment: Production"),
            (with_value("watch", ICLOUD_ENVIRONMENT, ["Development"]), "companion watch provisioning profile does not authorize iCloud environment: Production"),
            (with_value("watch-widget", ICLOUD_ENVIRONMENT, ["Development"]), "companion watch widget provisioning profile does not authorize iCloud environment: Production"),
            (without("app", UBIQUITY_CONTAINERS), "companion app provisioning profile does not authorize ubiquity container"),
            (with_value("app", APS_ENVIRONMENT, "development"), "companion app provisioning profile has APNs environment 'development', expected 'production'"),
            (without("app", APS_ENVIRONMENT), "companion app provisioning profile has APNs environment '', expected 'production'"),
            (with_value("app", APPLICATION_GROUPS, ["group.com.example.other"]), "companion app provisioning profile does not authorize app group"),
            (with_value("widget", APPLICATION_GROUPS, []), "companion widget provisioning profile does not authorize app group"),
            (with_value("watch", APPLICATION_GROUPS, []), "companion watch provisioning profile does not authorize app group"),
            (with_value("watch-widget", APPLICATION_GROUPS, []), "companion watch widget provisioning profile does not authorize app group"),
        ]  # fmt: skip
        for mutate, message in cases:
            with self.subTest(message=message):
                profiles = copy.deepcopy(ios_profiles())
                mutate(profiles)
                self.assert_refused("ios", profiles, message)

    def test_each_tvos_profile_defect_is_refused(self):
        cases = [
            ("app", "Platform", ["iOS"], "companion app provisioning profile does not support platform: tvOS"),
            ("tv-top-shelf", "Platform", ["iOS"], "tvOS Top Shelf provisioning profile does not support platform: tvOS"),
            ("tv-top-shelf", "application-identifier", f"{TEAM_ID}.com.shinycomputers.contextpanel.widget", "tvOS Top Shelf provisioning profile has application identifier"),
            ("app", USER_MANAGEMENT, [], "tvOS app provisioning profile does not authorize current-user isolation"),
            ("tv-top-shelf", USER_MANAGEMENT, [], "tvOS Top Shelf provisioning profile does not authorize current-user isolation"),
            ("app", APPLICATION_GROUPS, [], "tvOS app provisioning profile does not authorize app group"),
            ("tv-top-shelf", APPLICATION_GROUPS, [], "tvOS Top Shelf provisioning profile does not authorize app group"),
            ("app", APS_ENVIRONMENT, "development", "companion app provisioning profile has APNs environment 'development'"),
            ("app", ICLOUD_ENVIRONMENT, ["Development"], "companion app provisioning profile does not authorize iCloud environment: Production"),
        ]  # fmt: skip
        for name, key, value, message in cases:
            with self.subTest(message=message):
                profiles = tvos_profiles()
                if key == "Platform":
                    profiles[name]["Platform"] = value
                else:
                    profiles[name]["Entitlements"][key] = value
                self.assert_refused("tvos", profiles, message)


if __name__ == "__main__":
    unittest.main()
