"""Runs the companion upload script against fixture profiles and a fixture archive.

The script decodes each provisioning profile with `security cms -D`. A fake
`security` on PATH copies a plain property list through, so the script's real
profile checks run against profiles this test controls. The preflight tests stop
at a fake `xcodegen`. The archive tests continue past it: the script's
CONTEXT_PANEL_UPLOAD_FIXTURE_TOOLS_DIR seam swaps in fixture `xcodebuild`,
`codesign`, and `xcrun`, which the script honours only for a local export.
"""

from concurrent.futures import ThreadPoolExecutor
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


INSTALL_DIRECTORY = "Library/MobileDevice/Provisioning Profiles"

APP = "Products/Applications/Context Panel.app"
COMPANION_WIDGET = f"{APP}/PlugIns/ContextPanelCompanionWidgetExtension.appex"
WATCH_APP = f"{APP}/Watch/Context Panel.app"
WATCH_WIDGET = f"{WATCH_APP}/PlugIns/ContextPanelWatchWidgetExtension.appex"
TOP_SHELF = f"{APP}/PlugIns/ContextPanelTVTopShelfExtension.appex"

FAKE_XCODEBUILD = r"""#!/bin/bash
printf '%s\x1f' "$@" >>"$FIXTURE_ROOT/xcodebuild.log"
printf '\n' >>"$FIXTURE_ROOT/xcodebuild.log"
arguments=("$@")
for ((index = 0; index < ${#arguments[@]}; index++)); do
	case "${arguments[index]}" in
	-archivePath) archive_path="${arguments[index + 1]}" ;;
	-exportPath) export_path="${arguments[index + 1]}" ;;
	esac
done
if [[ "${arguments[${#arguments[@]} - 1]}" == "archive" ]]; then
	exec /bin/cp -R "$FIXTURE_ROOT/archive-template" "$archive_path"
fi
/bin/mkdir -p "$export_path"
[[ -e "$FIXTURE_ROOT/no-ipa" ]] || : >"$export_path/Context Panel.ipa"
"""

FAKE_CODESIGN = r"""#!/bin/bash
bundle="${@: -1}"
case "$1" in
-d) exec /bin/cat "$bundle/.fixture-entitlements.plist" ;;
--verify) [[ ! -e "$bundle/.fixture-bad-signature" ]] ;;
*) exit 64 ;;
esac
"""

FAKE_XCRUN = r"""#!/bin/bash
[[ "$1 $2" == "dwarfdump --uuid" ]] || exit 64
if [[ -d "$3" ]]; then uuids="$3/.fixture-uuids"; else uuids="$3.fixture-uuids"; fi
while IFS= read -r uuid; do
	[[ -z "$uuid" ]] || echo "UUID: $uuid (arm64) $3"
done <"$uuids"
"""

FAKE_EXPECTED_BUILD_WRITER = r"""#!/bin/bash
printf '%s\n' "$@" >"$FIXTURE_ROOT/expected-build.log"
"""


def bundle(identifier: str, uuid: str, entitlements: dict, **info) -> dict:
    return {
        "info": {
            "CFBundleIdentifier": identifier,
            "CFBundleExecutable": "Executable",
            "CFBundleShortVersionString": "9.9.9",
            "CFBundleVersion": "999",
            **info,
        },
        "entitlements": entitlements,
        "uuids": [uuid],
        "signature_valid": True,
    }


def signed_cloudkit(*services: str) -> dict:
    return {
        APPLICATION_GROUPS: [APP_GROUP],
        ICLOUD_CONTAINERS: [CONTAINER],
        ICLOUD_SERVICES: list(services),
        ICLOUD_ENVIRONMENT: "Production",
    }


