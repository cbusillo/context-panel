import contextlib
import importlib.util
import io
import json
import os
import plistlib
import sys
import tempfile
import unittest
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from types import SimpleNamespace
from unittest import mock


PACKAGE_PATH = Path(__file__).resolve().parents[2] / "scripts" / "context_panel_validation"
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
    def test_device_inventory_queries_only_reachable_physical_devices(self):
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
        self.assertEqual(by_label["iPad"].condition, "not_reachable")
        self.assertEqual(by_label["Apple Watch"].install_state, "current")
        self.assertEqual(by_label["Vision Pro"].condition, "not_found")
        commands = [" ".join(command) for command in runner.commands]
        self.assertFalse(any("ipad-1" in command and " info apps " in command for command in commands))
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
    def test_watch_restart_attestation_persists_without_device_identifiers(self):
        target = Target("1.0.53", "202607301200")
        recorded_at = datetime(2026, 7, 30, 17, 0, tzinfo=timezone.utc)
        with tempfile.TemporaryDirectory() as temp_dir:
            store = context_panel_validation.SessionStateStore(Path(temp_dir))

            store.record_watch_restart(target, recorded_at)

            self.assertTrue(store.watch_restart_recorded(target))
            payload = json.loads(store.path(target).read_text())
            self.assertNotIn("device", json.dumps(payload).casefold())
            self.assertEqual(payload["watchRestartRecordedAt"], "2026-07-30T17:00:00Z")


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
            state_files = list(Path(temp_dir).glob("*.json"))
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
            self.assertFalse(list(Path(temp_dir).glob("*.json")))


if __name__ == "__main__":
    unittest.main()
