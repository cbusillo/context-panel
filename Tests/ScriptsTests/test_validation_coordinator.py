import contextlib
import importlib.util
import io
import json
import os
import plistlib
import stat
import sys
import tempfile
import unittest
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path
from types import SimpleNamespace
from unittest import mock


SCRIPTS_PATH = Path(__file__).resolve().parents[2] / "scripts"
sys.path.insert(0, str(SCRIPTS_PATH))
PACKAGE_PATH = SCRIPTS_PATH / "context_panel_validation"
SPEC = importlib.util.spec_from_file_location(
    "context_panel_validation",
    PACKAGE_PATH / "__init__.py",
    submodule_search_locations=[str(PACKAGE_PATH)],
)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"Unable to load {PACKAGE_PATH}")
context_panel_validation = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = context_panel_validation
SPEC.loader.exec_module(context_panel_validation)
asc_module = sys.modules["context_panel_validation.asc"]
cli_module = __import__("context_panel_validation.cli", fromlist=["main"])
session_module = sys.modules["context_panel_validation.session"]
system_module = sys.modules["context_panel_validation.system"]


Target = context_panel_validation.Target
ASCPlatformEvidence = context_panel_validation.ASCPlatformEvidence
ASCEvidence = context_panel_validation.ASCEvidence
MacEvidence = context_panel_validation.MacEvidence
DeviceEvidence = context_panel_validation.DeviceEvidence


class FakeASCClient:
    def __init__(self, payloads):
        self.payloads = payloads
        self.requests = []

    def get(self, path, params=None):
        self.requests.append((path, params))
        if path.startswith("/betaGroups/"):
            group_id = path.split("/")[2]
            return self.payloads.get(("group", group_id), {"data": []})
        return self.payloads[path]


class FakeHTTPResponse:
    status = 200

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, traceback):
        return False

    def read(self):
        return b'{"data": []}'


def asc_build(build_id, platform, state="VALID", expired=False, version="1.0.53"):
    pre_release_id = f"pre-{platform}"
    return (
        {
            "id": build_id,
            "type": "builds",
            "attributes": {
                "version": "202607301200",
                "processingState": state,
                "expired": expired,
            },
            "relationships": {
                "preReleaseVersion": {
                    "data": {"type": "preReleaseVersions", "id": pre_release_id}
                }
            },
        },
        {
            "id": pre_release_id,
            "type": "preReleaseVersions",
            "attributes": {"version": version, "platform": platform},
        },
    )


def asc_payloads(group_all_builds=True):
    builds = []
    included = []
    for platform in context_panel_validation.ASC_PLATFORMS:
        build, pre_release = asc_build(f"build-{platform}", platform)
        builds.append(build)
        included.append(pre_release)
    group = {
        "id": "group-1",
        "type": "betaGroups",
        "attributes": {
            "isInternalGroup": True,
            "hasAccessToAllBuilds": group_all_builds,
        },
    }
    return {
        "/apps": {"data": [{"id": "app-1", "type": "apps", "attributes": {}}]},
        "/builds": {"data": builds, "included": included},
        "/apps/app-1/betaGroups": {"data": [group]},
        ("group", "group-1"): {"data": []},
    }


class FakeRunner:
    def __init__(self, list_payload=None, app_payloads=None, baseline=None):
        self.list_payload = list_payload
        self.app_payloads = app_payloads or {}
        self.baseline = baseline or context_panel_validation.CommandResult(
            0,
            "app-cloudkit=Production\nrefresh-agent-cloudkit=Production\n"
            "distribution=testflight\nbaseline=OK app=/Applications/Context Panel.app\n",
            "",
        )
        self.commands = []

    def run(self, args, *, timeout, environment=None):
        self.commands.append(list(args))
        if args and args[0].endswith("context-panel-runtime-baseline.sh"):
            return self.baseline
        if args[:4] == ["xcrun", "devicectl", "list", "devices"]:
            return self.write_json_result(args, self.list_payload)
        if args[:5] == ["xcrun", "devicectl", "device", "info", "apps"]:
            identifier = args[args.index("--device") + 1]
            payload = self.app_payloads.get(identifier)
            if payload is None:
                return context_panel_validation.CommandResult(64, "", "device is not available")
            return self.write_json_result(args, payload)
        raise AssertionError(f"unexpected command: {args}")

    def write_json_result(self, args, payload):
        if payload is None:
            return context_panel_validation.CommandResult(1, "", "unavailable")
        output_path = Path(args[args.index("--json-output") + 1])
        output_path.write_text(json.dumps(payload))
        log_path = Path(args[args.index("--log-output") + 1])
        log_path.write_text("")
        return context_panel_validation.CommandResult(0, "", "")


def physical_device(identifier, platform, device_type, connected=True, booted=True):
    return {
        "identifier": identifier,
        "hardwareProperties": {
            "platform": platform,
            "deviceType": device_type,
            "reality": "physical",
        },
        "connectionProperties": {
            "tunnelState": "connected" if connected else "disconnected",
            "pairingState": "paired",
        },
        "deviceProperties": {
            "bootState": "booted" if booted else "shutdown",
            "ddiServicesAvailable": connected,
        },
    }


def installed_app(
    version="1.0.53",
    build="202607301200",
    bundle_id="com.shinycomputers.contextpanel",
):
    return {
        "result": {
            "apps": [
                {
                    "bundleIdentifier": bundle_id,
                    "version": version,
                    "bundleVersion": build,
                }
            ]
        }
    }


def valid_asc():
    return ASCEvidence(
        "available",
        "direct_local_api",
        tuple(
            ASCPlatformEvidence(platform, "valid", "available", "VALID")
            for platform in context_panel_validation.ASC_PLATFORMS
        ),
    )


def processing_asc():
    return ASCEvidence(
        "available",
        "direct_local_api",
        tuple(
            ASCPlatformEvidence(platform, "processing", "processing", "PROCESSING")
            for platform in context_panel_validation.ASC_PLATFORMS
        ),
    )


def proven_mac(state="current"):
    return MacEvidence(
        "1.0.53",
        "202607301200",
        state,
        "proven",
        "running",
        "testflight",
        "Production",
        "Production",
    )


def device(label, platform, install_state="current", condition="reachable"):
    version = "1.0.53" if install_state in {"current", "superseded"} else "1.0.52"
    build = "202607301200" if install_state == "current" else "202607281100"
    if install_state == "superseded":
        version = "1.0.54"
        build = "202608010100"
    return DeviceEvidence(
        label,
        platform,
        version,
        build,
        install_state,
        condition,
        "fixture",
    )