def ios_archive() -> dict:
    base = "com.shinycomputers.contextpanel"
    return {
        "bundles": {
            APP: bundle(
                base,
                "UUID-BINARY-APP",
                {
                    **signed_cloudkit("CloudKit", "CloudDocuments"),
                    UBIQUITY_CONTAINERS: [CONTAINER],
                    APS_ENVIRONMENT: "production",
                },
            ),
            COMPANION_WIDGET: bundle(f"{base}.widget", "UUID-BINARY-WIDGET", signed_cloudkit("CloudKit")),
            WATCH_APP: bundle(
                f"{base}.watch",
                "UUID-BINARY-WATCH",
                signed_cloudkit("CloudKit"),
                WKApplication=True,
                WKCompanionAppBundleIdentifier=base,
            ),
            WATCH_WIDGET: bundle(
                f"{base}.watch.widget",
                "UUID-BINARY-WATCH-WIDGET",
                signed_cloudkit("CloudKit"),
                NSExtension={"NSExtensionPointIdentifier": "com.apple.widgetkit-extension"},
            ),
        },
        "files": [],
        "dsyms": {
            "App.dSYM": ["UUID-BINARY-APP"],
            "Watch.dSYM": ["UUID-BINARY-WATCH"],
            "WatchWidget.dSYM": ["UUID-BINARY-WATCH-WIDGET"],
        },
    }


def tvos_archive() -> dict:
    base = "com.shinycomputers.contextpanel"
    isolation = {USER_MANAGEMENT: ["runs-as-current-user-with-user-independent-keychain"]}
    return {
        "bundles": {
            APP: bundle(
                base,
                "UUID-BINARY-TV",
                {**signed_cloudkit("CloudKit"), **isolation, APS_ENVIRONMENT: "production"},
                CFBundleIcons={"CFBundlePrimaryIcon": "App Icon - Small"},
                TVTopShelfImage={
                    "TVTopShelfPrimaryImage": "Top Shelf Image",
                    "TVTopShelfPrimaryImageWide": "Top Shelf Image Wide",
                },
            ),
            TOP_SHELF: bundle(
                f"{base}.topshelf",
                "UUID-BINARY-TOP-SHELF",
                {APPLICATION_GROUPS: [APP_GROUP], **isolation},
                UIRequiredDeviceCapabilities=["arm64"],
            ),
        },
        "files": [f"{APP}/Assets.car"],
        "dsyms": {},
    }


def install_archive_fixture(root: Path, working_directory: Path, archive: dict, environment: dict) -> None:
    tools = root / "fixture-tools"
    scripts = working_directory / "scripts"
    for path in (tools, scripts):
        path.mkdir(parents=True)
    for name, body in (("xcodebuild", FAKE_XCODEBUILD), ("codesign", FAKE_CODESIGN), ("xcrun", FAKE_XCRUN)):
        (tools / name).write_text(body)
        (tools / name).chmod(0o755)
    writer = scripts / "context-panel-write-expected-build.sh"
    writer.write_text(FAKE_EXPECTED_BUILD_WRITER)
    writer.chmod(0o755)
    if archive.get("no_ipa"):
        (root / "no-ipa").touch()

    template = root / "archive-template"
    for relative, content in archive["bundles"].items():
        path = template / relative
        path.mkdir(parents=True)
        (path / "Info.plist").write_bytes(plistlib.dumps(content["info"]))
        if content["entitlements"] is not None:
            (path / ".fixture-entitlements.plist").write_bytes(plistlib.dumps(content["entitlements"]))
        executable = path / content["info"]["CFBundleExecutable"]
        executable.write_text(f"executable of {relative}\n")
        Path(f"{executable}.fixture-uuids").write_text("".join(f"{uuid}\n" for uuid in content["uuids"]))
        if not content["signature_valid"]:
            (path / ".fixture-bad-signature").touch()
    for relative in archive["files"]:
        (template / relative).parent.mkdir(parents=True, exist_ok=True)
        (template / relative).touch()
    for name, uuids in archive["dsyms"].items():
        dsym = template / "dSYMs" / name
        dsym.mkdir(parents=True)
        (dsym / ".fixture-uuids").write_text("".join(f"{uuid}\n" for uuid in uuids))

    environment["FIXTURE_ROOT"] = str(root)
    environment["CONTEXT_PANEL_UPLOAD_FIXTURE_TOOLS_DIR"] = str(tools)


class ArchiveRun:
    def __init__(self, xcodebuild_calls, expected_build_arguments, receipt, ipa_exported):
        self.xcodebuild_calls = xcodebuild_calls
        self.expected_build_arguments = expected_build_arguments
        self.receipt = receipt
        self.ipa_exported = ipa_exported

    @property
    def exported(self) -> bool:
        return any("-exportArchive" in call for call in self.xcodebuild_calls)


def read_archive_run(root: Path) -> ArchiveRun:
    log = root / "xcodebuild.log"
    calls = [line.split("\x1f")[:-1] for line in log.read_text().splitlines()] if log.exists() else []
    expected_build = root / "expected-build.log"
    receipt_path = root / "WatchArchiveReceipt-iOS.txt"
    receipt = {}
    if receipt_path.exists():
        receipt = dict(line.split("=", 1) for line in receipt_path.read_text().splitlines())
    return ArchiveRun(
        calls,
        expected_build.read_text().splitlines() if expected_build.exists() else [],
        receipt,
        any((root / "export").glob("*.ipa")),
    )



def run_preflight(
    platform: str,
    profiles: dict[str, dict],
    *,
    missing: tuple[str, ...] = (),
    already_installed: tuple[str, ...] = (),
    archive: dict | None = None,
):
    """Returns the script result, the ExportOptions it wrote, and the installed profile names.

    With `archive`, fixture Xcode tools let the run continue past xcodegen, and the
    result gains an `ArchiveRun` describing what the script did with that archive.
    """
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        home = root / "home"
        bin_path = root / "bin"
        installed = home / INSTALL_DIRECTORY
        for path in (installed, bin_path):
            path.mkdir(parents=True)

        fake_security = bin_path / "security"
        fake_security.write_text(
            "#!/bin/bash\n"
            '[[ "$1 $2 $3" == "cms -D -i" && "$5" == "-o" ]] || { echo "unexpected: $*" >&2; exit 64; }\n'
            'exec /bin/cp "$4" "$6"\n'
        )
        fake_xcodegen = bin_path / "xcodegen"
        fake_xcodegen.write_text(f"#!/bin/bash\nexit {0 if archive is not None else XCODEGEN_REACHED}\n")
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
            if name in already_installed:
                path = installed / f"{content['UUID']}.provisionprofile"
            if name not in missing:
                path.write_bytes(plistlib.dumps(content))
            arguments += [f"--{name}-profile", str(path)]

        environment = {
            key: value
            for key, value in os.environ.items()
            if not key.startswith(("APP_STORE_CONNECT_", "COMPANION_APP_STORE_", "CONTEXT_PANEL_"))
        }
        environment["HOME"] = str(home)
        environment["PATH"] = f"{bin_path}:{environment['PATH']}"
        # The script resolves project.yml and the expected-build writer against its
        # working directory. An archive run gets a directory of its own, so the real
        # writer, which needs a clean checkout and a real archive, never runs.
        working_directory = REPO_ROOT
        if archive is not None:
            working_directory = root / "checkout"
            install_archive_fixture(root, working_directory, archive, environment)
        result = subprocess.run(
            ["/bin/bash", str(SCRIPT), *arguments],
            cwd=working_directory,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )
        if archive is not None:
            result.archive_run = read_archive_run(root)
        return (
            result,
            plistlib.loads(export_options.read_bytes()) if export_options.exists() else {},
            sorted(path.name for path in installed.glob("*")),
        )