class AppStoreConnectTests(unittest.TestCase):
    def test_network_client_can_only_issue_get_requests(self):
        client = context_panel_validation.ReadOnlyASCClient("token")
        with mock.patch.object(
            urllib.request,
            "urlopen",
            return_value=FakeHTTPResponse(),
        ) as urlopen:
            client.get("/apps", {"filter[bundleId]": "example"})

        request = urlopen.call_args.args[0]
        self.assertEqual(request.get_method(), "GET")
        self.assertIsNone(request.data)

    def test_valid_builds_in_all_build_group_are_available(self):
        client = FakeASCClient(asc_payloads())

        evidence = context_panel_validation.query_asc_with_client(
            client, Target("1.0.53", "202607301200")
        )

        self.assertEqual(evidence.status, "available")
        self.assertTrue(all(item.build_state == "valid" for item in evidence.platforms))
        self.assertTrue(all(item.testflight_state == "available" for item in evidence.platforms))
        self.assertTrue(all(request[0].startswith("/") for request in client.requests))

    def test_valid_build_not_in_internal_group_waits_for_assignment(self):
        client = FakeASCClient(asc_payloads(group_all_builds=False))

        evidence = context_panel_validation.query_asc_with_client(
            client, Target("1.0.53", "202607301200")
        )

        self.assertTrue(
            all(item.testflight_state == "waiting_for_assignment" for item in evidence.platforms)
        )

    def test_shared_build_number_never_matches_wrong_platform_or_version(self):
        payloads = asc_payloads()
        build, pre_release = asc_build("build-IOS", "IOS", version="1.0.52")
        payloads["/builds"] = {"data": [build], "included": [pre_release]}

        evidence = context_panel_validation.query_asc_with_client(
            FakeASCClient(payloads), Target("1.0.53", "202607301200")
        )

        self.assertTrue(all(item.build_state == "missing" for item in evidence.platforms))

    def test_missing_operator_config_is_unknown_without_network_access(self):
        with mock.patch.object(asc_module, "asc_credentials", return_value=None):
            evidence = context_panel_validation.collect_asc_evidence(
                FakeRunner(), Target("1.0.53", "202607301200"), Path("/missing")
            )

        self.assertEqual(evidence.status, "unavailable")
        self.assertEqual(evidence.source, "none")
        self.assertTrue(all(item.build_state == "unknown" for item in evidence.platforms))

    def test_operator_env_file_is_parsed_without_executing_shell_code(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            marker = root / "should-not-exist"
            env_file = root / "asc.env"
            env_file.write_text(
                "export APP_STORE_CONNECT_KEY_ID='key-id'\n"
                "export APP_STORE_CONNECT_ISSUER_ID='issuer-id'\n"
                f"export APP_STORE_CONNECT_API_KEY_PATH=$(touch {marker})\n"
            )
            runner = FakeRunner()
            with mock.patch.dict(os.environ, {}, clear=True):
                environment = asc_module.load_asc_environment(runner, env_file)

            self.assertEqual(environment["APP_STORE_CONNECT_KEY_ID"], "key-id")
            self.assertEqual(environment["APP_STORE_CONNECT_ISSUER_ID"], "issuer-id")
            self.assertNotIn("APP_STORE_CONNECT_API_KEY_PATH", environment)
            self.assertFalse(marker.exists())
            self.assertFalse(runner.commands)

    def test_temporary_key_is_removed_when_asc_read_fails(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            temporary_key = Path(temp_dir) / "temporary-key.p8"
            temporary_key.write_text("private key fixture")
            credentials = ("key-id", "issuer-id", temporary_key, temporary_key)
            with (
                mock.patch.object(asc_module, "asc_credentials", return_value=credentials),
                mock.patch.object(asc_module, "make_asc_token", return_value="token"),
                mock.patch.object(
                    asc_module,
                    "query_asc_with_client",
                    side_effect=asc_module.ASCReadError("read unavailable"),
                ),
            ):
                evidence = context_panel_validation.collect_asc_evidence(
                    FakeRunner(), Target("1.0.53", "202607301200"), Path("/unused")
                )

            self.assertFalse(temporary_key.exists())
            self.assertEqual(evidence.status, "unavailable")


class ParserTests(unittest.TestCase):
    def test_session_commands_parse_bounded_public_arguments(self):
        start = cli_module.parse_args(
            [
                "start-session",
                "--version",
                "1.0.53",
                "--build-number",
                "202607301200",
                "--surface",
                "macos.app",
                "--duration-hours",
                "24",
                "--retention-days",
                "14",
                "--json",
            ]
        )
        pause = cli_module.parse_args(
            [
                "pause-session",
                "--version",
                "1.0.53",
                "--build-number",
                "202607301200",
                "--reason",
                "hardware-unavailable",
            ]
        )

        self.assertEqual(start.command, "start-session")
        self.assertEqual(start.surfaces, ["macos.app"])
        self.assertEqual(start.duration_hours, 24)
        self.assertEqual(start.retention_days, 14)
        self.assertEqual(pause.reason, "hardware-unavailable")

    def test_install_classification_distinguishes_current_old_and_superseded(self):
        target = Target("1.0.53", "202607301200")

        self.assertEqual(
            context_panel_validation.classify_install("1.0.53", "202607301200", target),
            "current",
        )
        self.assertEqual(
            context_panel_validation.classify_install("1.0.52", "202607281100", target),
            "old",
        )
        self.assertEqual(
            context_panel_validation.classify_install("1.0.54", "202608010100", target),
            "superseded",
        )

    def test_baseline_parser_keeps_only_public_status_values(self):
        parsed = context_panel_validation.parse_key_values(
            "distribution=testflight\napp-cloudkit=Production\n"
            "refresh-agent-cloudkit=Production\nbaseline=OK app=/private/path\n"
        )

        self.assertEqual(
            parsed,
            {
                "distribution": "testflight",
                "app-cloudkit": "Production",
                "refresh-agent-cloudkit": "Production",
                "baseline": "OK",
            },
        )

    def test_baseline_parser_degrades_empty_values_to_unknown(self):
        parsed = context_panel_validation.parse_key_values(
            "baseline=\ndistribution=\napp-cloudkit=\nrefresh-agent-cloudkit=\n"
        )

        self.assertEqual(
            parsed,
            {
                "baseline": "unknown",
                "distribution": "unknown",
                "app-cloudkit": "unknown",
                "refresh-agent-cloudkit": "unknown",
            },
        )


class MacEvidenceCollectorTests(unittest.TestCase):
    target = Target("1.0.53", "202607301200")

    def collect(self, version, build, baseline):
        with tempfile.TemporaryDirectory() as temp_dir:
            info_plist = Path(temp_dir) / "Info.plist"
            if version is not None and build is not None:
                with info_plist.open("wb") as handle:
                    plistlib.dump(
                        {
                            "CFBundleShortVersionString": version,
                            "CFBundleVersion": build,
                        },
                        handle,
                    )
            with mock.patch.object(system_module, "CANONICAL_INFO_PLIST", info_plist):
                return context_panel_validation.collect_mac_evidence(
                    FakeRunner(baseline=baseline), self.target
                )

    @staticmethod
    def baseline(
        *,
        result="OK",
        returncode=0,
        app_cloudkit="Production",
        refresh_cloudkit="Production",
        process="OK: app process is running from installed runtime app",
    ):
        output = (
            f"app-cloudkit={app_cloudkit}\n"
            f"refresh-agent-cloudkit={refresh_cloudkit}\n"
            "distribution=testflight\n"
            f"{process}\n"
            f"baseline={result} failures=1\n"
        )
        return context_panel_validation.CommandResult(returncode, output, "")

    def test_current_target_with_passing_receipt_is_proven(self):
        evidence = self.collect("1.0.53", "202607301200", self.baseline())

        self.assertEqual(evidence.install_state, "current")
        self.assertEqual(evidence.baseline_state, "proven")

    def test_old_signed_build_waits_for_install_instead_of_blocking_publisher(self):
        evidence = self.collect(
            "1.0.52",
            "202607281100",
            self.baseline(result="FAIL", returncode=1),
        )
        report = context_panel_validation.build_report(
            self.target,
            valid_asc(),
            evidence,
            (),
            None,
            datetime(2026, 7, 30, 17, 0, tzinfo=timezone.utc),
        )

        self.assertEqual(evidence.baseline_state, "identity_verified_install_mismatch")
        self.assertEqual(report.state, "waiting")
        self.assertEqual(report.stage, "waiting on install")
        self.assertNotIn("publisher", report.headline.casefold())

    def test_current_target_with_failed_composite_receipt_is_unknown_not_blocked(self):
        evidence = self.collect(
            "1.0.53",
            "202607301200",
            self.baseline(result="FAIL", returncode=1),
        )
        report = context_panel_validation.build_report(
            self.target,
            valid_asc(),
            evidence,
            (),
            None,
            datetime(2026, 7, 30, 17, 0, tzinfo=timezone.utc),
        )

        self.assertEqual(evidence.baseline_state, "runtime_unverified")
        self.assertEqual(report.state, "unknown")
        self.assertEqual(report.exit_code, 30)
        self.assertIn("canonical Mac state is unknown", report.headline)
        self.assertNotIn("publisher", report.headline.casefold())

    def test_passing_receipt_without_main_app_process_requests_app_open(self):
        evidence = self.collect(
            "1.0.53",
            "202607301200",
            self.baseline(
                process="OK: refresh agent process is running from installed runtime app"
            ),
        )
        report = context_panel_validation.build_report(
            self.target,
            valid_asc(),
            evidence,
            (),
            None,
            datetime(2026, 7, 30, 17, 0, tzinfo=timezone.utc),
        )

        self.assertEqual(evidence.app_process_state, "not_running")
        self.assertEqual(evidence.baseline_state, "identity_verified_app_not_running")
        self.assertEqual(report.state, "ready_for_you")
        self.assertIn("Open the canonical Mac app once", report.actions[0].instruction)

    def test_explicit_development_identity_is_blocked(self):
        evidence = self.collect(
            "1.0.53",
            "202607301200",
            self.baseline(
                result="FAIL",
                returncode=1,
                app_cloudkit="Development",
                refresh_cloudkit="Development",
            ),
        )

        self.assertEqual(evidence.baseline_state, "failed")

    def test_missing_or_crashed_baseline_is_unknown(self):
        evidence = self.collect(
            "1.0.53",
            "202607301200",
            context_panel_validation.CommandResult(127, "", "command unavailable"),
        )

        self.assertEqual(evidence.baseline_state, "unknown")

    def test_missing_canonical_app_is_known_waiting_state(self):
        evidence = self.collect(
            None,
            None,
            self.baseline(
                result="FAIL",
                returncode=1,
                app_cloudkit="absent",
                refresh_cloudkit="absent",
                process="OK: no Context Panel processes are running",
            ),
        )

        self.assertEqual(evidence.install_state, "not_installed")
        self.assertEqual(evidence.baseline_state, "install_missing")


class CoreDeviceTests(unittest.TestCase):
    def test_device_inventory_queries_booted_physical_devices(self):
        list_payload = {
            "result": {
                "devices": [
                    physical_device("iphone-1", "iOS", "iPhone"),
                    physical_device("ipad-1", "iOS", "iPad", connected=False),
                    physical_device("watch-1", "watchOS", "appleWatch"),
                    {
                        **physical_device("sim-1", "visionOS", "realityDevice"),
                        "hardwareProperties": {
                            "platform": "visionOS",
                            "deviceType": "realityDevice",
                            "reality": "simulated",
                        },
                    },
                ]
            }
        }
        runner = FakeRunner(
            list_payload=list_payload,
            app_payloads={
                "iphone-1": installed_app(),
                "ipad-1": installed_app(),
                "watch-1": installed_app(
                    bundle_id="com.shinycomputers.contextpanel.watch"
                ),
            },
        )

        evidence = context_panel_validation.collect_device_evidence(
            runner, Target("1.0.53", "202607301200")
        )

        by_label = {item.label: item for item in evidence}
        self.assertEqual(by_label["iPhone"].install_state, "current")
        self.assertEqual(by_label["iPad"].install_state, "current")
        self.assertEqual(by_label["Apple Watch"].install_state, "current")
        self.assertEqual(by_label["Vision Pro"].condition, "not_found")
        commands = [" ".join(command) for command in runner.commands]
        self.assertTrue(any("ipad-1" in command and " info apps " in command for command in commands))
        self.assertTrue(
            all(
                "--timeout 20" in command
                for command in commands
                if " info apps " in command
            )
        )
        forbidden = (
            " install ",
            " uninstall ",
            " launch ",
            " reboot ",
            " capture ",
            " reset ",
            " erase ",
            " send ",
            " process ",
            " copy ",
            " openURL ",
        )
        self.assertFalse(any(token in f" {command} " for command in commands for token in forbidden))

    def test_disconnected_booted_device_is_unreachable_only_after_query_failure(self):
        runner = FakeRunner(
            list_payload={
                "result": {
                    "devices": [
                        physical_device(
                            "watch-1",
                            "watchOS",
                            "appleWatch",
                            connected=False,
                        )
                    ]
                }
            }
        )

        devices = context_panel_validation.collect_device_evidence(
            runner, Target("1.0.53", "202607301200")
        )

        watch = next(item for item in devices if item.label == "Apple Watch")
        self.assertEqual(watch.condition, "not_reachable")
        commands = [" ".join(command) for command in runner.commands]
        self.assertTrue(any("watch-1" in command and " info apps " in command for command in commands))

    def test_unpaired_platforms_do_not_hide_ready_watch_restart(self):
        runner = FakeRunner(
            list_payload={
                "result": {
                    "devices": [physical_device("watch-1", "watchOS", "appleWatch")]
                }
            },
            app_payloads={
                "watch-1": installed_app(
                    bundle_id="com.shinycomputers.contextpanel.watch"
                )
            },
        )
        devices = context_panel_validation.collect_device_evidence(
            runner, Target("1.0.53", "202607301200")
        )
        report = context_panel_validation.build_report(
            Target("1.0.53", "202607301200"),
            valid_asc(),
            proven_mac(),
            devices,
            None,
            datetime(2026, 7, 30, 17, 0, tzinfo=timezone.utc),
        )

        self.assertEqual(
            sum(item.condition == "not_found" for item in devices),
            4,
        )
        self.assertEqual(report.state, "ready_for_you")
        self.assertEqual(report.exit_code, 10)
        self.assertEqual([action.device for action in report.actions], ["Apple Watch"])

    def test_device_json_uses_public_camel_case_contract(self):
        public = device("iPhone", "iOS").public_dict()

        self.assertEqual(public["observedVersion"], "1.0.53")
        self.assertEqual(public["installState"], "current")
        self.assertNotIn("observed_version", public)


class ReportTests(unittest.TestCase):
    def setUp(self):
        self.target = Target("1.0.53", "202607301200")
        self.now = datetime(2026, 7, 30, 17, 0, tzinfo=timezone.utc)

    def report(self, asc, mac, devices, watch_restart_recorded_at=None):
        return context_panel_validation.build_report(
            self.target,
            asc,
            mac,
            tuple(devices),
            watch_restart_recorded_at,
            self.now,
        )

    def test_processing_is_waiting_and_needs_no_human_action(self):
        report = self.report(
            processing_asc(),
            proven_mac(),
            [device("iPhone", "iOS", "old")],
        )

        self.assertEqual(report.state, "waiting")
        self.assertEqual(report.stage, "waiting on Apple processing")
        self.assertEqual(report.exit_code, 0)
        self.assertFalse(report.actions)
        self.assertIn("nothing needs you right now", report.headline)

    def test_machine_waiting_states_suppress_other_ready_actions(self):
        watch = device("Apple Watch", "watchOS")
        cases = (
            (
                processing_asc(),
                proven_mac(),
                [watch],
                "waiting on Apple processing",
            ),
            (
                valid_asc(),
                proven_mac(),
                [device("iPhone", "iOS", "old"), watch],
                "waiting on install",
            ),
            (
                valid_asc(),
                proven_mac(),
                [device("iPhone", "iOS", "unknown", "locked"), watch],
                "waiting on device",
            ),
        )

        for asc, mac, devices, expected_stage in cases:
            with self.subTest(expected_stage=expected_stage):
                report = self.report(asc, mac, devices)
                self.assertEqual(report.state, "waiting")
                self.assertEqual(report.stage, expected_stage)
                self.assertEqual(report.exit_code, 0)
                self.assertFalse(report.actions)

    def test_mac_production_failure_blocks_downstream_review(self):
        mac = MacEvidence(
            "1.0.53",
            "202607301200",
            "current",
            "failed",
            "running",
            "development",
            "Development",
            "Development",
            "fixture",
        )

        report = self.report(valid_asc(), mac, [device("iPhone", "iOS")])

        self.assertEqual(report.state, "blocked")
        self.assertEqual(report.exit_code, 20)
        self.assertIn("Mac publisher", report.headline)

    def test_current_watch_requests_restart_until_recorded(self):
        devices = [device("Apple Watch", "watchOS")]

        ready = self.report(valid_asc(), proven_mac(), devices)
        recorded = self.report(
            valid_asc(),
            proven_mac(),
            devices,
            watch_restart_recorded_at="2026-07-30T17:00:00Z",
        )

        self.assertEqual(ready.state, "ready_for_you")
        self.assertEqual(ready.exit_code, 10)
        self.assertEqual(len(ready.actions), 1)
        self.assertIn("Restart the Watch once", ready.actions[0].instruction)
        self.assertEqual(recorded.state, "complete_for_slice")
        self.assertEqual(recorded.exit_code, 0)
        self.assertFalse(recorded.actions)

    def test_proven_runtime_completes_when_device_becomes_unreachable(self):
        report = self.report(
            valid_asc(),
            proven_mac(),
            [device("Apple Watch", "watchOS", "unknown", "not_reachable")],
            watch_restart_recorded_at="2026-07-30T17:00:00Z",
        )

        completed = context_panel_validation.apply_runtime_evidence_to_report(
            report,
            {
                "schemaVersion": 1,
                "state": "proven",
                "provenSurfaceCount": 2,
                "requestedSurfaceCount": 2,
                "lastReconciledAt": "2026-07-30T17:00:00Z",
                "runtimeSession": None,
                "diagnostics": [],
                "surfaces": [],
            },
        )

        self.assertEqual(completed.state, "complete_for_slice")
        self.assertEqual(completed.stage, "exact-build runtime proven")
        self.assertEqual(completed.exit_code, 0)

    def test_requested_surface_scope_excludes_out_of_scope_blockers_and_actions(self):
        asc = ASCEvidence(
            "available",
            "direct_local_api",
            tuple(
                ASCPlatformEvidence(
                    platform,
                    "invalid" if platform == "IOS" else "valid",
                    "available",
                    "INVALID" if platform == "IOS" else "VALID",
                )
                for platform in context_panel_validation.ASC_PLATFORMS
            ),
        )
        devices = (device("Apple Watch", "watchOS", "superseded"),)

        unscoped = context_panel_validation.build_report(
            self.target,
            asc,
            proven_mac(),
            devices,
            None,
            self.now,
        )
        mac_only = context_panel_validation.build_report(
            self.target,
            asc,
            proven_mac(),
            devices,
            None,
            self.now,
            requested_surfaces=("macos.app",),
        )

        self.assertEqual(unscoped.state, "blocked")
        self.assertEqual(mac_only.state, "complete_for_slice")
        self.assertFalse(mac_only.actions)
        self.assertEqual(mac_only.devices, devices)
        self.assertEqual(len(mac_only.asc.platforms), len(context_panel_validation.ASC_PLATFORMS))

    def test_watch_scope_ignores_out_of_scope_mac_failure(self):
        blocked_mac = MacEvidence(
            "1.0.53",
            "202607301200",
            "current",
            "failed",
            "running",
            "development",
            "Development",
            "Development",
            "fixture",
        )

        report = context_panel_validation.build_report(
            self.target,
            valid_asc(),
            blocked_mac,
            (device("Apple Watch", "watchOS"),),
            None,
            self.now,
            requested_surfaces=("watchos.app", "watchos.complication"),
        )

        self.assertEqual(report.state, "ready_for_you")
        self.assertEqual(report.exit_code, 10)
        self.assertEqual(report.actions[0].device, "Apple Watch")

    def test_superseded_device_blocks_target_evidence(self):
        report = self.report(
            valid_asc(),
            proven_mac(),
            [device("iPhone", "iOS", "superseded")],
        )

        self.assertEqual(report.state, "blocked")
        self.assertIn("moved to a newer build", report.headline)

    def test_superseded_mac_blocks_target_evidence(self):
        report = self.report(
            valid_asc(),
            proven_mac(state="superseded"),
            [device("iPhone", "iOS")],
        )

        self.assertEqual(report.state, "blocked")
        self.assertIn("Mac moved to a newer build", report.headline)

    def test_partial_asc_blindness_never_reports_complete(self):
        asc = ASCEvidence(
            "unavailable",
            "none",
            tuple(
                ASCPlatformEvidence(platform, "unknown", "unknown", reason="unavailable")
                for platform in context_panel_validation.ASC_PLATFORMS
            ),
            "unavailable",
        )

        report = self.report(asc, proven_mac(), [device("iPhone", "iOS")])

        self.assertEqual(report.state, "unknown")
        self.assertEqual(report.exit_code, 30)
        self.assertIn("App Store Connect state is unknown", report.headline)

    def test_unknown_testflight_assignment_never_reports_complete(self):
        asc = ASCEvidence(
            "available",
            "direct_local_api",
            tuple(
                ASCPlatformEvidence(platform, "valid", "unknown", "VALID", "no group visible")
                for platform in context_panel_validation.ASC_PLATFORMS
            ),
        )

        report = self.report(asc, proven_mac(), [device("iPhone", "iOS")])

        self.assertEqual(report.state, "unknown")
        self.assertEqual(report.exit_code, 30)

    def test_reachable_device_with_unknown_install_is_not_complete(self):
        unknown_device = DeviceEvidence(
            "iPhone",
            "iOS",
            "1.0.53",
            None,
            "unknown",
            "reachable",
            "install evidence unavailable",
        )

        report = self.report(valid_asc(), proven_mac(), [unknown_device])

        self.assertEqual(report.state, "unknown")
        self.assertEqual(report.exit_code, 30)
        self.assertIn("device install state is unknown", report.headline)

    def test_partial_asc_blindness_suppresses_watch_action(self):
        asc = ASCEvidence(
            "unavailable",
            "none",
            tuple(
                ASCPlatformEvidence(platform, "unknown", "unknown", reason="unavailable")
                for platform in context_panel_validation.ASC_PLATFORMS
            ),
            "unavailable",
        )

        report = self.report(
            asc,
            proven_mac(),
            [device("Apple Watch", "watchOS")],
        )

        self.assertEqual(report.state, "unknown")
        self.assertFalse(report.actions)

    def test_partial_asc_blindness_outranks_device_waiting(self):
        asc = ASCEvidence(
            "unavailable",
            "none",
            tuple(
                ASCPlatformEvidence(platform, "unknown", "unknown", reason="unavailable")
                for platform in context_panel_validation.ASC_PLATFORMS
            ),
            "unavailable",
        )
        waiting_device = DeviceEvidence(
            "iPhone",
            "iOS",
            None,
            None,
            "unknown",
            "not_reachable",
            "fixture",
        )

        report = self.report(asc, proven_mac(), [waiting_device])

        self.assertEqual(report.state, "unknown")
        self.assertEqual(report.exit_code, 30)

    def test_unknown_mac_process_state_never_reports_complete(self):
        mac = MacEvidence(
            "1.0.53",
            "202607301200",
            "current",
            "identity_verified",
            "unknown",
            "testflight",
            "Production",
            "Production",
            "canonical Production identity verified; app process state is unknown",
        )

        report = self.report(valid_asc(), mac, [device("iPhone", "iOS")])

        self.assertEqual(report.state, "unknown")
        self.assertEqual(report.exit_code, 30)
        self.assertIn("canonical Mac state is unknown", report.headline)

    def test_passive_mac_identity_requests_one_app_open_without_overclaiming(self):
        mac = MacEvidence(
            "1.0.53",
            "202607301200",
            "current",
            "identity_verified_app_not_running",
            "not_running",
            "testflight",
            "Production",
            "Production",
            "canonical Production identity verified; app is not running",
        )

        report = self.report(valid_asc(), mac, [device("iPhone", "iOS")])
        text = context_panel_validation.render_text(report)

        self.assertEqual(report.state, "ready_for_you")
        self.assertIn("Open the canonical Mac app once", report.actions[0].instruction)
        self.assertIn("Mac target Production identity verified; app not running", text)

    def test_json_contract_is_camel_case_and_surfaces_watch_attestation(self):
        report = self.report(
            valid_asc(),
            proven_mac(),
            [device("Apple Watch", "watchOS")],
            watch_restart_recorded_at="2026-07-30T17:00:00Z",
        )

        payload = report.to_dict()

        platform = payload["evidence"]["appStoreConnect"]["platforms"][0]
        mac = payload["evidence"]["canonicalMacProductionRuntime"]
        self.assertIn("buildState", platform)
        self.assertNotIn("build_state", platform)
        self.assertIn("appProcessState", mac)
        self.assertNotIn("app_process_state", mac)
        self.assertEqual(
            payload["evidence"]["watchRestartAttestation"]["recordedAt"],
            "2026-07-30T17:00:00Z",
        )

    def test_total_tool_blindness_is_unknown_not_failed(self):
        asc = ASCEvidence(
            "unavailable",
            "none",
            tuple(
                ASCPlatformEvidence(platform, "unknown", "unknown", reason="unavailable")
                for platform in context_panel_validation.ASC_PLATFORMS
            ),
            "unavailable",
        )
        mac = MacEvidence(
            None,
            None,
            "unknown",
            "unknown",
            "unknown",
            "unknown",
            "unknown",
            "unknown",
        )
        devices = [
            DeviceEvidence("iPhone", "iOS", None, None, "unknown", "unavailable", "fixture")
        ]

        report = self.report(asc, mac, devices)

        self.assertEqual(report.state, "unknown")
        self.assertEqual(report.exit_code, 30)
        self.assertNotIn("failed", report.headline.casefold())

    def test_text_is_answer_first_and_never_asks_for_keep_awake_behavior(self):
        report = self.report(
            valid_asc(),
            proven_mac(),
            [device("Apple Watch", "watchOS")],
        )

        text = context_panel_validation.render_text(report)

        self.assertTrue(text.startswith("1.0.53 (202607301200) — ready for you"))
        self.assertIn("Not proven by this slice", text)
        for banned in ("keep awake", "stay awake", "leave it unlocked", "please", "make sure"):
            self.assertNotIn(banned, text.casefold())


class StateStoreTests(unittest.TestCase):
    def test_default_state_root_is_the_canonical_app_group_validation_boundary(self):
        root = context_panel_validation.DEFAULT_STATE_ROOT

        self.assertEqual(
            root,
            Path.home()
            / "Library"
            / "Group Containers"
            / "MM5YXC7T6E.group.com.shinycomputers.contextpanel"
            / "Context Panel"
            / "Validation"
            / "Coordinator",
        )

    def test_watch_restart_attestation_persists_without_device_identifiers(self):
        target = Target("1.0.53", "202607301200")
        recorded_at = datetime(2026, 7, 30, 17, 0, tzinfo=timezone.utc)
        with tempfile.TemporaryDirectory() as temp_dir:
            store = context_panel_validation.SessionStateStore(Path(temp_dir))

            store.record_watch_restart(target, recorded_at)

            self.assertTrue(store.watch_restart_recorded(target))
            payload = json.loads(store.legacy_path(target).read_text())
            self.assertNotIn("device", json.dumps(payload).casefold())
            self.assertEqual(payload["watchRestartRecordedAt"], "2026-07-30T17:00:00Z")

    def test_missing_session_reads_do_not_create_state(self):
        target = Target("1.0.53", "202607301200")
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir) / "Coordinator"
            store = context_panel_validation.SessionStateStore(root)

            self.assertIsNone(store.load(target))
            self.assertIsNone(store.watch_restart_recorded_at(target))
            self.assertFalse(root.exists())

    def test_missing_session_read_uses_lock_when_store_exists(self):
        target = Target("1.0.53", "202607301200")
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir) / "Coordinator"
            root.mkdir()
            store = context_panel_validation.SessionStateStore(root)

            with mock.patch.object(session_module.fcntl, "flock") as flock:
                self.assertIsNone(store.load(target))

            self.assertEqual(flock.call_count, 2)

    def test_start_session_is_private_atomic_and_idempotent(self):
        target = Target("1.0.53", "202607301200")
        now = datetime(2026, 8, 1, 14, 0, tzinfo=timezone.utc)
        with tempfile.TemporaryDirectory() as temp_dir:
            store = context_panel_validation.SessionStateStore(Path(temp_dir))

            state, created = store.start_session(
                target,
                ("macos.app", "watchos.complication"),
                now,
                timedelta(hours=72),
                timedelta(days=30),
            )
            recovered, created_again = store.start_session(
                target,
                ("macos.app",),
                now + timedelta(minutes=1),
                timedelta(hours=24),
                timedelta(days=7),
            )

            self.assertTrue(created)
            self.assertFalse(created_again)
            self.assertEqual(recovered, state)
            self.assertEqual(state.requested_surfaces, ("macos.app", "watchos.complication"))
            payload = json.loads(store.path(target).read_text())
            self.assertEqual(payload["schemaVersion"], 1)
            self.assertNotIn("device", json.dumps(payload).casefold())
            self.assertEqual(stat.S_IMODE(store.path(target).stat().st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(Path(temp_dir).stat().st_mode), 0o700)

    def test_conflicting_active_target_is_blocked(self):
        now = datetime(2026, 8, 1, 14, 0, tzinfo=timezone.utc)
        with tempfile.TemporaryDirectory() as temp_dir:
            store = context_panel_validation.SessionStateStore(Path(temp_dir))
            store.start_session(
                Target("1.0.53", "202607301200"),
                ("macos.app",),
                now,
                timedelta(hours=72),
                timedelta(days=30),
            )

            with self.assertRaises(context_panel_validation.CoordinatorSessionConflictError):
                store.start_session(
                    Target("1.0.54", "202608010100"),
                    ("macos.app",),
                    now,
                    timedelta(hours=72),
                    timedelta(days=30),
                )

            with self.assertRaises(context_panel_validation.CoordinatorSessionConflictError):
                store.load(
                    Target("1.0.54", "202608010100"),
                    now=now + timedelta(minutes=1),
                )

    def test_multiple_active_state_files_fail_closed(self):
        target = Target("1.0.53", "202607301200")
        other_target = Target("1.0.54", "202608010100")
        now = datetime(2026, 8, 1, 14, 0, tzinfo=timezone.utc)
        with tempfile.TemporaryDirectory() as temp_dir:
            store = context_panel_validation.SessionStateStore(Path(temp_dir))
            store.start_session(
                target,
                ("macos.app",),
                now,
                timedelta(hours=72),
                timedelta(days=30),
            )
            other_state = context_panel_validation.create_session_state(
                other_target,
                ("macos.app",),
                now,
                timedelta(hours=72),
                timedelta(days=30),
            )
            store._write_state(store.path(other_target), other_state)

            with self.assertRaises(context_panel_validation.CoordinatorSessionConflictError):
                store.start_session(
                    target,
                    ("macos.app",),
                    now + timedelta(minutes=1),
                    timedelta(hours=72),
                    timedelta(days=30),
                )

    def test_explicit_replacement_archives_a_closed_prior_session(self):
        target = Target("1.0.53", "202607301200")
        now = datetime(2026, 8, 1, 14, 0, tzinfo=timezone.utc)
        with tempfile.TemporaryDirectory() as temp_dir:
            store = context_panel_validation.SessionStateStore(Path(temp_dir))
            original, _ = store.start_session(
                target,
                ("macos.app",),
                now,
                timedelta(hours=72),
                timedelta(days=30),
            )
            replacement, created = store.start_session(
                target,
                ("macos.app", "macos.widget"),
                now + timedelta(hours=1),
                timedelta(hours=72),
                timedelta(days=30),
                replace_existing=True,
            )

            archived = context_panel_validation.CoordinatorSessionState.from_dict(
                json.loads(
                    (store.archive_directory / f"{original.id.lower()}.json").read_text()
                )
            )
            self.assertTrue(created)
            self.assertNotEqual(replacement.id, original.id)
            self.assertEqual(archived.lifecycle, "stopped")
            self.assertEqual(archived.lifecycle_reason, "operator-stopped")

    def test_same_target_replacement_preserves_watch_restart_attestation(self):
        target = Target("1.0.53", "202607301200")
        now = datetime(2026, 8, 1, 14, 0, tzinfo=timezone.utc)
        recorded_at = now + timedelta(minutes=5)
        with tempfile.TemporaryDirectory() as temp_dir:
            store = context_panel_validation.SessionStateStore(Path(temp_dir))
            original, _ = store.start_session(
                target,
                ("watchos.app", "watchos.complication"),
                now,
                timedelta(hours=72),
                timedelta(days=30),
            )
            store.record_watch_restart(target, recorded_at)

            replacement, _ = store.start_session(
                target,
                ("watchos.app", "watchos.complication"),
                now + timedelta(hours=1),
                timedelta(hours=72),
                timedelta(days=30),
                replace_existing=True,
            )

            self.assertNotEqual(replacement.id, original.id)
            self.assertEqual(replacement.watch_restart_recorded_at, "2026-08-01T14:05:00Z")
            self.assertEqual(replacement.events[-1].kind, "watch-restart-recorded")
            self.assertEqual(replacement.events[-1].occurred_at, replacement.created_at)

    def test_failed_atomic_replace_preserves_previous_revision(self):
        target = Target("1.0.53", "202607301200")
        now = datetime(2026, 8, 1, 14, 0, tzinfo=timezone.utc)
        with tempfile.TemporaryDirectory() as temp_dir:
            store = context_panel_validation.SessionStateStore(Path(temp_dir))
            store.start_session(
                target,
                ("macos.app",),
                now,
                timedelta(hours=72),
                timedelta(days=30),
            )
            before = store.path(target).read_bytes()

            with (
                mock.patch.object(session_module.os, "replace", side_effect=OSError("fixture")),
                self.assertRaises(OSError),
            ):
                store.transition(
                    target,
                    "paused",
                    now + timedelta(minutes=1),
                    "operator-unavailable",
                )

            self.assertEqual(store.path(target).read_bytes(), before)
            self.assertFalse(list(store.sessions_directory.glob(".*.json.*")))

    def test_pause_resume_extends_deadline_and_stop_preserves_state(self):
        target = Target("1.0.53", "202607301200")
        now = datetime(2026, 8, 1, 14, 0, tzinfo=timezone.utc)
        with tempfile.TemporaryDirectory() as temp_dir:
            store = context_panel_validation.SessionStateStore(Path(temp_dir))
            started, _ = store.start_session(
                target,
                ("macos.app",),
                now,
                timedelta(hours=4),
                timedelta(days=30),
            )
            paused = store.transition(
                target,
                "paused",
                now + timedelta(hours=1),
                "operator-unavailable",
            )

            still_paused = store.load(target, now=now + timedelta(hours=8))
            resumed = store.transition(target, "resumed", now + timedelta(hours=3))
            stopped = store.transition(
                target,
                "stopped",
                now + timedelta(hours=4),
                "operator-stopped",
            )

            self.assertEqual(paused.lifecycle, "paused")
            self.assertEqual(still_paused.lifecycle, "paused")
            self.assertEqual(resumed.lifecycle, "active")
            self.assertEqual(resumed.accumulated_pause_seconds, 2 * 60 * 60)
            self.assertEqual(
                context_panel_validation.parse_iso8601(resumed.expires_at),
                context_panel_validation.parse_iso8601(started.expires_at) + timedelta(hours=2),
            )
            self.assertEqual(stopped.lifecycle, "stopped")
            self.assertTrue(store.path(target).is_file())

    def test_paused_session_can_record_watch_restart_after_nominal_deadline(self):
        target = Target("1.0.53", "202607301200")
        now = datetime(2026, 8, 1, 14, 0, tzinfo=timezone.utc)
        with tempfile.TemporaryDirectory() as temp_dir:
            store = context_panel_validation.SessionStateStore(Path(temp_dir))
            store.start_session(
                target,
                ("watchos.app", "watchos.complication"),
                now,
                timedelta(hours=1),
                timedelta(days=30),
            )
            store.transition(
                target,
                "paused",
                now + timedelta(minutes=30),
                "operator-unavailable",
            )

            store.record_watch_restart(target, now + timedelta(hours=2))
            resumed = store.transition(target, "resumed", now + timedelta(hours=3))

            self.assertEqual(resumed.watch_restart_recorded_at, "2026-08-01T16:00:00Z")
            self.assertEqual(resumed.lifecycle, "active")
            self.assertEqual(
                context_panel_validation.parse_iso8601(resumed.expires_at),
                now + timedelta(hours=3, minutes=30),
            )

    def test_watch_restart_is_rejected_outside_requested_surfaces(self):
        target = Target("1.0.53", "202607301200")
        now = datetime(2026, 8, 1, 14, 0, tzinfo=timezone.utc)
        with tempfile.TemporaryDirectory() as temp_dir:
            store = context_panel_validation.SessionStateStore(Path(temp_dir))
            store.start_session(
                target,
                ("macos.app",),
                now,
                timedelta(hours=72),
                timedelta(days=30),
            )

            with self.assertRaises(
                context_panel_validation.CoordinatorSessionTransitionError
            ):
                store.record_watch_restart(target, now + timedelta(minutes=1))

    def test_legacy_watch_restart_migrates_into_new_session(self):
        target = Target("1.0.53", "202607301200")
        recorded_at = datetime(2026, 7, 30, 17, 0, tzinfo=timezone.utc)
        now = datetime(2026, 8, 1, 14, 0, tzinfo=timezone.utc)
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir) / "Coordinator"
            legacy_root = Path(temp_dir) / "Legacy"
            store = context_panel_validation.SessionStateStore(root, legacy_root)
            store.record_watch_restart(target, recorded_at)

            state, _ = store.start_session(
                target,
                ("watchos.app", "watchos.complication"),
                now,
                timedelta(hours=72),
                timedelta(days=30),
            )

            self.assertEqual(state.watch_restart_recorded_at, "2026-07-30T17:00:00Z")
            self.assertEqual(state.events[-1].occurred_at, state.created_at)
            self.assertFalse(store.legacy_path(target).exists())
            self.assertTrue(store.path(target).exists())

    def test_terminal_session_defers_legacy_watch_migration_until_replacement(self):
        target = Target("1.0.53", "202607301200")
        now = datetime(2026, 8, 1, 14, 0, tzinfo=timezone.utc)
        recorded_at = now + timedelta(minutes=5)
        with tempfile.TemporaryDirectory() as temp_dir:
            store = context_panel_validation.SessionStateStore(Path(temp_dir))
            terminal, _ = store.start_session(
                target,
                ("watchos.app", "watchos.complication"),
                now,
                timedelta(hours=72),
                timedelta(days=30),
            )
            terminal = store.transition(
                target,
                "stopped",
                now + timedelta(minutes=1),
                "operator-stopped",
            )
            store._write_legacy_watch_restart(target, recorded_at)

            recovered, created = store.start_session(
                target,
                ("watchos.app", "watchos.complication"),
                now + timedelta(minutes=10),
                timedelta(hours=72),
                timedelta(days=30),
            )
            self.assertFalse(created)
            self.assertEqual(recovered, terminal)
            self.assertTrue(store.legacy_path(target).exists())

            replacement, replaced = store.start_session(
                target,
                ("watchos.app", "watchos.complication"),
                now + timedelta(minutes=11),
                timedelta(hours=72),
                timedelta(days=30),
                replace_existing=True,
            )

            self.assertTrue(replaced)
            self.assertEqual(replacement.watch_restart_recorded_at, "2026-08-01T14:05:00Z")
            self.assertFalse(store.legacy_path(target).exists())

    def test_expired_session_refuses_watch_restart_without_legacy_fallback(self):
        target = Target("1.0.53", "202607301200")
        now = datetime(2026, 8, 1, 14, 0, tzinfo=timezone.utc)
        with tempfile.TemporaryDirectory() as temp_dir:
            store = context_panel_validation.SessionStateStore(Path(temp_dir))
            store.start_session(
                target,
                ("watchos.app", "watchos.complication"),
                now,
                timedelta(hours=1),
                timedelta(days=30),
            )

            with self.assertRaises(
                context_panel_validation.CoordinatorSessionTransitionError
            ):
                store.record_watch_restart(target, now + timedelta(hours=2))

            state = store.load(target)
            self.assertEqual(state.lifecycle, "expired")
            self.assertIsNone(state.watch_restart_recorded_at)
            self.assertFalse(store.legacy_path(target).exists())

    def test_corrupt_session_fails_closed(self):
        target = Target("1.0.53", "202607301200")
        with tempfile.TemporaryDirectory() as temp_dir:
            store = context_panel_validation.SessionStateStore(Path(temp_dir))
            store.path(target).parent.mkdir(parents=True)
            store.path(target).write_text("{not-json")

            with self.assertRaises(context_panel_validation.CoordinatorSessionStateError):
                store.load(target)

    def test_session_target_must_match_its_state_path(self):
        target = Target("1.0.53", "202607301200")
        other_target = Target("1.0.54", "202608010100")
        now = datetime(2026, 8, 1, 14, 0, tzinfo=timezone.utc)
        with tempfile.TemporaryDirectory() as temp_dir:
            store = context_panel_validation.SessionStateStore(Path(temp_dir))
            state = context_panel_validation.create_session_state(
                other_target,
                ("macos.app",),
                now,
                timedelta(hours=72),
                timedelta(days=30),
            )
            store.path(target).parent.mkdir(parents=True)
            store.path(target).write_text(json.dumps(state.to_dict()))

            with self.assertRaises(context_panel_validation.CoordinatorSessionStateError):
                store.load(target)

    def test_mixed_type_requested_surfaces_fail_with_state_error(self):
        now = datetime(2026, 8, 1, 14, 0, tzinfo=timezone.utc)
        state = context_panel_validation.create_session_state(
            Target("1.0.53", "202607301200"),
            ("macos.app",),
            now,
            timedelta(hours=72),
            timedelta(days=30),
        )
        payload = state.to_dict()
        payload["requestedSurfaces"] = ["macos.app", 7]

        with self.assertRaises(context_panel_validation.CoordinatorSessionStateError):
            context_panel_validation.CoordinatorSessionState.from_dict(payload)

    def test_invalid_target_cannot_escape_state_root(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            store = context_panel_validation.SessionStateStore(Path(temp_dir))

            with self.assertRaises(context_panel_validation.CoordinatorSessionStateError):
                store.path(Target("../private", "1"))

    def test_transition_without_session_fails_closed(self):
        target = Target("1.0.53", "202607301200")
        now = datetime(2026, 8, 1, 14, 0, tzinfo=timezone.utc)
        with tempfile.TemporaryDirectory() as temp_dir:
            store = context_panel_validation.SessionStateStore(Path(temp_dir))

            with self.assertRaises(context_panel_validation.CoordinatorSessionStateError):
                store.transition(
                    target,
                    "paused",
                    now,
                    "operator-unavailable",
                )

    def test_symlinked_session_state_is_rejected(self):
        target = Target("1.0.53", "202607301200")
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            store = context_panel_validation.SessionStateStore(root / "Coordinator")
            outside = root / "outside.json"
            outside.write_text("{}")
            store.path(target).parent.mkdir(parents=True)
            store.path(target).symlink_to(outside)

            with self.assertRaises(context_panel_validation.CoordinatorSessionStateError):
                store.load(target)

    def test_broken_symlinked_session_state_is_rejected(self):
        target = Target("1.0.53", "202607301200")
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            store = context_panel_validation.SessionStateStore(root / "Coordinator")
            store.path(target).parent.mkdir(parents=True)
            store.path(target).symlink_to(root / "missing.json")

            with self.assertRaises(context_panel_validation.CoordinatorSessionStateError):
                store.load(target)

    def test_broken_symlinked_state_root_is_rejected(self):
        target = Target("1.0.53", "202607301200")
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            coordinator_root = root / "Coordinator"
            coordinator_root.symlink_to(root / "missing")
            store = context_panel_validation.SessionStateStore(coordinator_root)

            with self.assertRaises(context_panel_validation.CoordinatorSessionStateError):
                store.load(target)

    def test_non_directory_state_boundaries_fail_closed(self):
        target = Target("1.0.53", "202607301200")
        now = datetime(2026, 8, 1, 14, 0, tzinfo=timezone.utc)
        for boundary in ("Sessions", "Archive"):
            with self.subTest(boundary=boundary), tempfile.TemporaryDirectory() as temp_dir:
                root = Path(temp_dir) / "Coordinator"
                root.mkdir()
                (root / boundary).write_text("fixture")
                store = context_panel_validation.SessionStateStore(root)

                with self.assertRaises(context_panel_validation.CoordinatorSessionStateError):
                    store.load(target, now=now)

    def test_symlinked_legacy_boundary_cannot_mutate_session_or_external_file(self):
        target = Target("1.0.53", "202607301200")
        now = datetime(2026, 8, 1, 14, 0, tzinfo=timezone.utc)
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            coordinator_root = root / "Coordinator"
            legacy_root = root / "Legacy"
            outside = root / "Outside"
            store = context_panel_validation.SessionStateStore(
                coordinator_root,
                legacy_root,
            )
            state, _ = store.start_session(
                target,
                ("watchos.app", "watchos.complication"),
                now,
                timedelta(hours=72),
                timedelta(days=30),
            )
            outside.mkdir()
            outside_state = outside / f"{target.version}-{target.build_number}.json"
            outside_state.write_text("external fixture")
            legacy_root.symlink_to(outside, target_is_directory=True)

            with self.assertRaises(context_panel_validation.CoordinatorSessionStateError):
                store.record_watch_restart(target, now + timedelta(minutes=1))

            persisted = store.load(target)
            self.assertEqual(persisted.revision, state.revision)
            self.assertIsNone(persisted.watch_restart_recorded_at)
            self.assertEqual(outside_state.read_text(), "external fixture")

    def test_invalid_legacy_boundary_precedes_refresh_and_replacement_mutations(self):
        target = Target("1.0.53", "202607301200")
        now = datetime(2026, 8, 1, 14, 0, tzinfo=timezone.utc)
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            coordinator_root = root / "Coordinator"
            legacy_root = root / "Legacy"
            outside = root / "Outside"
            store = context_panel_validation.SessionStateStore(
                coordinator_root,
                legacy_root,
            )
            original, _ = store.start_session(
                target,
                ("watchos.app", "watchos.complication"),
                now,
                timedelta(hours=1),
                timedelta(days=30),
            )
            outside.mkdir()
            legacy_root.symlink_to(outside, target_is_directory=True)

            with self.assertRaises(context_panel_validation.CoordinatorSessionStateError):
                store.load(target, now=now + timedelta(hours=2))
            with self.assertRaises(context_panel_validation.CoordinatorSessionStateError):
                store.start_session(
                    target,
                    ("watchos.app", "watchos.complication"),
                    now + timedelta(hours=2),
                    timedelta(hours=72),
                    timedelta(days=30),
                    replace_existing=True,
                )

            persisted = store.load(target)
            self.assertEqual(persisted, original)
            self.assertFalse(store.archive_directory.exists())

    def test_expired_session_is_persisted_then_pruned(self):
        target = Target("1.0.53", "202607301200")
        now = datetime(2026, 8, 1, 14, 0, tzinfo=timezone.utc)
        with tempfile.TemporaryDirectory() as temp_dir:
            store = context_panel_validation.SessionStateStore(Path(temp_dir))
            store.start_session(
                target,
                ("macos.app",),
                now,
                timedelta(hours=1),
                timedelta(days=1),
            )

            expired = store.load(target, now=now + timedelta(hours=2))
            store.prune(now + timedelta(days=2))

            self.assertEqual(expired.lifecycle, "expired")
            self.assertFalse(store.path(target).exists())

    def test_normal_load_enforces_terminal_retention(self):
        target = Target("1.0.53", "202607301200")
        now = datetime(2026, 8, 1, 14, 0, tzinfo=timezone.utc)
        with tempfile.TemporaryDirectory() as temp_dir:
            store = context_panel_validation.SessionStateStore(Path(temp_dir))
            store.start_session(
                target,
                ("macos.app",),
                now,
                timedelta(hours=1),
                timedelta(days=1),
            )
            store.transition(
                target,
                "stopped",
                now + timedelta(minutes=30),
                "operator-stopped",
            )

            retained = store.load(target, now=now + timedelta(hours=24))
            pruned = store.load(target, now=now + timedelta(hours=26))

            self.assertEqual(retained.lifecycle, "stopped")
            self.assertIsNone(pruned)
            self.assertFalse(store.path(target).exists())

    def test_pure_reducer_supports_terminal_states(self):
        now = datetime(2026, 8, 1, 14, 0, tzinfo=timezone.utc)
        for event, reason, lifecycle in (
            ("blocked", "explicit-block", "blocked"),
            ("superseded", "newer-build-observed", "superseded"),
            ("completed", "evidence-complete", "completed"),
        ):
            with self.subTest(event=event):
                state = context_panel_validation.create_session_state(
                    Target("1.0.53", "202607301200"),
                    ("macos.app",),
                    now,
                    timedelta(hours=72),
                    timedelta(days=30),
                )
                transitioned = context_panel_validation.transition_session_state(
                    state,
                    event,
                    now + timedelta(minutes=1),
                    reason,
                )
                self.assertEqual(transitioned.lifecycle, lifecycle)
                self.assertEqual(transitioned.lifecycle_reason, reason)

    def test_event_history_is_bounded_without_losing_start_provenance(self):
        now = datetime(2026, 8, 1, 14, 0, tzinfo=timezone.utc)
        state = context_panel_validation.create_session_state(
            Target("1.0.53", "202607301200"),
            ("macos.app",),
            now,
            timedelta(hours=72),
            timedelta(days=30),
        )
        for index in range(70):
            state = context_panel_validation.transition_session_state(
                state,
                "paused",
                now + timedelta(minutes=index * 2 + 1),
                "operator-unavailable",
            )
            state = context_panel_validation.transition_session_state(
                state,
                "resumed",
                now + timedelta(minutes=index * 2 + 2),
            )

        self.assertEqual(len(state.events), 128)
        self.assertEqual(state.events[0].kind, "started")
        self.assertEqual(state.events[-1].kind, "resumed")

    def test_paused_session_suppresses_ready_actions(self):
        now = datetime(2026, 8, 1, 14, 0, tzinfo=timezone.utc)
        report = context_panel_validation.build_report(
            Target("1.0.53", "202607301200"),
            valid_asc(),
            proven_mac(),
            (device("Apple Watch", "watchOS"),),
            None,
            now,
        )
        session = context_panel_validation.create_session_state(
            report.target,
            ("watchos.app", "watchos.complication"),
            now,
            timedelta(hours=72),
            timedelta(days=30),
        )
        paused = context_panel_validation.transition_session_state(
            session,
            "paused",
            now + timedelta(minutes=1),
            "operator-unavailable",
        )

        updated = context_panel_validation.apply_session_state_to_report(report, paused)

        self.assertEqual(updated.state, "waiting")
        self.assertEqual(updated.stage, "paused")
        self.assertFalse(updated.actions)
        self.assertEqual(updated.session["lifecycle"], "paused")

    def test_paused_session_never_hides_blocked_or_unknown_evidence(self):
        now = datetime(2026, 8, 1, 14, 0, tzinfo=timezone.utc)
        target = Target("1.0.53", "202607301200")
        session = context_panel_validation.create_session_state(
            target,
            ("macos.app",),
            now,
            timedelta(hours=72),
            timedelta(days=30),
        )
        paused = context_panel_validation.transition_session_state(
            session,
            "paused",
            now + timedelta(minutes=1),
            "operator-unavailable",
        )
        blocked_mac = MacEvidence(
            "1.0.53",
            "202607301200",
            "current",
            "failed",
            "running",
            "development",
            "Development",
            "Development",
            "fixture",
        )
        unknown_asc = ASCEvidence(
            "unavailable",
            "none",
            tuple(
                ASCPlatformEvidence(platform, "unknown", "unknown", reason="unavailable")
                for platform in context_panel_validation.ASC_PLATFORMS
            ),
            "unavailable",
        )
        reports = (
            context_panel_validation.build_report(
                target,
                valid_asc(),
                blocked_mac,
                (device("iPhone", "iOS"),),
                None,
                now,
            ),
            context_panel_validation.build_report(
                target,
                unknown_asc,
                proven_mac(),
                (device("iPhone", "iOS"),),
                None,
                now,
            ),
        )

        for report in reports:
            with self.subTest(state=report.state):
                updated = context_panel_validation.apply_session_state_to_report(report, paused)
                self.assertEqual(updated.state, report.state)
                self.assertEqual(updated.stage, report.stage)
                self.assertEqual(updated.exit_code, report.exit_code)
                self.assertEqual(updated.headline, report.headline)
                self.assertEqual(updated.session["lifecycle"], "paused")


class CLITests(unittest.TestCase):
    def test_main_propagates_coordinator_exit_code(self):
        args = SimpleNamespace(command="status")
        with (
            mock.patch.object(cli_module, "parse_args", return_value=args),
            mock.patch.object(cli_module, "run_status", return_value=10),
        ):
            exit_code = cli_module.main([])

        self.assertEqual(exit_code, 10)

    def test_internal_error_does_not_print_private_paths(self):
        args = SimpleNamespace(command="status")
        stderr = io.StringIO()
        with (
            mock.patch.object(cli_module, "parse_args", return_value=args),
            mock.patch.object(
                cli_module,
                "run_status",
                side_effect=OSError("/Users/operator/.appstoreconnect/private_keys/secret.p8"),
            ),
            contextlib.redirect_stderr(stderr),
        ):
            exit_code = cli_module.main([])

        self.assertEqual(exit_code, 1)
        self.assertNotIn("/Users", stderr.getvalue())
        self.assertNotIn("secret.p8", stderr.getvalue())

    def test_status_refuses_another_active_target_before_collecting_evidence(self):
        active_target = Target("1.0.53", "202607301200")
        now = datetime(2026, 8, 1, 14, 0, tzinfo=timezone.utc)
        with tempfile.TemporaryDirectory() as temp_dir:
            store = context_panel_validation.SessionStateStore(Path(temp_dir))
            store.start_session(
                active_target,
                ("macos.app",),
                now,
                timedelta(hours=72),
                timedelta(days=30),
            )
            args = SimpleNamespace(
                command="status",
                version="1.0.54",
                build_number="202608010100",
                asc_env_file=Path("/unused"),
                json=True,
            )
            stderr = io.StringIO()
            with (
                mock.patch.dict(
                    os.environ,
                    {"CONTEXT_PANEL_VALIDATION_STATE_ROOT": temp_dir},
                    clear=False,
                ),
                mock.patch.object(cli_module, "parse_args", return_value=args),
                mock.patch.object(cli_module, "utc_now", return_value=now + timedelta(minutes=1)),
                mock.patch.object(cli_module, "collect_asc_evidence") as collect_asc,
                mock.patch.object(cli_module, "collect_mac_evidence") as collect_mac,
                mock.patch.object(cli_module, "collect_device_evidence") as collect_devices,
                contextlib.redirect_stderr(stderr),
            ):
                exit_code = cli_module.main([])

            self.assertEqual(exit_code, 20)
            self.assertIn("another signed validation session is active", stderr.getvalue())
            collect_asc.assert_not_called()
            collect_mac.assert_not_called()
            collect_devices.assert_not_called()

    def test_status_honors_requested_surface_scope(self):
        target = Target("1.0.53", "202607301200")
        now = datetime(2026, 8, 1, 14, 0, tzinfo=timezone.utc)
        with tempfile.TemporaryDirectory() as temp_dir:
            store = context_panel_validation.SessionStateStore(Path(temp_dir))
            store.start_session(
                target,
                ("macos.app",),
                now,
                timedelta(hours=72),
                timedelta(days=30),
            )
            stdout = io.StringIO()
            args = SimpleNamespace(
                version=target.version,
                build_number=target.build_number,
                asc_env_file=Path("/unused"),
                json=True,
            )
            with (
                mock.patch.dict(
                    os.environ,
                    {"CONTEXT_PANEL_VALIDATION_STATE_ROOT": temp_dir},
                    clear=False,
                ),
                mock.patch.object(cli_module, "utc_now", return_value=now + timedelta(minutes=1)),
                mock.patch.object(cli_module, "collect_asc_evidence", return_value=valid_asc()),
                mock.patch.object(cli_module, "collect_mac_evidence", return_value=proven_mac()),
                mock.patch.object(
                    cli_module,
                    "collect_device_evidence",
                    return_value=(device("Apple Watch", "watchOS"),),
                ),
                contextlib.redirect_stdout(stdout),
            ):
                exit_code = cli_module.run_status(args)

            payload = json.loads(stdout.getvalue())
            self.assertEqual(exit_code, 0)
            self.assertEqual(payload["summary"]["state"], "complete_for_slice")
            self.assertFalse(payload["actions"])
            self.assertEqual(payload["session"]["requestedSurfaces"], ["macos.app"])
            self.assertEqual(payload["evidence"]["devices"][0]["platform"], "watchOS")

    def test_status_reports_paused_session_without_ready_actions(self):
        target = Target("1.0.53", "202607301200")
        now = datetime(2026, 8, 1, 14, 0, tzinfo=timezone.utc)
        with tempfile.TemporaryDirectory() as temp_dir:
            store = context_panel_validation.SessionStateStore(Path(temp_dir))
            store.start_session(
                target,
                ("watchos.app", "watchos.complication"),
                now,
                timedelta(hours=72),
                timedelta(days=30),
            )
            store.transition(
                target,
                "paused",
                now + timedelta(minutes=1),
                "operator-unavailable",
            )
            stdout = io.StringIO()
            args = SimpleNamespace(
                version=target.version,
                build_number=target.build_number,
                asc_env_file=Path("/unused"),
                json=True,
            )
            with (
                mock.patch.dict(
                    os.environ,
                    {"CONTEXT_PANEL_VALIDATION_STATE_ROOT": temp_dir},
                    clear=False,
                ),
                mock.patch.object(cli_module, "utc_now", return_value=now + timedelta(minutes=2)),
                mock.patch.object(cli_module, "collect_asc_evidence", return_value=valid_asc()),
                mock.patch.object(cli_module, "collect_mac_evidence", return_value=proven_mac()),
                mock.patch.object(
                    cli_module,
                    "collect_device_evidence",
                    return_value=(device("Apple Watch", "watchOS"),),
                ),
                contextlib.redirect_stdout(stdout),
            ):
                exit_code = cli_module.run_status(args)

            payload = json.loads(stdout.getvalue())
            self.assertEqual(exit_code, 0)
            self.assertEqual(payload["summary"]["stage"], "paused")
            self.assertFalse(payload["summary"]["needsHumanAction"])
            self.assertEqual(payload["session"]["lifecycle"], "paused")

    def test_record_watch_restart_writes_only_local_attestation(self):
        recorded_at = datetime(2026, 7, 30, 17, 0, tzinfo=timezone.utc)
        with tempfile.TemporaryDirectory() as temp_dir:
            args = SimpleNamespace(
                version="1.0.53",
                build_number="202607301200",
                json=True,
            )
            stdout = io.StringIO()
            with (
                mock.patch.dict(
                    os.environ,
                    {"CONTEXT_PANEL_VALIDATION_STATE_ROOT": temp_dir},
                    clear=False,
                ),
                mock.patch.object(cli_module, "utc_now", return_value=recorded_at),
                mock.patch.object(
                    cli_module,
                    "collect_device_evidence",
                    return_value=(device("Apple Watch", "watchOS"),),
                ),
                contextlib.redirect_stdout(stdout),
            ):
                exit_code = cli_module.run_record_watch_restart(args)

            payload = json.loads(stdout.getvalue())
            state_files = list(Path(temp_dir).rglob("*.json"))
            self.assertEqual(exit_code, 0)
            self.assertEqual(payload["proof"], "operator_attestation")
            self.assertEqual(len(state_files), 1)
            self.assertNotIn("device", state_files[0].read_text().casefold())

    def test_record_watch_restart_refuses_unobserved_target(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            args = SimpleNamespace(
                version="1.0.53",
                build_number="202607301200",
                json=True,
            )
            stdout = io.StringIO()
            with (
                mock.patch.dict(
                    os.environ,
                    {"CONTEXT_PANEL_VALIDATION_STATE_ROOT": temp_dir},
                    clear=False,
                ),
                mock.patch.object(
                    cli_module,
                    "collect_device_evidence",
                    return_value=(
                        DeviceEvidence(
                            "Apple Watch",
                            "watchOS",
                            None,
                            None,
                            "unknown",
                            "asleep",
                            "will check when awake",
                        ),
                    ),
                ),
                contextlib.redirect_stdout(stdout),
            ):
                exit_code = cli_module.run_record_watch_restart(args)

            payload = json.loads(stdout.getvalue())
            self.assertEqual(exit_code, 30)
            self.assertFalse(payload["recorded"])
            self.assertFalse(list(Path(temp_dir).rglob("*.json")))

    def test_session_lifecycle_commands_share_one_persisted_state(self):
        target_args = {
            "version": "1.0.53",
            "build_number": "202607301200",
            "json": True,
        }
        started_at = datetime(2026, 8, 1, 14, 0, tzinfo=timezone.utc)
        with tempfile.TemporaryDirectory() as temp_dir:
            stdout = io.StringIO()
            with (
                mock.patch.dict(
                    os.environ,
                    {"CONTEXT_PANEL_VALIDATION_STATE_ROOT": temp_dir},
                    clear=False,
                ),
                mock.patch.object(cli_module, "utc_now", return_value=started_at),
                contextlib.redirect_stdout(stdout),
            ):
                exit_code = cli_module.run_start_session(
                    SimpleNamespace(
                        **target_args,
                        surfaces=["macos.app"],
                        duration_hours=72,
                        retention_days=30,
                        replace=False,
                    )
                )

            start_payload = json.loads(stdout.getvalue())
            self.assertEqual(exit_code, 0)
            self.assertTrue(start_payload["created"])
            self.assertEqual(start_payload["session"]["lifecycle"], "active")

            for function, offset, arguments, lifecycle in (
                (
                    cli_module.run_pause_session,
                    timedelta(hours=1),
                    {"reason": "operator-unavailable"},
                    "paused",
                ),
                (cli_module.run_resume_session, timedelta(hours=2), {}, "active"),
                (cli_module.run_stop_session, timedelta(hours=3), {}, "stopped"),
            ):
                stdout = io.StringIO()
                with (
                    mock.patch.dict(
                        os.environ,
                        {"CONTEXT_PANEL_VALIDATION_STATE_ROOT": temp_dir},
                        clear=False,
                    ),
                    mock.patch.object(cli_module, "utc_now", return_value=started_at + offset),
                    contextlib.redirect_stdout(stdout),
                ):
                    self.assertEqual(function(SimpleNamespace(**target_args, **arguments)), 0)
                self.assertEqual(json.loads(stdout.getvalue())["session"]["lifecycle"], lifecycle)

    def test_invalid_session_bounds_exit_unknown_without_writing_state(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            stderr = io.StringIO()
            with (
                mock.patch.dict(
                    os.environ,
                    {"CONTEXT_PANEL_VALIDATION_STATE_ROOT": temp_dir},
                    clear=False,
                ),
                contextlib.redirect_stderr(stderr),
            ):
                exit_code = cli_module.main(
                    [
                        "start-session",
                        "--version",
                        "1.0.53",
                        "--build-number",
                        "202607301200",
                        "--duration-hours",
                        "0",
                    ]
                )

            self.assertEqual(exit_code, 30)
            self.assertIn("session duration must be between", stderr.getvalue())
            self.assertFalse(list(Path(temp_dir).rglob("*.json")))


if __name__ == "__main__":
    unittest.main()