class CompanionUploadProfilePreflightTests(unittest.TestCase):
    def run_preflight(self, platform: str, profiles: dict[str, dict], **options):
        return run_preflight(platform, profiles, **options)

    def assert_each_refused(self, platform: str, cases: list[tuple[dict[str, dict], str]]) -> None:
        # Every case is an independent script run in its own directory.
        with ThreadPoolExecutor(max_workers=8) as pool:
            outcomes = list(pool.map(lambda case: run_preflight(platform, case[0]), cases))
        for (_, message), (result, export_options, installed) in zip(cases, outcomes, strict=True):
            with self.subTest(message=message):
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
        refusals = []
        for mutate, message in cases:
            profiles = ios_profiles()
            mutate(profiles)
            refusals.append((profiles, message))
        self.assert_each_refused("ios", refusals)

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
        refusals = []
        for name, key, value, message in cases:
            profiles = tvos_profiles()
            if key == "Platform":
                profiles[name]["Platform"] = value
            else:
                profiles[name]["Entitlements"][key] = value
            refusals.append((profiles, message))
        self.assert_each_refused("tvos", refusals)

    def test_watch_profiles_may_target_either_ios_or_watchos(self):
        for watch, watch_widget in ((["watchOS"], ["iOS"]), (["iOS"], ["watchOS"])):
            with self.subTest(watch=watch, watch_widget=watch_widget):
                profiles = ios_profiles()
                profiles["watch"]["Platform"] = watch
                profiles["watch-widget"]["Platform"] = watch_widget

                result, _, _ = self.run_preflight("ios", profiles)

                self.assertEqual(result.returncode, XCODEGEN_REACHED, result.stdout)

    def test_a_missing_profile_file_is_named_before_any_profile_is_decoded(self):
        for name, message in (
            ("widget", "companion widget provisioning profile not found"),
            ("watch", "companion watch provisioning profile not found"),
            ("watch-widget", "companion watch widget provisioning profile not found"),
        ):
            with self.subTest(name=name):
                result, _, installed = self.run_preflight("ios", ios_profiles(), missing=(name,))

                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn(message, result.stdout)
                self.assertEqual(installed, [])

        result, _, _ = self.run_preflight("tvos", tvos_profiles(), missing=("tv-top-shelf",))
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("tvOS Top Shelf provisioning profile not found", result.stdout)

    def test_a_profile_already_at_its_install_location_is_accepted(self):
        result, export_options, installed = self.run_preflight(
            "ios", ios_profiles(), already_installed=("app", "watch")
        )

        self.assertEqual(result.returncode, XCODEGEN_REACHED, result.stdout)
        self.assertEqual(len(installed), 4)
        self.assertEqual(export_options["provisioningProfiles"]["com.shinycomputers.contextpanel"], "UUID-APP")


class CompanionUploadArchiveTests(unittest.TestCase):
    """Everything after xcodegen, against a fixture archive and fixture Xcode tools."""

    def assert_each_refused(self, platform: str, profiles, cases) -> None:
        with ThreadPoolExecutor(max_workers=8) as pool:
            outcomes = list(pool.map(lambda case: run_preflight(platform, profiles(), archive=case[0])[0], cases))
        for (_, message), result in zip(cases, outcomes, strict=True):
            with self.subTest(message=message):
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn(message, result.stdout)
                # A refused archive must never be exported or described as an expected build.
                self.assertFalse(result.archive_run.exported)
                self.assertEqual(result.archive_run.expected_build_arguments, [])
                self.assertFalse(result.archive_run.ipa_exported)

    def test_a_valid_ios_archive_is_archived_with_every_profile_then_exported(self):
        result, _, _ = run_preflight("ios", ios_profiles(), archive=ios_archive())
        run = result.archive_run

        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("this export is not a release artifact", result.stdout)
        archive_call, export_call = run.xcodebuild_calls
        self.assertEqual(archive_call[-1], "archive")
        for setting in (
            "CONTEXT_PANEL_APP_STORE_COMPANION_PROFILE_SPECIFIER=UUID-APP",
            "CONTEXT_PANEL_APP_STORE_COMPANION_WIDGET_PROFILE_SPECIFIER=UUID-WIDGET",
            "CONTEXT_PANEL_APP_STORE_WATCH_PROFILE_SPECIFIER=UUID-WATCH",
            "CONTEXT_PANEL_APP_STORE_WATCH_WIDGET_PROFILE_SPECIFIER=UUID-WATCH-WIDGET",
            "CURRENT_PROJECT_VERSION=999",
            "MARKETING_VERSION=9.9.9",
            f"DEVELOPMENT_TEAM={TEAM_ID}",
        ):
            self.assertIn(setting, archive_call)
        self.assertFalse([setting for setting in archive_call if "_TV_" in setting])
        self.assertIn("-exportArchive", export_call)
        self.assertTrue(run.ipa_exported)

        expected_build = run.expected_build_arguments
        self.assertEqual(expected_build[expected_build.index("--layout") + 1], "ios")
        self.assertEqual(
            sorted(value.split("=")[0] for flag, value in zip(expected_build, expected_build[1:]) if flag == "--profile"),
            ["companion.ios.app", "companion.ios.widget", "watchos.app", "watchos.widget"],
        )

    def test_the_ios_watch_receipt_describes_the_archived_bundles(self):
        result, _, _ = run_preflight("ios", ios_profiles(), archive=ios_archive())
        receipt = result.archive_run.receipt

        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(receipt["distribution_mode"], "export-only")
        self.assertEqual(receipt["local_ipa_expected"], "true")
        self.assertEqual(receipt["watch_app_bundle_id"], "com.shinycomputers.contextpanel.watch")
        self.assertEqual(receipt["watch_widget_bundle_id"], "com.shinycomputers.contextpanel.watch.widget")
        self.assertEqual(receipt["watch_app_build"], "999")
        self.assertEqual(receipt["companion_executable_uuids"], "UUID-BINARY-APP")
        self.assertEqual(receipt["companion_dsym"], "dSYMs/App.dSYM")
        self.assertEqual(receipt["watch_app_dsym"], "dSYMs/Watch.dSYM")
        self.assertEqual(receipt["watch_widget_dsym"], "dSYMs/WatchWidget.dSYM")
        self.assertRegex(receipt["watch_app_executable_sha256"], r"^[0-9a-f]{64}$")
        self.assertNotEqual(receipt["watch_app_executable_sha256"], receipt["companion_executable_sha256"])

    def test_a_valid_tvos_archive_uses_the_tv_profiles_and_writes_no_watch_receipt(self):
        result, _, _ = run_preflight("tvos", tvos_profiles(), archive=tvos_archive())
        run = result.archive_run

        self.assertEqual(result.returncode, 0, result.stdout)
        archive_call = run.xcodebuild_calls[0]
        self.assertIn("CONTEXT_PANEL_APP_STORE_TV_PROFILE_SPECIFIER=UUID-TV", archive_call)
        self.assertIn("CONTEXT_PANEL_APP_STORE_TV_TOP_SHELF_PROFILE_SPECIFIER=UUID-TOP-SHELF", archive_call)
        self.assertFalse([setting for setting in archive_call if "COMPANION" in setting or "WATCH" in setting])
        self.assertTrue(run.exported)
        self.assertEqual(run.receipt, {})
        expected_build = run.expected_build_arguments
        self.assertEqual(expected_build[expected_build.index("--layout") + 1], "tvos")

    def test_an_export_that_produces_no_ipa_fails(self):
        result, _, _ = run_preflight("tvos", tvos_profiles(), archive={**tvos_archive(), "no_ipa": True})

        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("export-only mode did not emit a local IPA", result.stdout)

    def test_each_ios_archive_defect_is_refused_before_export(self):
        def case(message, mutate):
            archive = ios_archive()
            mutate(archive["bundles"], archive)
            return archive, message

        def drop(*names):
            return lambda bundles, _: [bundles.pop(name) for name in names]

        def entitlement(name, key, value):
            return lambda bundles, _: bundles[name]["entitlements"].__setitem__(key, value)

        def without_entitlement(name, key):
            return lambda bundles, _: bundles[name]["entitlements"].pop(key)

        def info(name, key, value):
            return lambda bundles, _: bundles[name]["info"].__setitem__(key, value)

        def field(name, key, value):
            return lambda bundles, _: bundles[name].__setitem__(key, value)

        services = ICLOUD_SERVICES
        cases = [
            case("companion archive is missing the embedded widget extension", drop(COMPANION_WIDGET)),
            case("could not read signed entitlements from companion widget", field(COMPANION_WIDGET, "entitlements", None)),
            case("companion widget signed entitlements do not contain com.apple.security.application-groups", entitlement(COMPANION_WIDGET, APPLICATION_GROUPS, [])),
            case("companion widget signed entitlements do not contain com.apple.developer.icloud-container-identifiers", entitlement(COMPANION_WIDGET, ICLOUD_CONTAINERS, ["iCloud.com.example.other"])),
            case("companion widget signed entitlements do not contain com.apple.developer.icloud-services value: CloudKit", entitlement(COMPANION_WIDGET, services, [])),
            case("companion widget signed entitlements unexpectedly contain com.apple.developer.icloud-services value: CloudDocuments", entitlement(COMPANION_WIDGET, services, ["CloudKit", "CloudDocuments"])),
            case("companion widget signed entitlements have com.apple.developer.icloud-container-environment value 'Development', expected 'Production'", entitlement(COMPANION_WIDGET, ICLOUD_ENVIRONMENT, "Development")),
            case("companion widget signed entitlements unexpectedly contain: com.apple.developer.ubiquity-container-identifiers", entitlement(COMPANION_WIDGET, UBIQUITY_CONTAINERS, [CONTAINER])),
            case("companion widget signed entitlements unexpectedly contain: aps-environment", entitlement(COMPANION_WIDGET, APS_ENVIRONMENT, "production")),
            case("iOS archive is missing the embedded Watch app", drop(WATCH_APP, WATCH_WIDGET)),
            case("iOS archive is missing the embedded Watch complication extension", drop(WATCH_WIDGET)),
            case("iOS companion app marketing version is '1.0', expected '9.9.9'", info(APP, "CFBundleShortVersionString", "1.0")),
            case("companion Watch app marketing version is '1.0', expected '9.9.9'", info(WATCH_APP, "CFBundleShortVersionString", "1.0")),
            case("companion Watch widget build number is '1', expected '999'", info(WATCH_WIDGET, "CFBundleVersion", "1")),
            case("iOS companion app has CFBundleIdentifier value", info(APP, "CFBundleIdentifier", "com.example.other")),
            case("companion Watch app has CFBundleIdentifier value", info(WATCH_APP, "CFBundleIdentifier", "com.example.other")),
            case("companion Watch widget has CFBundleIdentifier value", info(WATCH_WIDGET, "CFBundleIdentifier", "com.example.other")),
            case("companion Watch app has WKApplication value 'false', expected 'true'", info(WATCH_APP, "WKApplication", False)),
            case("companion Watch app has WKCompanionAppBundleIdentifier value", info(WATCH_APP, "WKCompanionAppBundleIdentifier", "com.example.other")),
            case("companion Watch widget has NSExtension:NSExtensionPointIdentifier value", info(WATCH_WIDGET, "NSExtension", {"NSExtensionPointIdentifier": "com.example.other"})),
            case("companion Watch widget code signature verification failed", field(WATCH_WIDGET, "signature_valid", False)),
            case("companion Watch app code signature verification failed", field(WATCH_APP, "signature_valid", False)),
            case("iOS companion app code signature verification failed", field(APP, "signature_valid", False)),
            case("companion Watch app signed entitlements do not contain com.apple.security.application-groups", entitlement(WATCH_APP, APPLICATION_GROUPS, [])),
            case("companion Watch app signed entitlements do not contain com.apple.developer.icloud-container-identifiers", entitlement(WATCH_APP, ICLOUD_CONTAINERS, [])),
            case("companion Watch app signed entitlements do not contain com.apple.developer.icloud-services value: CloudKit", entitlement(WATCH_APP, services, [])),
            case("companion Watch app signed entitlements have com.apple.developer.icloud-container-environment value 'Development'", entitlement(WATCH_APP, ICLOUD_ENVIRONMENT, "Development")),
            case("companion Watch widget signed entitlements do not contain com.apple.security.application-groups", entitlement(WATCH_WIDGET, APPLICATION_GROUPS, [])),
            case("companion Watch widget signed entitlements do not contain com.apple.developer.icloud-container-identifiers", entitlement(WATCH_WIDGET, ICLOUD_CONTAINERS, [])),
            case("companion Watch widget signed entitlements do not contain com.apple.developer.icloud-services value: CloudKit", entitlement(WATCH_WIDGET, services, [])),
            case("companion Watch widget signed entitlements have com.apple.developer.icloud-container-environment value ''", without_entitlement(WATCH_WIDGET, ICLOUD_ENVIRONMENT)),
            case("companion Watch app archive dSYM does not cover every executable UUID", lambda _, archive: archive["dsyms"].pop("Watch.dSYM")),
            case("bundle executable has no DWARF UUIDs", field(WATCH_WIDGET, "uuids", [])),
        ]  # fmt: skip
        self.assert_each_refused("ios", ios_profiles, cases)

    def test_each_tvos_archive_defect_is_refused_before_export(self):
        def case(message, mutate):
            archive = tvos_archive()
            mutate(archive["bundles"], archive)
            return archive, message

        def entitlement(name, key, value):
            return lambda bundles, _: bundles[name]["entitlements"].__setitem__(key, value)

        def info(name, key, value):
            return lambda bundles, _: bundles[name]["info"].__setitem__(key, value)

        stray_widget = bundle("com.shinycomputers.contextpanel.widget", "UUID-STRAY", {})
        cases = [
            case("tvOS archive unexpectedly contains the iOS/visionOS companion widget", lambda bundles, _: bundles.__setitem__(COMPANION_WIDGET, stray_widget)),
            case("tvOS archive is missing the embedded Top Shelf extension", lambda bundles, _: bundles.pop(TOP_SHELF)),
            case("tvOS Top Shelf extension is missing the required arm64 device capability", info(TOP_SHELF, "UIRequiredDeviceCapabilities", [])),
            case("tvOS archive is missing compiled brand assets", lambda _, archive: archive["files"].clear()),
            case("tvOS archive is missing the primary layered app icon", info(APP, "CFBundleIcons", {"CFBundlePrimaryIcon": "AppIcon"})),
            case("tvOS archive is missing required standard or wide Top Shelf artwork", info(APP, "TVTopShelfImage", {"TVTopShelfPrimaryImage": "Top Shelf Image"})),
            case("tvOS Top Shelf extension code signature verification failed", lambda bundles, _: bundles[TOP_SHELF].__setitem__("signature_valid", False)),
            case("tvOS app code signature verification failed", lambda bundles, _: bundles[APP].__setitem__("signature_valid", False)),
            case("tvOS app signed entitlements do not contain com.apple.security.application-groups", entitlement(APP, APPLICATION_GROUPS, [])),
            case("tvOS app signed entitlements do not contain com.apple.developer.icloud-container-identifiers", entitlement(APP, ICLOUD_CONTAINERS, [])),
            case("tvOS app signed entitlements do not contain com.apple.developer.icloud-services value: CloudKit", entitlement(APP, ICLOUD_SERVICES, [])),
            case("tvOS app signed entitlements have com.apple.developer.icloud-container-environment value 'Development'", entitlement(APP, ICLOUD_ENVIRONMENT, "Development")),
            case("tvOS app signed entitlements have aps-environment value 'development', expected 'production'", entitlement(APP, APS_ENVIRONMENT, "development")),
            case("tvOS app signed entitlements do not contain com.apple.developer.user-management", entitlement(APP, USER_MANAGEMENT, [])),
            case("tvOS Top Shelf extension signed entitlements do not contain com.apple.security.application-groups", entitlement(TOP_SHELF, APPLICATION_GROUPS, [])),
            case("tvOS Top Shelf extension signed entitlements do not contain com.apple.developer.user-management", entitlement(TOP_SHELF, USER_MANAGEMENT, [])),
            case("tvOS Top Shelf extension signed entitlements unexpectedly contain: com.apple.developer.icloud-container-environment", entitlement(TOP_SHELF, ICLOUD_ENVIRONMENT, "Production")),
            case("tvOS Top Shelf extension signed entitlements unexpectedly contain: com.apple.developer.icloud-services", entitlement(TOP_SHELF, ICLOUD_SERVICES, ["CloudKit"])),
            case("tvOS Top Shelf extension signed entitlements unexpectedly contain: aps-environment", entitlement(TOP_SHELF, APS_ENVIRONMENT, "production")),
        ]  # fmt: skip
        self.assert_each_refused("tvos", tvos_profiles, cases)

    def test_fixture_tools_are_refused_for_an_upload(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "ran"
            for name in ("xcodebuild", "codesign", "xcrun"):
                tool = Path(directory) / name
                tool.write_text(f'#!/bin/bash\n: >"{marker}"\n')
                tool.chmod(0o755)
            environment = {
                key: value for key, value in os.environ.items() if not key.startswith("CONTEXT_PANEL_")
            }
            environment["CONTEXT_PANEL_UPLOAD_FIXTURE_TOOLS_DIR"] = directory
            result = subprocess.run(
                ["/bin/bash", str(SCRIPT), "--platform", "tvos", "--version", "9.9.9", "--build-number", "999"],
                cwd=directory,
                env=environment,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                check=False,
            )

            self.assertEqual(result.returncode, 2, result.stdout)
            self.assertIn("cannot be used for an upload", result.stdout)
            # Refused before the receipt gate, the profile checks, or any tool ran.
            self.assertNotIn("refusing live release mutation", result.stdout)
            self.assertNotIn("provisioning profile", result.stdout)
            self.assertFalse(marker.exists())


if __name__ == "__main__":
    unittest.main()
