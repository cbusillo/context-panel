import unittest
from pathlib import Path
import base64
import subprocess
import re
import tempfile
import os
import json
import shlex
import hashlib
import shutil
import textwrap
import time


REPO_ROOT = Path(__file__).resolve().parents[2]
FIXTURE_SIGNING_CERTIFICATE = b"context-panel-fixture-signing-certificate"
FIXTURE_SIGNING_FINGERPRINT = hashlib.sha1(FIXTURE_SIGNING_CERTIFICATE).hexdigest().upper()


def indented_block(document: str, header: str, indent: int) -> str:
    lines = document.splitlines()
    target = f"{' ' * indent}{header}:"
    matches = [index for index, line in enumerate(lines) if line == target]
    if len(matches) != 1:
        raise AssertionError(f"expected one {target!r} block, found {len(matches)}")

    start = matches[0]
    end = len(lines)
    for index in range(start + 1, len(lines)):
        line = lines[index]
        if line.strip() and len(line) - len(line.lstrip()) <= indent:
            end = index
            break
    return "\n".join(lines[start:end])


def workflow_job(workflow: str, job_name: str) -> str:
    return indented_block(workflow, job_name, 2)


def workflow_step_run(workflow: str, job_name: str, step_name: str) -> str:
    job = workflow_job(workflow, job_name)
    lines = job.splitlines()
    target = f"      - name: {step_name}"
    matches = [index for index, line in enumerate(lines) if line == target]
    if len(matches) != 1:
        raise AssertionError(f"expected one {target!r} step, found {len(matches)}")

    start = matches[0]
    end = len(lines)
    for index in range(start + 1, len(lines)):
        line = lines[index]
        if line.startswith("      - "):
            end = index
            break
    lines = lines[start:end]
    target = "        run: |"
    matches = [index for index, line in enumerate(lines) if line == target]
    if len(matches) != 1:
        raise AssertionError(f"expected one run block, found {len(matches)}")
    return textwrap.dedent("\n".join(lines[matches[0] + 1 :]))


def workflow_run_blocks(workflow: str) -> tuple[str, ...]:
    lines = workflow.splitlines()
    blocks: list[str] = []
    for index, line in enumerate(lines):
        if line.strip() not in {"run: |", "run: |-", "run: >", "run: >-"}:
            continue
        indent = len(line) - len(line.lstrip())
        block_lines: list[str] = []
        for candidate in lines[index + 1 :]:
            candidate_indent = len(candidate) - len(candidate.lstrip())
            if candidate.strip() and candidate_indent <= indent:
                break
            block_lines.append(candidate)
        blocks.append(textwrap.dedent("\n".join(block_lines)))
    return tuple(blocks)


def workflow_job_needs(job: str) -> tuple[str, ...]:
    lines = job.splitlines()
    matches = [index for index, line in enumerate(lines) if line.startswith("    needs:")]
    if len(matches) != 1:
        raise AssertionError(f"expected one needs declaration, found {len(matches)}")

    declaration = lines[matches[0]].removeprefix("    needs:").strip()
    if declaration:
        return (declaration,)

    needs: list[str] = []
    for line in lines[matches[0] + 1 :]:
        if line.startswith("      - "):
            needs.append(line.removeprefix("      - ").strip())
            continue
        if line.strip():
            break
    if not needs:
        raise AssertionError("needs list is empty")
    return tuple(needs)


def workflow_choice_options(workflow: str, input_name: str) -> tuple[str, ...]:
    input_block = indented_block(workflow, input_name, 6)
    lines = input_block.splitlines()
    try:
        options_index = lines.index("        options:")
    except ValueError as error:
        raise AssertionError(f"{input_name} has no options block") from error

    options: list[str] = []
    for line in lines[options_index + 1 :]:
        if line.startswith("          - "):
            options.append(line.removeprefix("          - ").strip())
            continue
        if line.strip():
            break
    if not options:
        raise AssertionError(f"{input_name} options block is empty")
    return tuple(options)


def assert_lines_in_order(document: str, *expected_lines: str) -> None:
    normalized_lines = [re.sub(r"\s+", " ", line).strip() for line in document.splitlines()]
    search_start = 0
    previous_line = "the start of the document"
    for expected_line in expected_lines:
        normalized_expected_line = re.sub(r"\s+", " ", expected_line).strip()
        if not normalized_expected_line:
            raise AssertionError("expected lines must not be empty")
        try:
            line_index = normalized_lines.index(normalized_expected_line, search_start)
        except ValueError as error:
            raise AssertionError(
                f"expected line {normalized_expected_line!r} after {previous_line}"
            ) from error
        previous_line = f"line {line_index + 1} ({normalized_expected_line!r})"
        search_start = line_index + 1


class ReleaseWorkflowTests(unittest.TestCase):
    def read(self, relative_path: str) -> str:
        return (REPO_ROOT / relative_path).read_text()

    def expected_checkout_cache_key(self, checkout_root: Path) -> str:
        physical_root = str(checkout_root.resolve())
        return hashlib.sha256(f"{physical_root}\0".encode()).hexdigest()[:16]

    def run_commit_gate_cache_fixture(
        self,
        checkout_root: Path,
        artifact_cache_root: Path,
        *,
        invocation_root: Path | None = None,
        scratch_override: Path | None = None,
        include_standard_path: bool = True,
    ) -> subprocess.CompletedProcess[str]:
        scripts_path = checkout_root / "scripts"
        scripts_path.mkdir(parents=True, exist_ok=True)
        fixture_path = scripts_path / "commit-gate.sh"
        fixture_path.write_text(self.read("scripts/commit-gate.sh"))
        fixture_path.chmod(0o755)

        bin_path = checkout_root / ".test-bin"
        bin_path.mkdir(exist_ok=True)
        fake_swift = bin_path / "swift"
        fake_swift.write_text('#!/bin/bash\nprintf \'swift %s\\n\' "$*"\n')
        fake_swift.chmod(0o755)
        fake_python = bin_path / "python3"
        fake_python.write_text("#!/bin/bash\nexit 0\n")
        fake_python.chmod(0o755)

        path_entries = [str(bin_path)]
        if include_standard_path:
            path_entries.append(os.environ.get("PATH", ""))
        else:
            for command in ("dirname", "mkdir"):
                command_path = shutil.which(command)
                if command_path is None:
                    self.fail(f"required fixture command not found: {command}")
                fixture_command = bin_path / command
                if not fixture_command.exists():
                    fixture_command.symlink_to(command_path)

        environment = os.environ.copy()
        environment["CONTEXT_PANEL_ARTIFACT_CACHE_ROOT"] = str(artifact_cache_root)
        environment.pop("CONTEXT_PANEL_SWIFTPM_SCRATCH_PATH", None)
        if scratch_override is not None:
            environment["CONTEXT_PANEL_SWIFTPM_SCRATCH_PATH"] = str(scratch_override)
        environment["PATH"] = ":".join(path_entries)

        invoked_root = invocation_root or checkout_root
        return subprocess.run(
            ["/bin/bash", str(invoked_root / "scripts/commit-gate.sh")],
            cwd=invoked_root,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )

    def run_companion_cache_fixture(
        self,
        checkout_root: Path,
        artifact_cache_root: Path,
        *,
        derived_data_override: Path | None = None,
        cli_derived_data_root: Path | None = None,
        invocation_root: Path | None = None,
        working_directory: Path | None = None,
        include_standard_path: bool = True,
        fake_xcodebuild_body: str | None = None,
    ) -> subprocess.CompletedProcess[str]:
        scripts_path = checkout_root / "scripts"
        scripts_path.mkdir(parents=True, exist_ok=True)
        bin_path = checkout_root / ".test-bin"
        bin_path.mkdir(exist_ok=True)

        fake_xcodebuild = bin_path / "xcodebuild"
        fake_xcodebuild.write_text(
            fake_xcodebuild_body
            or "#!/bin/bash\nprintf '** BUILD SUCCEEDED **\\n'\n"
        )
        fake_xcodebuild.chmod(0o755)
        fake_xcodegen = bin_path / "xcodegen"
        fake_xcodegen.write_text("#!/bin/bash\nexit 0\n")
        fake_xcodegen.chmod(0o755)

        fixture_script = self.read("scripts/validate-companion-builds.sh")
        fixture_script = fixture_script.replace(
            "/usr/bin/xcodebuild", f'"{fake_xcodebuild}"'
        )
        fixture_path = scripts_path / "validate-companion-builds.sh"
        fixture_path.write_text(fixture_script)
        fixture_path.chmod(0o755)
        cache_helper = scripts_path / "context-panel-companion-cache.sh"
        cache_helper.write_text(self.read("scripts/context-panel-companion-cache.sh"))
        cache_helper.chmod(0o755)

        temp_path = checkout_root / ".runner-temp"
        temp_path.mkdir(exist_ok=True)
        environment = os.environ.copy()
        environment["CONTEXT_PANEL_ARTIFACT_CACHE_ROOT"] = str(artifact_cache_root)
        environment.pop("CONTEXT_PANEL_COMPANION_DERIVED_DATA_ROOT", None)
        if derived_data_override is not None:
            environment["CONTEXT_PANEL_COMPANION_DERIVED_DATA_ROOT"] = str(
                derived_data_override
            )
        path_entries = [str(bin_path)]
        if include_standard_path:
            path_entries.append(environment.get("PATH", ""))
        else:
            for command in ("dirname", "mktemp"):
                command_path = shutil.which(command)
                if command_path is None:
                    self.fail(f"required fixture command not found: {command}")
                fixture_command = bin_path / command
                if not fixture_command.exists():
                    fixture_command.symlink_to(command_path)
        environment["PATH"] = ":".join(path_entries)
        environment["RUNNER_TEMP"] = str(temp_path)
        environment["TMPDIR"] = str(temp_path)

        invoked_root = invocation_root or checkout_root
        arguments = [
            "/bin/bash",
            str(invoked_root / "scripts/validate-companion-builds.sh"),
        ]
        if cli_derived_data_root is not None:
            arguments.extend(["--derived-data-root", str(cli_derived_data_root)])
        arguments.append("ios")
        return subprocess.run(
            arguments,
            cwd=working_directory or invoked_root,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
            timeout=30,
        )

    def run_companion_cache_helper(
        self,
        command: str,
        root: Path | None = None,
        *,
        environment: dict[str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        arguments = [
            "/bin/bash",
            str(REPO_ROOT / "scripts/context-panel-companion-cache.sh"),
            command,
        ]
        if root is not None:
            arguments.extend(["--root", str(root)])
        return subprocess.run(
            arguments,
            cwd=REPO_ROOT,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
            timeout=30,
        )

    def run_companion_interrupt_fixture(
        self,
        checkout_root: Path,
        artifact_cache_root: Path,
    ) -> subprocess.CompletedProcess[str]:
        scripts_path = checkout_root / "scripts"
        scripts_path.mkdir(parents=True)
        bin_path = checkout_root / ".test-bin"
        bin_path.mkdir()
        marker = checkout_root / "xcodebuild-started"

        fake_xcodebuild = bin_path / "xcodebuild"
        fake_xcodebuild.write_text(
            """#!/bin/bash
derived_data=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-derivedDataPath" ]]; then
    derived_data="$2"
    shift 2
  else
    shift
  fi
done
mkdir -p "$derived_data/Build/Products/Release-iphoneos/Context Panel.app"
touch "$FAKE_XCODEBUILD_MARKER"
trap 'exit 143' TERM
sleep 30
"""
        )
        fake_xcodebuild.chmod(0o755)
        fake_xcodegen = bin_path / "xcodegen"
        fake_xcodegen.write_text("#!/bin/bash\nexit 0\n")
        fake_xcodegen.chmod(0o755)

        validator = self.read("scripts/validate-companion-builds.sh").replace(
            "/usr/bin/xcodebuild", f'"{fake_xcodebuild}"'
        )
        validator_path = scripts_path / "validate-companion-builds.sh"
        validator_path.write_text(validator)
        validator_path.chmod(0o755)
        helper_path = scripts_path / "context-panel-companion-cache.sh"
        helper_path.write_text(self.read("scripts/context-panel-companion-cache.sh"))
        helper_path.chmod(0o755)

        environment = os.environ.copy()
        environment["CONTEXT_PANEL_ARTIFACT_CACHE_ROOT"] = str(artifact_cache_root)
        environment["FAKE_XCODEBUILD_MARKER"] = str(marker)
        environment["PATH"] = f"{bin_path}:{environment.get('PATH', '')}"
        environment["RUNNER_TEMP"] = str(checkout_root / ".runner-temp")
        environment["TMPDIR"] = str(checkout_root / ".runner-temp")
        Path(environment["RUNNER_TEMP"]).mkdir()

        process = subprocess.Popen(
            ["/bin/bash", str(validator_path), "--configuration", "Release", "ios"],
            cwd=checkout_root,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        try:
            for _ in range(100):
                if marker.exists():
                    break
                if process.poll() is not None:
                    break
                time.sleep(0.05)
            self.assertTrue(marker.exists(), "fake xcodebuild did not start")
            process.terminate()
            stdout, _ = process.communicate(timeout=15)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)
            if process.stdout is not None and not process.stdout.closed:
                process.stdout.close()

        return subprocess.CompletedProcess(
            process.args,
            process.returncode,
            stdout=stdout,
            stderr=None,
        )

    def run_codeql_cache_fixture(
        self,
        checkout_root: Path,
        artifact_cache_root: Path,
        *,
        trusted_run: bool,
        include_standard_path: bool = True,
    ) -> subprocess.CompletedProcess[str]:
        workflow = self.read(".github/workflows/codeql.yml")
        build_step = re.search(
            r"      - name: Build\n.*?        run: \|\n(?P<body>.*?)(?=\n      - name:)",
            workflow,
            re.S,
        )
        self.assertIsNotNone(build_step)
        assert build_step is not None

        bin_path = checkout_root / ".test-bin"
        bin_path.mkdir(parents=True, exist_ok=True)
        fake_swift = bin_path / "swift"
        fake_swift.write_text('#!/bin/bash\nprintf \'swift %s\\n\' "$*"\n')
        fake_swift.chmod(0o755)

        path_entries = [str(bin_path)]
        if include_standard_path:
            path_entries.append(os.environ.get("PATH", ""))
        else:
            for command in ("dirname", "mkdir"):
                command_path = shutil.which(command)
                if command_path is None:
                    self.fail(f"required fixture command not found: {command}")
                fixture_command = bin_path / command
                if not fixture_command.exists():
                    fixture_command.symlink_to(command_path)

        environment = os.environ.copy()
        environment["CONTEXT_PANEL_ARTIFACT_CACHE_ROOT"] = str(artifact_cache_root)
        environment["TRUSTED_RUN"] = "true" if trusted_run else "false"
        environment["PATH"] = ":".join(path_entries)
        return subprocess.run(
            ["/bin/bash", "-c", textwrap.dedent(build_step.group("body"))],
            cwd=checkout_root,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )

    def run_companion_validation_watchdog_fixture(
        self, fake_xcodebuild_body: str
    ) -> tuple[subprocess.CompletedProcess[str], int, bool]:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)
            bin_path = temp_path / "bin"
            bin_path.mkdir()
            counter_path = temp_path / "xcodebuild-count"
            fake_xcodebuild = bin_path / "xcodebuild"
            fake_xcodebuild.write_text(fake_xcodebuild_body)
            fake_xcodebuild.chmod(0o755)
            fake_xcodegen = bin_path / "xcodegen"
            fake_xcodegen.write_text("#!/usr/bin/env bash\nexit 0\n")
            fake_xcodegen.chmod(0o755)

            scripts_path = temp_path / "scripts"
            scripts_path.mkdir()
            fixture_script = self.read("scripts/validate-companion-builds.sh")
            fixture_script = fixture_script.replace("5 * 60", "1")
            fixture_script = fixture_script.replace(
                "/usr/bin/xcodebuild", f'"{fake_xcodebuild}"'
            )
            fixture_path = scripts_path / "validate-companion-builds.sh"
            fixture_path.write_text(fixture_script)
            fixture_path.chmod(0o755)
            cache_helper = scripts_path / "context-panel-companion-cache.sh"
            cache_helper.write_text(self.read("scripts/context-panel-companion-cache.sh"))
            cache_helper.chmod(0o755)

            environment = os.environ.copy()
            environment["FAKE_XCODEBUILD_COUNTER"] = str(counter_path)
            environment["PATH"] = f"{bin_path}:{environment.get('PATH', '')}"
            environment["RUNNER_TEMP"] = str(temp_path)
            environment["TMPDIR"] = str(temp_path)

            sentinel = subprocess.Popen(["/bin/sleep", "30"])
            try:
                completed = subprocess.run(
                    ["/bin/bash", str(fixture_path), "--configuration", "Debug", "ios"],
                    cwd=temp_path,
                    env=environment,
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    check=False,
                    timeout=30,
                )
                invocation_count = int(counter_path.read_text()) if counter_path.exists() else 0
                sentinel_alive = sentinel.poll() is None
            finally:
                if sentinel.poll() is None:
                    sentinel.terminate()
                    sentinel.wait(timeout=5)

            return completed, invocation_count, sentinel_alive

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

    def run_widget_timeline_freshness_fixture(self, timeline_mtime: int, reference_mtime: int) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            timeline_dir = root / "timelines/ContextPanelWidget"
            timeline_dir.mkdir(parents=True)
            timeline = timeline_dir / "systemMedium344.00w-164.00h.timeline.chrono-timeline"
            reference = root / "ContextPanelBuildFingerprint.txt"
            timeline.write_text("timeline")
            reference.write_text("fingerprint")
            os.utime(timeline, (timeline_mtime, timeline_mtime))
            os.utime(reference, (reference_mtime, reference_mtime))
            command = f"""
            source scripts/context-panel-runtime-baseline.sh --source-only
            widget_timeline_cache_is_current_for_build "{root}" "{reference}"
            """
            return subprocess.run(
                ["bash", "-lc", command],
                cwd=REPO_ROOT,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                check=False,
            )

    def run_runtime_identity_fixture(
        self,
        app_entitlements: str | None,
        refresh_entitlements: str | None = None,
        *,
        receipt: bool = False,
        operation: str = "guard",
    ) -> subprocess.CompletedProcess[str]:
        fixture_dir = REPO_ROOT / "Tests/ScriptsTests/fixtures/runtime-preflight"
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            app_path = root / "Context Panel.app"
            refresh_path = app_path / "Contents/Library/LoginItems/ContextPanelRefreshAgent.app"
            if app_entitlements is not None:
                app_path.mkdir(parents=True)
            if refresh_entitlements is not None:
                refresh_path.mkdir(parents=True)
            if receipt:
                receipt_path = app_path / "Contents/_MASReceipt/receipt"
                receipt_path.parent.mkdir(parents=True, exist_ok=True)
                receipt_path.write_text("fixture")

            app_entitlements_path = fixture_dir / app_entitlements if app_entitlements is not None else None
            refresh_entitlements_path = (
                fixture_dir / refresh_entitlements if refresh_entitlements is not None else None
            )
            if operation == "guard":
                operation_body = 'guard_installed_runtime_replacement "$fixture_app" "$fixture_refresh"'
            elif operation == "production-check":
                operation_body = """
                require_production_runtime=1
                failures=0
                check_runtime_identity "$fixture_app" "$fixture_refresh"
                [[ "$failures" == "0" ]]
                """
            elif operation == "development-check":
                operation_body = """
                failures=0
                check_bundle_cloudkit_environment "$fixture_app" "built app" "Development" || true
                check_bundle_cloudkit_environment "$fixture_refresh" "built refresh agent" "Development" || true
                [[ "$failures" == "0" ]]
                """
            else:
                raise ValueError(f"unsupported runtime fixture operation: {operation}")

            command = f"""
            source {shlex.quote(str(REPO_ROOT / 'scripts/context-panel-runtime-baseline.sh'))} --source-only
            fixture_app={shlex.quote(str(app_path))}
            fixture_refresh={shlex.quote(str(refresh_path))}
            fixture_app_entitlements={shlex.quote(str(app_entitlements_path) if app_entitlements_path else '')}
            fixture_refresh_entitlements={shlex.quote(str(refresh_entitlements_path) if refresh_entitlements_path else '')}
            signed_entitlements_plist() {{
              if [[ -n "$fixture_app_entitlements" && "$1" == "$fixture_app" ]]; then
                cp "$fixture_app_entitlements" "$2"
                return 0
              fi
              if [[ -n "$fixture_refresh_entitlements" && "$1" == "$fixture_refresh" ]]; then
                cp "$fixture_refresh_entitlements" "$2"
                return 0
              fi
              return 1
            }}
            set +e
            {operation_body}
            status=$?
            exit "$status"
            """
            return subprocess.run(
                ["bash", "-lc", command],
                cwd=REPO_ROOT,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                check=False,
            )

    def run_package_script_preflight(
        self,
        args: list[str],
        profiles: dict[str, str] | None = None,
        identity_output: str | None = None,
        identity_status: int = 0,
    ) -> subprocess.CompletedProcess[str]:
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
            env["FAKE_SECURITY_IDENTITIES"] = identity_output if identity_output is not None else (
                f'  1) {FIXTURE_SIGNING_FINGERPRINT} "Apple Development: Test"\n'
                "     1 valid identities found"
            )
            env["FAKE_SECURITY_STATUS"] = str(identity_status)
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
  printf '%s\n' "${FAKE_SECURITY_IDENTITIES:-}"
  exit "${FAKE_SECURITY_STATUS:-0}"
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
        developer_certificate: bytes = FIXTURE_SIGNING_CERTIFICATE,
    ) -> str:
        team_id = "MM5YXC7T6E"
        certificate_data = base64.b64encode(developer_certificate).decode()
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
  <key>DeveloperCertificates</key>
  <array>
    <data>{certificate_data}</data>
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

    def widget_profile_plist(self, developer_certificate: bytes = FIXTURE_SIGNING_CERTIFICATE) -> str:
        team_id = "MM5YXC7T6E"
        bundle_id = "com.shinycomputers.contextpanel.widget"
        certificate_data = base64.b64encode(developer_certificate).decode()
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
  <key>DeveloperCertificates</key>
  <array>
    <data>{certificate_data}</data>
  </array>
  <key>Entitlements</key>
  <dict>
    <key>application-identifier</key>
    <string>{team_id}.{bundle_id}</string>
    <key>com.apple.application-identifier</key>
    <string>{team_id}.{bundle_id}</string>
    <key>com.apple.developer.team-identifier</key>
    <string>{team_id}</string>
    <key>com.apple.security.application-groups</key>
    <array>
      <string>{team_id}.group.com.shinycomputers.contextpanel</string>
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
        checked_in_schema: str | None = None,
    ) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            tool_dir = root / "tools"
            tool_dir.mkdir()
            live_schema_path = root / "live.ckdb"
            live_schema_path.write_text(live_schema)
            checked_in_schema_args: list[str] = []
            if checked_in_schema is not None:
                checked_in_schema_path = root / "checked-in.ckdb"
                checked_in_schema_path.write_text(checked_in_schema)
                checked_in_schema_args = ["--cktool-schema", str(checked_in_schema_path)]
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
                ]
                + checked_in_schema_args,
                cwd=REPO_ROOT,
                env=env,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                check=False,
            )

    def test_ship_forwards_resolved_build_number_to_github_release(self):
        workflow = self.read(".github/workflows/ship.yml")

        self.assertIn(
            "build_number: ${{ needs.validate.outputs.build_number }}",
            workflow_job(workflow, "github-release"),
        )

    def test_release_workflows_guard_secrets_with_protected_environment(self):
        workflows = {
            ".github/workflows/release.yml": "macos",
            ".github/workflows/ship.yml": "validate",
            ".github/workflows/app-store-connect-upload.yml": "upload",
            ".github/workflows/app-store-connect-companion-upload.yml": "upload",
            ".github/workflows/testflight-beta-distribution.yml": "distribute",
            ".github/workflows/submit-app-store-review.yml": "submit",
            ".github/workflows/upload-app-store-screenshots.yml": "upload",
        }

        for workflow_path, secret_job_name in workflows.items():
            with self.subTest(workflow=workflow_path):
                workflow = self.read(workflow_path)
                guard_job = workflow_job(workflow, "guard")
                secret_job = workflow_job(workflow, secret_job_name)
                self.assertIn("fetch-depth: 0", guard_job)
                self.assertIn("scripts/release-workflow-guard.sh", guard_job)
                self.assertEqual(workflow_job_needs(secret_job), ("guard",))
                self.assertIn("environment: release", secret_job)
                job_header = secret_job.split("\n    steps:", maxsplit=1)[0]
                self.assertNotIn("${{ secrets.", job_header)

    def test_release_workflow_only_runs_from_explicit_main_dispatches(self):
        workflow = self.read(".github/workflows/release.yml")

        self.assertNotIn("push:", workflow)
        self.assertIn("workflow_call:", workflow)
        self.assertIn("workflow_dispatch:", workflow)
        self.assertIn("contents: read", workflow_job(workflow, "guard"))
        self.assertIn("contents: write", workflow_job(workflow, "macos"))

    def test_release_workflow_shell_blocks_do_not_expand_actions_expressions(self):
        workflow_paths = (
            ".github/workflows/release.yml",
            ".github/workflows/ship.yml",
            ".github/workflows/app-store-connect-upload.yml",
            ".github/workflows/app-store-connect-companion-upload.yml",
            ".github/workflows/testflight-beta-distribution.yml",
            ".github/workflows/submit-app-store-review.yml",
            ".github/workflows/upload-app-store-screenshots.yml",
        )

        for workflow_path in workflow_paths:
            with self.subTest(workflow=workflow_path):
                for run_block in workflow_run_blocks(self.read(workflow_path)):
                    self.assertNotIn("${{", run_block)

    def test_release_workflow_guard_rejects_untrusted_inputs_and_refs(self):
        guard = REPO_ROOT / "scripts/release-workflow-guard.sh"
        base_environment = os.environ.copy()
        base_environment.update(
            {
                "GITHUB_REF": "refs/heads/main",
                "GITHUB_REF_TYPE": "branch",
                "GITHUB_REF_NAME": "main",
                "GITHUB_REF_PROTECTED": "true",
                "GITHUB_SHA": "unused-for-early-validation",
            }
        )

        hostile_version = subprocess.run(
            [str(guard), "--version", "1.2.3; echo injected"],
            cwd=REPO_ROOT,
            env=base_environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )
        self.assertEqual(hostile_version.returncode, 2)
        self.assertIn("release version must contain", hostile_version.stdout)

        untrusted_ref_environment = base_environment | {
            "GITHUB_REF": "refs/heads/feature",
            "GITHUB_REF_NAME": "feature",
        }
        untrusted_ref = subprocess.run(
            [str(guard), "--version", "1.2.3", "--build-number", "42"],
            cwd=REPO_ROOT,
            env=untrusted_ref_environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )
        self.assertEqual(untrusted_ref.returncode, 1)
        self.assertIn("must run from refs/heads/main", untrusted_ref.stdout)

        unprotected_environment = base_environment | {"GITHUB_REF_PROTECTED": "false"}
        unprotected_ref = subprocess.run(
            [str(guard), "--version", "1.2.3", "--build-number", "42"],
            cwd=REPO_ROOT,
            env=unprotected_environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )
        self.assertEqual(unprotected_ref.returncode, 1)
        self.assertIn("require a protected main branch", unprotected_ref.stdout)

    def test_release_workflow_guard_accepts_only_main_lineage(self):
        guard_source = self.read("scripts/release-workflow-guard.sh")
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            origin = root / "origin.git"
            checkout = root / "checkout"
            subprocess.run(["git", "init", "--bare", str(origin)], check=True)
            subprocess.run(["git", "clone", str(origin), str(checkout)], check=True)
            subprocess.run(
                ["git", "config", "user.email", "tests@context-panel.invalid"],
                cwd=checkout,
                check=True,
            )
            subprocess.run(
                ["git", "config", "user.name", "Context Panel Tests"],
                cwd=checkout,
                check=True,
            )
            (checkout / "README.md").write_text("trusted\n")
            subprocess.run(["git", "add", "README.md"], cwd=checkout, check=True)
            subprocess.run(["git", "commit", "-m", "trusted"], cwd=checkout, check=True)
            subprocess.run(["git", "branch", "-M", "main"], cwd=checkout, check=True)
            subprocess.run(["git", "push", "-u", "origin", "main"], cwd=checkout, check=True)
            trusted_sha = subprocess.run(
                ["git", "rev-parse", "HEAD"],
                cwd=checkout,
                check=True,
                text=True,
                stdout=subprocess.PIPE,
            ).stdout.strip()
            guard = checkout / "release-workflow-guard.sh"
            guard.write_text(guard_source)
            guard.chmod(0o755)
            environment = os.environ.copy()
            environment.update(
                {
                    "GITHUB_REF": "refs/heads/main",
                    "GITHUB_REF_TYPE": "branch",
                    "GITHUB_REF_NAME": "main",
                    "GITHUB_REF_PROTECTED": "true",
                    "GITHUB_SHA": trusted_sha,
                }
            )

            trusted = subprocess.run(
                [str(guard), "--version", "1.2.3", "--build-number", "42"],
                cwd=checkout,
                env=environment,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                check=False,
            )
            self.assertEqual(trusted.returncode, 0, trusted.stdout)

            optional_inputs = subprocess.run(
                [str(guard), "--version", "", "--build-number", ""],
                cwd=checkout,
                env=environment,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                check=False,
            )
            self.assertEqual(optional_inputs.returncode, 0, optional_inputs.stdout)

            subprocess.run(["git", "switch", "-c", "untrusted"], cwd=checkout, check=True)
            (checkout / "README.md").write_text("untrusted\n")
            subprocess.run(["git", "commit", "-am", "untrusted"], cwd=checkout, check=True)
            untrusted_sha = subprocess.run(
                ["git", "rev-parse", "HEAD"],
                cwd=checkout,
                check=True,
                text=True,
                stdout=subprocess.PIPE,
            ).stdout.strip()
            environment["GITHUB_SHA"] = untrusted_sha
            untrusted = subprocess.run(
                [str(guard), "--version", "1.2.3", "--build-number", "42"],
                cwd=checkout,
                env=environment,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                check=False,
            )
            self.assertEqual(untrusted.returncode, 1)
            self.assertIn("outside origin/main", untrusted.stdout)

    def test_ship_release_channels_depend_on_validation(self):
        workflow = self.read(".github/workflows/ship.yml")

        expected_needs = {
            "github-release": ("validate",),
            "app-store-upload": ("validate",),
            "companion-app-store-upload": ("validate",),
            "testflight-beta": (
                "validate",
                "app-store-upload",
                "companion-app-store-upload",
            ),
        }
        for job_name, needs in expected_needs.items():
            with self.subTest(job=job_name):
                self.assertEqual(workflow_job_needs(workflow_job(workflow, job_name)), needs)

    def test_ship_validation_step_owns_app_store_preflight(self):
        workflow = self.read(".github/workflows/ship.yml")
        validate_job = workflow_job(workflow, "validate")
        validate_run = workflow_step_run(workflow, "validate", "Validate Inputs")

        self.assertEqual(validate_run.count("scripts/app-store-version-guard.py"), 1)
        self.assertEqual(workflow.count("scripts/app-store-version-guard.py"), 1)
        for credential in (
            "APP_STORE_CONNECT_KEY_ID",
            "APP_STORE_CONNECT_ISSUER_ID",
            "APP_STORE_CONNECT_API_KEY_P8_BASE64",
        ):
            with self.subTest(credential=credential):
                self.assertIn(credential, validate_job)
        self.assertIn(
            "App Store Connect API credentials are required for Ship App Store version preflight",
            validate_run,
        )
        for validation_message in (
            "testflight_beta_source=macos requires app_store_channel=upload",
            "testflight_beta_source=companion requires companion_app_store_channel=upload",
            "companion_app_store_channel=upload with testflight_beta=true requires testflight_beta_source=companion",
        ):
            with self.subTest(validation_message=validation_message):
                self.assertIn(validation_message, validate_run)

    def test_ship_preflight_platform_mapping_is_exhaustive(self):
        workflow = self.read(".github/workflows/ship.yml")
        validate_run = workflow_step_run(workflow, "validate", "Validate Inputs")
        companion_case_match = re.search(
            r'case\s+"\$\{INPUT_COMPANION_PLATFORM\}"\s+in(?P<body>.*?)\besac\b',
            validate_run,
            re.DOTALL,
        )
        self.assertIsNotNone(companion_case_match)
        companion_case = companion_case_match.group("body")

        self.assertRegex(
            re.sub(r"\s+", " ", validate_run),
            r'if \[\[ "\$\{app_store_channel\}" == "upload" \]\]; then '
            r'preflight_app_store_version MAC_OS fi',
        )
        self.assertRegex(
            re.sub(r"\s+", " ", validate_run),
            r'if \[\[ "\$\{companion_app_store_channel\}" == "upload" \]\]; then '
            r'case "\$\{INPUT_COMPANION_PLATFORM\}" in',
        )
        mappings = dict(
            re.findall(
                r"^\s*(ios|visionos|tvos)\)\s*$\n\s*preflight_app_store_version ([A-Z_]+)\s*$",
                companion_case,
                re.MULTILINE,
            )
        )
        self.assertEqual(
            mappings,
            {"ios": "IOS", "visionos": "VISION_OS", "tvos": "TV_OS"},
        )
        self.assertEqual(set(mappings), set(workflow_choice_options(workflow, "companion_platform")))
        self.assertRegex(
            companion_case,
            r"(?ms)^\s*\*\)\s*$.*unsupported companion_platform.*?^\s*exit 2\s*$",
        )

    def test_ship_distributes_testflight_beta_without_app_review(self):
        workflow = self.read(".github/workflows/ship.yml")
        testflight_job = workflow_job(workflow, "testflight-beta")

        self.assertIn("uses: ./.github/workflows/testflight-beta-distribution.yml", testflight_job)
        for contract in (
            "build_number:",
            "needs.app-store-upload.outputs.build_number",
            "needs.companion-app-store-upload.outputs.build_number",
            "platform:",
            "needs.companion-app-store-upload.outputs.app_store_platform",
            "'MAC_OS'",
            "beta_groups:",
            "include_internal_beta_groups:",
        ):
            with self.subTest(contract=contract):
                self.assertIn(contract, testflight_job)
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
        self.assertIn("COMPANION_APP_STORE_TV_PROVISIONING_PROFILE_BASE64", workflow)
        self.assertIn("COMPANION_APP_STORE_TV_TOP_SHELF_PROVISIONING_PROFILE_BASE64", workflow)
        self.assertIn("ContextPanelCompanion", script)
        self.assertIn("ContextPanelTV", script)
        self.assertIn("generic/platform=iOS", script)
        self.assertIn("generic/platform=visionOS", script)
        self.assertIn("generic/platform=tvOS", script)
        self.assertIn("CONTEXT_PANEL_APP_STORE_COMPANION_PROFILE_SPECIFIER", script)
        self.assertIn("CONTEXT_PANEL_APP_STORE_TV_PROFILE_SPECIFIER", script)
        self.assertIn("CONTEXT_PANEL_APP_STORE_TV_TOP_SHELF_PROFILE_SPECIFIER", script)
        self.assertIn("--tv-top-shelf-profile", script)
        self.assertIn("com.shinycomputers.contextpanel.topshelf", script)
        self.assertIn("iCloud.com.shinycomputers.contextpanel", script)
        self.assertIn("group.com.shinycomputers.contextpanel", script)
        self.assertIn("'Entitlements:com.apple.developer.icloud-services' '*'", script)

    def test_app_store_upload_name_does_not_claim_testflight_distribution(self):
        workflow = self.read(".github/workflows/app-store-connect-upload.yml")

        self.assertIn("name: App Store Connect Build Upload", workflow)
        self.assertIn("TestFlight beta distribution: handled by the TestFlight Beta Distribution workflow", workflow)
        self.assertNotIn("TestFlight beta distribution: not requested by this workflow", workflow)

    def test_app_store_upload_artifacts_retain_expected_build_manifests(self):
        mac_workflow = self.read(".github/workflows/app-store-connect-upload.yml")
        companion_workflow = self.read(".github/workflows/app-store-connect-companion-upload.yml")

        self.assertIn(
            ".build/app-store-connect/ExpectedBuildManifest-*.json",
            mac_workflow,
        )
        self.assertIn(
            ".build/app-store-connect-companion/ExpectedBuildManifest-*.json",
            companion_workflow,
        )

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
        self.assertIn("- TV_OS", workflow)
        self.assertIn("/betaGroups/{group_id}/relationships/builds", script)
        self.assertIn("processingState", script)

    def test_app_store_screenshot_upload_workflow_uses_safe_defaults(self):
        workflow = self.read(".github/workflows/upload-app-store-screenshots.yml")

        self.assertIn("name: Upload App Store Screenshots", workflow)
        self.assertIn("default: true", workflow)
        self.assertIn("scripts/upload-app-store-screenshots.py", workflow)
        self.assertIn("--dry-run", workflow)
        self.assertIn("APP_STORE_CONNECT_API_KEY_P8_BASE64", workflow)
        self.assertIn("default: \"\"", workflow)
        self.assertIn("type: string", workflow)
        self.assertNotIn("- MAC_OS", workflow)

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

    def test_app_store_review_workflow_gates_live_build_mutations_on_runtime_evidence(self):
        workflow = self.read(".github/workflows/submit-app-store-review.yml")
        script = self.read("scripts/submit-app-store-review.py")
        release_docs = self.read("docs/release.md")

        self.assertIn("validation_report_base64:", workflow)
        self.assertIn("Prepare Validation Report", workflow)
        self.assertIn("args+=(--validation-report .build/validation-report.json)", workflow)
        self.assertIn("report_required=\"false\"", workflow)
        self.assertIn("INPUT_DRY_RUN", workflow)
        self.assertIn("INPUT_CANCEL_REVIEW_ONLY", workflow)
        self.assertIn("INPUT_PREPARE_ONLY", workflow)
        self.assertIn("--validation-report", script)
        self.assertIn("--validate-report-only", script)
        self.assertIn("validation_report_required", script)
        self.assertIn("release_evidence_report_base64:", workflow)
        self.assertIn("release_evidence_mode:", workflow)
        self.assertIn("Prepare Release Evidence Report", workflow)
        self.assertIn("--release-evidence-report", script)
        self.assertIn("--release-evidence-mode", script)
        self.assertIn("--release-evidence-surface-policy", script)
        self.assertIn(
            "release_evidence_report_base64 is required for live shadow or enforce validation",
            workflow,
        )
        self.assertIn("release_evidence_comparison_base64:", workflow)
        self.assertIn("release_evidence_expected_build_manifests_base64:", workflow)
        self.assertIn("release_evidence_selected_rc_ledger_base64:", workflow)
        self.assertIn("release_evidence_shadow_evidence_base64:", workflow)
        self.assertIn("release_evidence_mode must be shadow or enforce", workflow)
        self.assertEqual(
            len(
                re.findall(
                    r"release_evidence_mode:\n"
                    r"(?:\s+.*\n){0,4}?"
                    r"\s+default: enforce\n",
                    workflow,
                )
            ),
            2,
        )
        github_config = json.loads(self.read(".github/github.json"))
        self.assertEqual(
            github_config["qualityGate"]["validate"][
                "appStoreReviewReleaseEvidenceDefault"
            ],
            "enforce",
        )
        validation_preflight = github_config["qualityGate"]["validate"][
            "appStoreReviewValidationPreflight"
        ]
        for argument in (
            "--validation-train release",
            "--release-evidence-report",
            "--release-evidence-mode enforce",
            "--release-evidence-comparison",
            "--release-evidence-expected-build-manifest",
            "--release-evidence-selected-rc-ledger",
            "--release-evidence-shadow-evidence",
        ):
            self.assertIn(argument, validation_preflight)
        self.assertIn("--release-evidence-mode enforce", release_docs)
        self.assertIn(
            "live build attachment or submission requires validation_train release",
            workflow,
        )
        self.assertIn(
            "live build attachment or submission requires --validation-train release",
            script,
        )
        self.assertIn("submission validation reconstructs every approved embedded ledger", release_docs.lower())
        self.assertIn("narrow exact-build runtime stop", release_docs)
        self.assertIn("iPhone app/widget, iPad app/widget", release_docs)

    def test_app_store_review_workflow_forwards_validation_for_supplied_evidence(self):
        workflow = self.read(".github/workflows/submit-app-store-review.yml")
        submit_step = re.search(
            r"      - name: Submit Review\n.*?        run: \|\n(?P<body>.*?)(?=\n      - name:|\Z)",
            workflow,
            re.S,
        )
        self.assertIsNotNone(submit_step)
        assert submit_step is not None
        script = textwrap.dedent(submit_step.group("body"))

        matrix = (
            ("dry-run", True, False, False, "202608080418", ""),
            ("prepare-only", False, False, True, "", ""),
            ("cancel-only", False, True, False, "", "1.0.53"),
            ("live", False, False, False, "202608080418", ""),
        )
        for label, dry_run, cancel_only, prepare_only, build_number, removal in matrix:
            with self.subTest(mode=label), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                python_path = root / ".build/submit-review-venv/bin/python"
                python_path.parent.mkdir(parents=True)
                python_path.write_text(
                    "#!/bin/bash\nprintf '%s\\n' \"$@\" > \"$CAPTURE_ARGS\"\n"
                )
                python_path.chmod(0o755)
                for relative_path in (
                    ".build/validation-report.json",
                    ".build/release-evidence-report.json",
                    ".build/release-evidence-comparison.json",
                    ".build/release-evidence-selected-rc-ledger.json",
                    ".build/release-evidence-shadow.json",
                ):
                    path = root / relative_path
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text("{}\n")
                manifest = (
                    root
                    / ".build/release-evidence-expected-build-manifests/000.json"
                )
                manifest.parent.mkdir(parents=True)
                manifest.write_text("{}\n")
                capture_path = root / "args.txt"
                summary_path = root / "summary.md"
                environment = os.environ.copy()
                environment.update(
                    {
                        "CAPTURE_ARGS": str(capture_path),
                        "GITHUB_SHA": "d966d826257a0ee23a09c55bd6b073360edf36aa",
                        "GITHUB_STEP_SUMMARY": str(summary_path),
                        "INPUT_VERSION": "1.0.54",
                        "INPUT_PLATFORM": "MAC_OS",
                        "INPUT_BUILD_NUMBER": build_number,
                        "INPUT_WHATS_NEW": "Release evidence preflight",
                        "INPUT_REVIEW_NOTES": "",
                        "INPUT_TVOS_DEMO_VIDEO_URL": "",
                        "INPUT_COPY_FROM_VERSION": "",
                        "INPUT_COPY_FROM_PLATFORM": "",
                        "INPUT_REMOVE_ACTIVE_REVIEW_VERSION": removal,
                        "INPUT_DRY_RUN": str(dry_run).lower(),
                        "INPUT_CANCEL_REVIEW_ONLY": str(cancel_only).lower(),
                        "INPUT_PREPARE_ONLY": str(prepare_only).lower(),
                        "INPUT_VALIDATION_REPORT_BASE64": "present",
                        "INPUT_VALIDATION_TRAIN": "release",
                        "INPUT_RELEASE_EVIDENCE_MODE": "shadow",
                        "INPUT_RELEASE_EVIDENCE_REPORT_BASE64": "present",
                        "INPUT_RELEASE_EVIDENCE_COMPARISON_BASE64": "present",
                        "INPUT_RELEASE_EVIDENCE_EXPECTED_BUILD_MANIFESTS_BASE64": "present",
                        "INPUT_RELEASE_EVIDENCE_PREVIOUS_LEDGER_BASE64": "",
                        "INPUT_RELEASE_EVIDENCE_SELECTED_RC_LEDGER_BASE64": "present",
                        "INPUT_RELEASE_EVIDENCE_HOST_OS_EVIDENCE_BASE64": "",
                        "INPUT_RELEASE_EVIDENCE_SHADOW_EVIDENCE_BASE64": "present",
                    }
                )
                result = subprocess.run(
                    ["/bin/bash", "-c", script],
                    cwd=root,
                    env=environment,
                    text=True,
                    capture_output=True,
                    check=False,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                arguments = capture_path.read_text().splitlines()
                self.assertIn("--validation-report", arguments)
                self.assertIn("--release-evidence-report", arguments)

    def test_release_evidence_entrypoints_execute_directly(self):
        for relative_path in (
            "scripts/context-panel-release-gate.py",
            "scripts/validate-release-evidence-report.py",
        ):
            with self.subTest(script=relative_path):
                path = REPO_ROOT / relative_path
                self.assertTrue(path.stat().st_mode & 0o100)
                result = subprocess.run(
                    [str(path), "--help"],
                    cwd=REPO_ROOT,
                    text=True,
                    capture_output=True,
                    check=False,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("usage:", result.stdout)

    def test_release_evidence_metadata_commands_include_required_contract(self):
        metadata = json.loads(self.read(".github/github.json"))
        validate = metadata["qualityGate"]["validate"]
        report_tokens = shlex.split(validate["releaseEvidenceBetaRCReportValidation"])
        release_shadow_tokens = shlex.split(
            validate["releaseEvidenceReleaseShadowReportValidation"]
        )
        enforced_tokens = shlex.split(
            validate["releaseEvidenceEnforcedReportValidation"]
        )
        for required_option in (
            "--report",
            "--validation-report",
            "--comparison",
            "--expected-build-manifest",
            "--policy",
            "--surface-policy",
            "--version",
            "--build-number",
            "--train",
        ):
            self.assertIn(required_option, report_tokens)
            self.assertIn(required_option, enforced_tokens)
        self.assertNotIn("--enforce", report_tokens)
        self.assertNotIn("--enforce", release_shadow_tokens)
        self.assertIn("--enforce", enforced_tokens)
        self.assertNotIn("releaseEvidenceReportValidation", validate)
        self.assertIn("<beta|rc>", report_tokens)
        self.assertNotIn("<beta|rc|release>", report_tokens)
        self.assertIn(
            "--selected-rc-ledger",
            shlex.split(validate["releaseEvidenceReleaseEnforcementGate"]),
        )
        self.assertIn(
            "--selected-rc-ledger",
            shlex.split(validate["releaseEvidenceReleaseShadowGate"]),
        )
        self.assertIn(
            "--selected-rc-ledger",
            shlex.split(validate["releaseEvidenceReleaseReportValidation"]),
        )
        self.assertIn("--selected-rc-ledger", release_shadow_tokens)
        self.assertIn(
            "--shadow-evidence",
            shlex.split(validate["releaseEvidenceEnforcedReportValidation"]),
        )
        for command_name in (
            "releaseEvidenceBetaShadowGate",
            "releaseEvidenceRCShadowGate",
            "releaseEvidenceReleaseShadowGate",
            "releaseEvidenceBetaEnforcementGate",
            "releaseEvidenceRCEnforcementGate",
            "releaseEvidenceReleaseEnforcementGate",
        ):
            self.assertIn("--lineage-output", shlex.split(validate[command_name]))

    def test_app_store_review_workflow_supports_review_notes_override(self):
        workflow = self.read(".github/workflows/submit-app-store-review.yml")
        script = self.read("scripts/submit-app-store-review.py")

        self.assertIn("review_notes:", workflow)
        self.assertIn("INPUT_REVIEW_NOTES", workflow)
        self.assertIn('args+=(--review-notes "${INPUT_REVIEW_NOTES}")', workflow)
        self.assertIn("--review-notes", script)
        self.assertIn('review_attributes["notes"] = review_notes', script)

    def test_app_store_review_workflow_uses_single_version_submissions(self):
        workflow = self.read(".github/workflows/submit-app-store-review.yml")
        script = self.read("scripts/submit-app-store-review.py")
        release_docs = self.read("docs/release.md")

        self.assertNotIn("additional_review_versions:", workflow)
        self.assertNotIn("--additional-review-version", script)
        self.assertIn('f"/reviewSubmissions/{submission_id}/items"', script)
        self.assertIn("exactly one App Store version item per review", release_docs)
        self.assertIn("separately for each platform and", release_docs)

    def test_app_store_review_workflow_supports_tvos(self):
        workflow = self.read(".github/workflows/submit-app-store-review.yml")
        script = self.read("scripts/submit-app-store-review.py")
        release_docs = self.read("docs/release.md")

        self.assertIn("- TV_OS", workflow)
        self.assertIn("tvos_demo_video_url:", workflow)
        self.assertIn("INPUT_TVOS_DEMO_VIDEO_URL", workflow)
        self.assertIn('args+=(--tvos-demo-video-url "${INPUT_TVOS_DEMO_VIDEO_URL}")', workflow)
        self.assertIn("TVOS_DEMO_NOTES_HEADING", script)
        self.assertIn("--tvos-demo-video-url", script)
        self.assertIn("optional for ordinary `TV_OS` updates", release_docs)
        self.assertIn("clears copied prior-version review notes", release_docs)
        self.assertIn("`tvos_demo_video_url`", release_docs)
        self.assertIn("copy_from_platform:", workflow)
        self.assertIn("INPUT_COPY_FROM_PLATFORM", workflow)
        self.assertIn('args+=(--copy-from-platform "${INPUT_COPY_FROM_PLATFORM}")', workflow)
        self.assertIn("--copy-from-platform", script)

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
        self.assertIn('--build-number "${BUILD_NUMBER}"', workflow)
        self.assertIn('MARKETING_VERSION="$version"', package_script)
        self.assertIn('CURRENT_PROJECT_VERSION="$build_number"', package_script)

    def test_release_workflow_pins_the_identity_imported_from_the_p12(self):
        workflow = self.read(".github/workflows/release.yml")

        self.assertIn('identity_output="$(security find-identity -v -p codesigning "${keychain_path}")"', workflow)
        self.assertIn('identity="${identities[0]}"', workflow)
        self.assertIn("expected exactly one Developer ID Application identity", workflow)
        self.assertIn("requires app, widget, and refresh-agent provisioning profiles", workflow)
        self.assertNotIn('identity="auto"', workflow)

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

    def test_release_and_runtime_gates_reject_profile_certificate_mismatches(self):
        package_script = self.read("scripts/package-native-macos-app.sh")
        runtime_script = self.read("scripts/context-panel-runtime-baseline.sh")

        self.assertIn("assert_profile_matches_signing_certificate()", package_script)
        self.assertIn("assert_profile_authorizes_signing_identity()", package_script)
        self.assertIn("DeveloperCertificates.$index", package_script)
        self.assertIn("does not authorize the actual signing certificate", package_script)
        preflight = (
            'assert_profile_authorizes_signing_identity "$widget_provisioning_profile" "Context Panel widget"'
        )
        self.assertIn(preflight, package_script)
        self.assertLess(package_script.index(preflight), package_script.index("xcodegen generate --spec project.yml"))
        self.assertIn(
            'assert_profile_matches_signing_certificate "$widget_path" "$widget_provisioning_profile" "Context Panel widget"',
            package_script,
        )
        self.assertIn("DeveloperCertificates.$index", runtime_script)
        self.assertIn("does not authorize the actual signing certificate", runtime_script)

    def test_runtime_gate_accepts_widget_timeline_from_installed_build(self):
        result = self.run_widget_timeline_freshness_fixture(timeline_mtime=200, reference_mtime=100)

        self.assertEqual(result.returncode, 0, result.stdout)

    def test_runtime_gate_rejects_widget_timeline_from_previous_build(self):
        result = self.run_widget_timeline_freshness_fixture(timeline_mtime=100, reference_mtime=200)

        self.assertNotEqual(result.returncode, 0, result.stdout)

    def test_runtime_gate_rejects_widget_timeline_without_build_reference(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            timeline_dir = root / "timelines/ContextPanelWidget"
            timeline_dir.mkdir(parents=True)
            (timeline_dir / "systemMedium344.00w-164.00h.timeline.chrono-timeline").write_text("timeline")
            command = f"""
            source scripts/context-panel-runtime-baseline.sh --source-only
            widget_timeline_cache_is_current_for_build "{root}" "{root / 'missing-fingerprint.txt'}"
            """
            result = subprocess.run(
                ["bash", "-lc", command],
                cwd=REPO_ROOT,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                check=False,
            )

        self.assertNotEqual(result.returncode, 0, result.stdout)

    def test_release_package_rejects_cloudkit_without_profiles_before_building(self):
        result = self.run_package_script_preflight([
            "--identity",
            "Apple Development: Test",
        ])

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Context Panel app uses CloudKit entitlements and requires an embedded provisioning profile", result.stdout)
        self.assertNotIn("unexpected fake xcodegen invocation", result.stdout)

    def test_release_package_rejects_ambiguous_auto_identity_before_building(self):
        second_fingerprint = hashlib.sha1(b"second-signing-certificate").hexdigest().upper()
        identities = (
            f'  1) {FIXTURE_SIGNING_FINGERPRINT} "Developer ID Application: Test (MM5YXC7T6E)"\n'
            f'  2) {second_fingerprint} "Developer ID Application: Test (MM5YXC7T6E)"\n'
            "     2 valid identities found"
        )

        result = self.run_package_script_preflight(["--identity", "auto"], identity_output=identities)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("multiple valid Developer ID Application signing certificates are available", result.stdout)
        self.assertNotIn("unexpected fake xcodegen invocation", result.stdout)

    def test_release_package_rejects_identity_lookup_failure_before_building(self):
        identities = f'  1) {FIXTURE_SIGNING_FINGERPRINT} "Developer ID Application: Test (MM5YXC7T6E)"'

        result = self.run_package_script_preflight(
            ["--identity", "auto"],
            identity_output=identities,
            identity_status=77,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("could not list valid codesigning identities", result.stdout)
        self.assertNotIn("unexpected fake xcodegen invocation", result.stdout)

    def test_release_package_requires_widget_profile_for_signed_builds(self):
        result = self.run_package_script_preflight(
            [
                "--identity",
                FIXTURE_SIGNING_FINGERPRINT,
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
        self.assertIn("Context Panel widget requires an embedded provisioning profile", result.stdout)
        self.assertNotIn("unexpected fake xcodegen invocation", result.stdout)

    def test_release_package_rejects_each_profile_for_a_different_signing_certificate(self):
        mismatch_cases = (
            ("app.plist", "Context Panel app"),
            ("widget.plist", "Context Panel widget"),
            ("refresh.plist", "Context Panel refresh agent"),
        )
        for mismatched_profile, label in mismatch_cases:
            with self.subTest(profile=mismatched_profile):
                profiles = {
                    "app.plist": self.cloudkit_profile_plist("com.shinycomputers.contextpanel"),
                    "widget.plist": self.widget_profile_plist(),
                    "refresh.plist": self.cloudkit_profile_plist("com.shinycomputers.contextpanel.refresh-agent"),
                }
                if mismatched_profile == "app.plist":
                    profiles[mismatched_profile] = self.cloudkit_profile_plist(
                        "com.shinycomputers.contextpanel",
                        developer_certificate=b"different-signing-certificate",
                    )
                elif mismatched_profile == "widget.plist":
                    profiles[mismatched_profile] = self.widget_profile_plist(b"different-signing-certificate")
                else:
                    profiles[mismatched_profile] = self.cloudkit_profile_plist(
                        "com.shinycomputers.contextpanel.refresh-agent",
                        developer_certificate=b"different-signing-certificate",
                    )

                result = self.run_package_script_preflight(
                    [
                        "--identity",
                        FIXTURE_SIGNING_FINGERPRINT,
                        "--app-provisioning-profile",
                        "app.plist",
                        "--widget-provisioning-profile",
                        "widget.plist",
                        "--refresh-agent-provisioning-profile",
                        "refresh.plist",
                    ],
                    profiles=profiles,
                )

                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f"{label} provisioning profile does not authorize signing certificate", result.stdout)
                self.assertNotIn("unexpected fake xcodegen invocation", result.stdout)

    def test_release_package_accepts_one_matching_certificate_profile_set(self):
        result = self.run_package_script_preflight(
            [
                "--identity",
                FIXTURE_SIGNING_FINGERPRINT,
                "--app-provisioning-profile",
                "app.plist",
                "--widget-provisioning-profile",
                "widget.plist",
                "--refresh-agent-provisioning-profile",
                "refresh.plist",
            ],
            profiles={
                "app.plist": self.cloudkit_profile_plist("com.shinycomputers.contextpanel"),
                "widget.plist": self.widget_profile_plist(),
                "refresh.plist": self.cloudkit_profile_plist("com.shinycomputers.contextpanel.refresh-agent"),
            },
        )

        self.assertEqual(result.returncode, 42)
        self.assertIn("unexpected fake xcodegen invocation", result.stdout)
        self.assertNotIn("does not authorize signing certificate", result.stdout)

    def test_release_package_allows_ad_hoc_validation_without_cloudkit_profiles(self):
        result = self.run_package_script_preflight([
            "--identity",
            "-",
        ], identity_status=77)

        self.assertEqual(result.returncode, 42)
        self.assertIn("unexpected fake xcodegen invocation", result.stdout)
        self.assertNotIn("uses CloudKit entitlements and requires an embedded provisioning profile", result.stdout)

    def test_release_package_rejects_ad_hoc_widget_profile_before_building(self):
        result = self.run_package_script_preflight(
            [
                "--identity",
                "-",
                "--widget-provisioning-profile",
                "widget.plist",
            ],
            profiles={"widget.plist": self.widget_profile_plist()},
            identity_status=77,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("provisioning profiles requires a non-ad-hoc signing identity", result.stdout)
        self.assertNotIn("unexpected fake xcodegen invocation", result.stdout)

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
        runtime_sync = self.read("Sources/ContextPanelCore/RuntimeReceiptRemoteSync.swift")

        self.assertEqual(schema["containerIdentifier"], "iCloud.com.shinycomputers.contextpanel")
        self.assertEqual(schema["database"], "private")
        record_types = {record["name"]: record for record in schema["recordTypes"]}
        record = record_types["CompanionSyncDocument"]
        self.assertEqual(record["recordName"], "current-v2")
        self.assertIn('cloudKitRecordName = "current-v2"', remote_sync)
        self.assertIn('cloudKitSubscriptionRecordName = "current"', remote_sync)
        self.assertIn("cloudKitLegacyRecordNames = [cloudKitSubscriptionRecordName]", remote_sync)
        self.assertIn('cloudKitSubscriptionID = "companion-sync-updates"', remote_sync)
        self.assertIn("cloudKitRetiredSubscriptionIDs: [String] = []", remote_sync)
        field_definitions = {field["name"]: field for field in record["fields"]}
        fields = {name: field["type"] for name, field in field_definitions.items()}
        self.assertEqual(fields["payload"], "BYTES")
        self.assertEqual(fields["schemaVersion"], "INT64")
        self.assertEqual(fields["documentSchemaVersion"], "INT64")
        self.assertEqual(fields["snapshotSchemaVersion"], "INT64")
        self.assertEqual(fields["generatedAt"], "TIMESTAMP")
        self.assertEqual(fields["publishedAt"], "TIMESTAMP")
        self.assertEqual(fields["payloadByteCount"], "INT64")
        self.assertTrue(field_definitions["snapshotSchemaVersion"]["queryable"])
        for field_name in fields:
            self.assertIn(f'= "{field_name}"', remote_sync)

        session_record = record_types["RuntimeValidationSession"]
        self.assertEqual(
            session_record["recordName"],
            "runtime-validation-session-current-v1",
        )
        session_fields = {field["name"]: field["type"] for field in session_record["fields"]}
        self.assertEqual(session_record["publicDatabaseGrants"], [])
        self.assertEqual(session_fields["retentionExpiresAt"], "TIMESTAMP")
        self.assertEqual(session_fields["sessionState"], "STRING")
        self.assertEqual(session_fields["stateUpdatedAt"], "TIMESTAMP")
        receipt_record = record_types["RuntimeReceipt"]
        self.assertEqual(
            receipt_record["recordNamePattern"],
            "runtime-receipt-<sha256>",
        )
        receipt_fields = {field["name"]: field for field in receipt_record["fields"]}
        self.assertEqual(receipt_record["publicDatabaseGrants"], [])
        self.assertTrue(receipt_fields["sessionID"]["queryable"])
        self.assertTrue(receipt_fields["retentionExpiresAt"]["queryable"])
        self.assertTrue(receipt_fields["retentionExpiresAt"]["sortable"])
        self.assertIn('cloudKitSessionRecordType = "RuntimeValidationSession"', runtime_sync)
        self.assertIn('cloudKitReceiptRecordType = "RuntimeReceipt"', runtime_sync)
        for record in (session_record, receipt_record):
            for field in record["fields"]:
                self.assertIn(f'= "{field["name"]}"', runtime_sync)

    def test_cloudkit_companion_schema_validator_documents_live_cktool_gate(self):
        script = self.read("scripts/validate-cloudkit-companion-schema.sh")
        release_docs = self.read("docs/release.md")

        self.assertIn("cktool export-schema", script)
        self.assertIn("CLOUDKIT_MANAGEMENT_TOKEN", script)
        self.assertIn("live_schema_has_field_type", script)
        self.assertIn("live_schema_field_is_queryable", script)
        self.assertIn("live_schema_field_is_sortable", script)
        self.assertIn("live_schema_record_has_grant", script)
        self.assertIn("CloudKit/companion-sync.schema.ckdb", script)
        self.assertIn("CompanionSyncDocument", script)
        self.assertIn("RuntimeValidationSession", script)
        self.assertIn("RuntimeReceipt", script)
        self.assertIn("iCloud.com.shinycomputers.contextpanel", script)
        self.assertIn("CloudKit Production Schema Gate", release_docs)
        self.assertIn("scripts/validate-cloudkit-companion-schema.sh --live --environment production", release_docs)
        self.assertIn("CloudKit Console's **Deploy Schema Changes** action", release_docs)
        self.assertIn("never use `cktool reset-schema`", release_docs)
        self.assertIn("CompanionSyncDocumentV2", release_docs)

    def test_cloudkit_companion_schema_validator_accepts_ckdb_export(self):
        result = self.run_cloudkit_schema_validator_with_fake_cktool(
            self.read("CloudKit/companion-sync.schema.ckdb")
        )

        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("runtime receipt contracts", result.stdout)

    def test_cloudkit_companion_schema_validator_forwards_management_token(self):
        result = self.run_cloudkit_schema_validator_with_fake_cktool(
            self.read("CloudKit/companion-sync.schema.ckdb"),
            management_token="test-management-token",
            require_token=True,
        )

        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertNotIn("test-management-token", result.stdout)

    def test_cloudkit_schema_validator_rejects_non_sortable_retention_field(self):
        live_schema = self.read("CloudKit/companion-sync.schema.ckdb").replace(
            "retentionExpiresAt   TIMESTAMP QUERYABLE SORTABLE",
            "retentionExpiresAt   TIMESTAMP QUERYABLE",
        )

        result = self.run_cloudkit_schema_validator_with_fake_cktool(live_schema)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("RuntimeReceipt.retentionExpiresAt", result.stdout)
        self.assertIn("not sortable", result.stdout)

    def test_cloudkit_schema_validator_rejects_runtime_public_grant(self):
        live_schema = self.read("CloudKit/companion-sync.schema.ckdb").replace(
            "        surface              STRING\n    );",
            '        surface              STRING,\n        GRANT READ TO "_world"\n    );',
        )

        result = self.run_cloudkit_schema_validator_with_fake_cktool(live_schema)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must not grant public database access", result.stdout)
        self.assertIn("RuntimeReceipt", result.stdout)

    def test_cloudkit_schema_validator_rejects_changed_users_grants(self):
        checked_in_schema = self.read("CloudKit/companion-sync.schema.ckdb").replace(
            '        GRANT WRITE TO "_creator",\n        GRANT READ TO "_world"\n    );',
            '        GRANT WRITE TO "_creator"\n    );',
        )

        result = self.run_cloudkit_schema_validator_with_fake_cktool(
            self.read("CloudKit/companion-sync.schema.ckdb"),
            checked_in_schema=checked_in_schema,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("grants changed for record type: Users", result.stdout)

    def test_cloudkit_schema_validator_rejects_unexpected_checked_in_record_type(self):
        checked_in_schema = self.read("CloudKit/companion-sync.schema.ckdb").replace(
            "\n    RECORD TYPE Users (",
            "\n    RECORD TYPE UnexpectedType (\n        value STRING\n    );\n\n    RECORD TYPE Users (",
        )

        result = self.run_cloudkit_schema_validator_with_fake_cktool(
            self.read("CloudKit/companion-sync.schema.ckdb"),
            checked_in_schema=checked_in_schema,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("record types differ from the additive companion/runtime baseline", result.stdout)

    def test_cloudkit_companion_schema_validator_rejects_wrong_ckdb_field_type(self):
        live_schema = self.read("CloudKit/companion-sync.schema.ckdb").replace(
            "payload               BYTES QUERYABLE SORTABLE",
            "payload               STRING QUERYABLE SORTABLE",
        )

        result = self.run_cloudkit_schema_validator_with_fake_cktool(live_schema)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("CompanionSyncDocument.payload BYTES", result.stdout)

    def test_cloudkit_companion_schema_validator_rejects_nonqueryable_subscription_field(self):
        live_schema = self.read("CloudKit/companion-sync.schema.ckdb").replace(
            "snapshotSchemaVersion INT64 QUERYABLE SORTABLE",
            "snapshotSchemaVersion INT64 SORTABLE",
        )

        result = self.run_cloudkit_schema_validator_with_fake_cktool(live_schema)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("snapshotSchemaVersion", result.stdout)
        self.assertIn("not queryable", result.stdout)

    def test_cloudkit_schema_validator_rejects_missing_runtime_receipt_boundary(self):
        live_schema = re.sub(
            r"\n    RECORD TYPE RuntimeReceipt \(.*?\n    \);\n",
            "\n",
            self.read("CloudKit/companion-sync.schema.ckdb"),
            flags=re.DOTALL,
        )

        result = self.run_cloudkit_schema_validator_with_fake_cktool(live_schema)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing record type: RuntimeReceipt", result.stdout)

    def test_app_store_export_preserves_archived_build_number(self):
        upload_script = self.read("scripts/upload-app-store-connect-macos-app.sh")

        self.assertNotIn("manageAppVersionAndBuildNumber", upload_script)

    def test_macos_app_store_archive_stamps_and_verifies_build_fingerprint(self):
        project = self.read("project.yml")
        upload_script = self.read("scripts/upload-app-store-connect-macos-app.sh")
        context_panel_start = project.index("  ContextPanel:")
        refresh_agent_start = project.index("  ContextPanelRefreshAgent:")
        context_panel_target = project[context_panel_start:refresh_agent_start]

        self.assertIn("postBuildScripts:", context_panel_target)
        self.assertIn("Stamp Build Fingerprint", context_panel_target)
        self.assertIn('"$SRCROOT/scripts/stamp-context-panel-build.sh"', context_panel_target)
        self.assertIn('"$TARGET_BUILD_DIR/$FULL_PRODUCT_NAME"', context_panel_target)
        self.assertIn("ContextPanelBuildFingerprint.txt", context_panel_target)
        self.assertIn("basedOnDependencyAnalysis: false", context_panel_target)

        assert_lines_in_order(
            upload_script,
            'run_xcodebuild "${archive_args[@]}" archive',
            "verify_archived_build_fingerprint",
            "scripts/context-panel-write-expected-build.sh \\",
            "-exportArchive \\",
        )
        self.assertIn("archived app is missing the build fingerprint", upload_script)
        self.assertIn("archived app build fingerprint does not match the source tree", upload_script)
        self.assertIn("--layout macos", upload_script)

    def test_build_fingerprint_delegates_to_reviewed_surface_contract(self):
        fingerprint_script = self.read("scripts/context-panel-build-fingerprint.sh")

        self.assertIn("context-panel-surface-manifest.py", fingerprint_script)
        self.assertIn("--surface macos.app", fingerprint_script)
        self.assertIn("--kind combined", fingerprint_script)
        self.assertNotIn("find Sources", fingerprint_script)

    def test_every_shipping_target_stamps_the_surface_manifest(self):
        project = self.read("project.yml")
        target_names = (
            "ContextPanel",
            "ContextPanelRefreshAgent",
            "ContextPanelWidgetExtension",
            "ContextPanelCompanion",
            "ContextPanelCompanionWidgetExtension",
            "ContextPanelWatch",
            "ContextPanelWatchWidgetExtension",
            "ContextPanelTV",
            "ContextPanelTVTopShelfExtension",
        )
        target_positions = [project.index(f"  {name}:") for name in target_names]
        schemes_index = project.index("schemes:")
        for index, target_name in enumerate(target_names):
            start = target_positions[index]
            end = target_positions[index + 1] if index + 1 < len(target_positions) else schemes_index
            target = project[start:end]
            with self.subTest(target=target_name):
                self.assertIn("postBuildScripts:", target)
                self.assertIn("stamp-context-panel-build.sh", target)
                self.assertIn("basedOnDependencyAnalysis: false", target)

    def test_companion_archives_emit_expected_signed_build_manifests(self):
        upload_script = self.read("scripts/upload-app-store-connect-companion-app.sh")
        assert_lines_in_order(
            upload_script,
            'run_xcodebuild "${archive_args[@]}" archive',
            'scripts/context-panel-write-expected-build.sh "${expected_build_args[@]}"',
            "-exportArchive \\",
        )
        self.assertIn('--layout "$platform"', upload_script)
        self.assertIn('--version "$marketing_version"', upload_script)
        self.assertIn('--build-number "$build_number"', upload_script)
        self.assertIn('companion.ios.app=$app_profile', upload_script)
        self.assertIn('companion.visionos.widget=$widget_profile', upload_script)
        self.assertIn('watchos.widget=$watch_widget_profile', upload_script)
        self.assertIn('tvos.top-shelf=$tv_top_shelf_profile', upload_script)

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
        self.assertIn('app_store_platform="TV_OS"', script)

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

    def test_commit_gate_namespaces_artifact_cache_by_physical_checkout(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)
            artifact_cache_root = temp_path / "artifact cache"
            artifact_cache_root.mkdir()
            first_checkout = temp_path / "checkout one"
            second_checkout = temp_path / "checkout two"

            first = self.run_commit_gate_cache_fixture(
                first_checkout, artifact_cache_root
            )
            second = self.run_commit_gate_cache_fixture(
                second_checkout, artifact_cache_root
            )

            first_scratch = (
                artifact_cache_root
                / "checkouts"
                / self.expected_checkout_cache_key(first_checkout)
                / "swiftpm"
            )
            second_scratch = (
                artifact_cache_root
                / "checkouts"
                / self.expected_checkout_cache_key(second_checkout)
                / "swiftpm"
            )
            self.assertEqual(first.returncode, 0, first.stdout)
            self.assertEqual(second.returncode, 0, second.stdout)
            self.assertIn(
                f"commit gate SwiftPM scratch path: {first_scratch}", first.stdout
            )
            self.assertIn(
                f"commit gate SwiftPM scratch path: {second_scratch}", second.stdout
            )
            self.assertNotEqual(first_scratch, second_scratch)

            checkout_alias = temp_path / "checkout alias"
            checkout_alias.symlink_to(first_checkout, target_is_directory=True)
            through_alias = self.run_commit_gate_cache_fixture(
                first_checkout,
                artifact_cache_root,
                invocation_root=checkout_alias,
            )
            self.assertEqual(through_alias.returncode, 0, through_alias.stdout)
            self.assertIn(
                f"commit gate SwiftPM scratch path: {first_scratch}",
                through_alias.stdout,
            )

            case_alias = first_checkout.with_name(first_checkout.name.upper())
            if case_alias.exists():
                through_case_alias = self.run_commit_gate_cache_fixture(
                    first_checkout,
                    artifact_cache_root,
                    invocation_root=case_alias,
                )
                self.assertEqual(
                    through_case_alias.returncode, 0, through_case_alias.stdout
                )
                self.assertIn(
                    f"commit gate SwiftPM scratch path: {first_scratch}",
                    through_case_alias.stdout,
                )

    def test_commit_gate_preserves_override_and_falls_back_without_hash_tool(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)
            artifact_cache_root = temp_path / "artifact cache"
            artifact_cache_root.mkdir()
            checkout_root = temp_path / "checkout"
            scratch_override = temp_path / "explicit SwiftPM scratch"

            explicit = self.run_commit_gate_cache_fixture(
                checkout_root,
                artifact_cache_root,
                scratch_override=scratch_override,
            )
            fallback = self.run_commit_gate_cache_fixture(
                checkout_root,
                artifact_cache_root,
                include_standard_path=False,
            )

            self.assertEqual(explicit.returncode, 0, explicit.stdout)
            self.assertIn(
                f"commit gate SwiftPM scratch path: {scratch_override}",
                explicit.stdout,
            )
            self.assertEqual(fallback.returncode, 0, fallback.stdout)
            self.assertIn(
                f"commit gate SwiftPM scratch path: {checkout_root.resolve() / '.build'}",
                fallback.stdout,
            )

    def test_companion_validation_namespaces_derived_data_and_preserves_overrides(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)
            artifact_cache_root = temp_path / "artifact cache"
            artifact_cache_root.mkdir()
            first_checkout = temp_path / "checkout one"
            second_checkout = temp_path / "checkout two"

            first = self.run_companion_cache_fixture(
                first_checkout, artifact_cache_root
            )
            second = self.run_companion_cache_fixture(
                second_checkout, artifact_cache_root
            )
            first_root = (
                artifact_cache_root
                / "checkouts"
                / self.expected_checkout_cache_key(first_checkout)
                / "derived-data"
                / "companion-build-validation"
            )
            second_root = (
                artifact_cache_root
                / "checkouts"
                / self.expected_checkout_cache_key(second_checkout)
                / "derived-data"
                / "companion-build-validation"
            )
            self.assertEqual(first.returncode, 0, first.stdout)
            self.assertEqual(second.returncode, 0, second.stdout)
            self.assertIn(
                f"companion validation DerivedData root: {first_root}", first.stdout
            )
            self.assertIn(
                f"companion validation DerivedData root: {second_root}", second.stdout
            )
            self.assertNotEqual(first_root, second_root)

            checkout_alias = temp_path / "checkout alias"
            checkout_alias.symlink_to(first_checkout, target_is_directory=True)
            through_alias = self.run_companion_cache_fixture(
                first_checkout,
                artifact_cache_root,
                invocation_root=checkout_alias,
            )
            self.assertEqual(through_alias.returncode, 0, through_alias.stdout)
            self.assertIn(
                f"companion validation DerivedData root: {first_root}",
                through_alias.stdout,
            )

            case_alias = first_checkout.with_name(first_checkout.name.upper())
            if case_alias.exists():
                through_case_alias = self.run_companion_cache_fixture(
                    first_checkout,
                    artifact_cache_root,
                    invocation_root=case_alias,
                )
                self.assertEqual(
                    through_case_alias.returncode, 0, through_case_alias.stdout
                )
                self.assertIn(
                    f"companion validation DerivedData root: {first_root}",
                    through_case_alias.stdout,
                )

            fallback = self.run_companion_cache_fixture(
                first_checkout,
                artifact_cache_root,
                working_directory=temp_path,
                include_standard_path=False,
            )
            self.assertEqual(fallback.returncode, 0, fallback.stdout)
            self.assertIn(
                "companion validation DerivedData root: "
                f"{first_checkout.resolve() / '.build/companion-build-validation'}",
                fallback.stdout,
            )

            environment_override = (
                temp_path
                / "explicit environment"
                / "derived-data"
                / "companion-build-validation"
            )
            environment_override.parent.parent.mkdir()
            explicit = self.run_companion_cache_fixture(
                first_checkout,
                artifact_cache_root,
                derived_data_override=environment_override,
            )
            cli_override = (
                temp_path
                / "explicit CLI"
                / "derived-data"
                / "companion-build-validation"
            )
            cli_override.parent.parent.mkdir()
            cli = self.run_companion_cache_fixture(
                first_checkout,
                artifact_cache_root,
                derived_data_override=environment_override,
                cli_derived_data_root=cli_override,
            )
            self.assertEqual(explicit.returncode, 0, explicit.stdout)
            self.assertIn(
                f"companion validation DerivedData root: {environment_override}",
                explicit.stdout,
            )
            self.assertEqual(cli.returncode, 0, cli.stdout)
            self.assertIn(
                f"companion validation DerivedData root: {cli_override}", cli.stdout
            )

    def test_companion_cache_quarantines_minimal_bundle_roots_without_following_symlinks(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)
            checkout_root = temp_path / "checkout"
            checkout_root.mkdir()
            cache_root = (
                checkout_root
                / "derived-data"
                / "companion-build-validation"
            )
            product_root = cache_root / "ios/Build/Products/Release-iphoneos"
            app_path = product_root / "Context Panel.app"
            nested_watch_app = app_path / "Watch/Context Panel.app"
            nested_watch_widget = (
                nested_watch_app
                / "PlugIns/ContextPanelWatchWidgetExtension.appex"
            )
            nested_watch_widget.mkdir(parents=True)
            (nested_watch_widget / "fixture").write_text("watch")

            external_widget = temp_path / "external widget"
            external_widget.mkdir()
            symlink_widget = (
                product_root / "ContextPanelCompanionWidgetExtension.appex"
            )
            symlink_widget.symlink_to(external_widget, target_is_directory=True)

            unrelated_bundle = product_root / "Unrelated.app"
            unrelated_bundle.mkdir()
            unrelated_file = cache_root / "compiler-cache/module.cache"
            unrelated_file.parent.mkdir(parents=True)
            unrelated_file.write_text("keep")
            expected_manifest = cache_root / "ExpectedBuildManifest-ios.json"
            expected_manifest.write_text("{}")
            runtime_receipt = cache_root / "runtime-receipt.json"
            runtime_receipt.write_text("{}")

            result = self.run_companion_cache_helper("quarantine", cache_root)

            self.assertEqual(result.returncode, 0, result.stdout)
            self.assertIn("bundles=4 apps=2 widgets=1", result.stdout)
            self.assertIn("watch-widgets=1", result.stdout)
            self.assertIn("symlinks=1", result.stdout)
            self.assertIn("quarantine=OK moved=2", result.stdout)
            self.assertFalse(app_path.exists())
            self.assertFalse(symlink_widget.exists())
            self.assertTrue(external_widget.is_dir())
            self.assertTrue(unrelated_bundle.is_dir())
            self.assertEqual(unrelated_file.read_text(), "keep")
            self.assertEqual(expected_manifest.read_text(), "{}")
            self.assertEqual(runtime_receipt.read_text(), "{}")

            quarantine_base = checkout_root / ".context-panel-companion-quarantine"
            quarantines = list(quarantine_base.iterdir())
            self.assertEqual(len(quarantines), 1)
            quarantined_app = (
                quarantines[0]
                / "ios/Build/Products/Release-iphoneos/Context Panel.app.quarantined"
            )
            quarantined_symlink = (
                quarantines[0]
                / "ios/Build/Products/Release-iphoneos/ContextPanelCompanionWidgetExtension.appex.quarantined"
            )
            self.assertTrue(quarantined_app.is_dir())
            self.assertTrue(
                (
                    quarantined_app
                    / "Watch/Context Panel.app.quarantined/PlugIns/ContextPanelWatchWidgetExtension.appex.quarantined/fixture"
                ).is_file()
            )
            self.assertTrue(quarantined_symlink.is_symlink())
            self.assertEqual(quarantined_symlink.resolve(), external_widget.resolve())
            self.assertEqual(
                list(quarantines[0].rglob("*.app"))
                + list(quarantines[0].rglob("*.appex")),
                [],
            )

    def test_companion_cache_quarantine_is_a_safe_noop(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            checkout_root = Path(temp_dir) / "checkout"
            cache_root = (
                checkout_root
                / "derived-data"
                / "companion-build-validation"
            )
            cache_root.mkdir(parents=True)

            result = self.run_companion_cache_helper("quarantine", cache_root)

            self.assertEqual(result.returncode, 0, result.stdout)
            self.assertIn("quarantine=OK moved=0", result.stdout)
            self.assertFalse(
                (checkout_root / ".context-panel-companion-quarantine").exists()
            )

    def test_companion_cache_keeps_checkout_quarantine_inside_ignored_build_root(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            checkout_root = Path(temp_dir) / "checkout"
            cache_root = (
                checkout_root
                / ".build/companion-build-validation"
            )
            app_path = cache_root / "Build/Products/Context Panel.app"
            app_path.mkdir(parents=True)

            result = self.run_companion_cache_helper("quarantine", cache_root)

            self.assertEqual(result.returncode, 0, result.stdout)
            self.assertIn("quarantine=OK moved=1", result.stdout)
            self.assertFalse(
                (checkout_root / ".context-panel-companion-quarantine").exists()
            )
            quarantine_base = (
                checkout_root
                / ".build/.context-panel-companion-quarantine"
            )
            self.assertEqual(
                len(
                    list(
                        quarantine_base.glob(
                            "*/Build/Products/Context Panel.app.quarantined"
                        )
                    )
                ),
                1,
            )

    def test_companion_cache_rejects_unrelated_root_level_and_symlink_roots(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)
            unrelated = temp_path / "unrelated"
            unrelated.mkdir()
            unrelated_result = self.run_companion_cache_helper(
                "quarantine", unrelated
            )
            root_level_result = self.run_companion_cache_helper(
                "quarantine", Path("/companion-build-validation")
            )
            root_build_result = self.run_companion_cache_helper(
                "quarantine", Path("/.build/companion-build-validation")
            )

            real_root = temp_path / "real/derived-data/companion-build-validation"
            real_root.mkdir(parents=True)
            symlink_parent = temp_path / "symlink/derived-data"
            symlink_parent.mkdir(parents=True)
            symlink_root = symlink_parent / "companion-build-validation"
            symlink_root.symlink_to(real_root, target_is_directory=True)
            symlink_result = self.run_companion_cache_helper(
                "quarantine", symlink_root
            )

            outside_root = temp_path / "outside/child"
            escaped_root = (
                outside_root
                / "derived-data/companion-build-validation"
            )
            escaped_root.mkdir(parents=True)
            ancestor_parent = temp_path / "safe"
            ancestor_parent.mkdir()
            ancestor_link = ancestor_parent / "link"
            ancestor_link.symlink_to(temp_path / "outside", target_is_directory=True)
            ancestor_result = self.run_companion_cache_helper(
                "quarantine",
                ancestor_link
                / "child/derived-data/companion-build-validation",
            )

            self.assertNotEqual(unrelated_result.returncode, 0)
            self.assertIn("root rejected", unrelated_result.stdout)
            self.assertNotEqual(root_level_result.returncode, 0)
            self.assertIn("root rejected", root_level_result.stdout)
            self.assertNotEqual(root_build_result.returncode, 0)
            self.assertIn("root rejected", root_build_result.stdout)
            self.assertNotEqual(symlink_result.returncode, 0)
            self.assertIn("symbolic link", symlink_result.stdout)
            self.assertNotEqual(ancestor_result.returncode, 0)
            self.assertIn("must not traverse symbolic links", ancestor_result.stdout)

    def test_companion_cache_preflight_passes_clean_and_fails_on_residue(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            cache_root = (
                Path(temp_dir)
                / "checkout/derived-data/companion-build-validation"
            )
            cache_root.mkdir(parents=True)

            clean = self.run_companion_cache_helper("preflight", cache_root)
            residue = cache_root / "Build/Products/ContextPanelRefreshAgent.app"
            residue.mkdir(parents=True)
            dirty = self.run_companion_cache_helper("preflight", cache_root)

            self.assertEqual(clean.returncode, 0, clean.stdout)
            self.assertIn("preflight=OK", clean.stdout)
            self.assertNotEqual(dirty.returncode, 0)
            self.assertIn("refresh-agents=1", dirty.stdout)
            self.assertIn("preflight=FAIL", dirty.stdout)
            self.assertTrue(residue.is_dir())

    def test_companion_cache_refuses_signed_bundle_material(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            cache_root = (
                Path(temp_dir)
                / "checkout/derived-data/companion-build-validation"
            )
            signed_app = cache_root / "Build/Products/Context Panel.app"
            signature = (
                signed_app
                / "Watch/Context Panel.app/_CodeSignature/CodeResources"
            )
            signature.parent.mkdir(parents=True)
            signature.write_text("signed")

            result = self.run_companion_cache_helper("quarantine", cache_root)

            self.assertEqual(result.returncode, 3, result.stdout)
            self.assertIn("protected-signed-bundles=1", result.stdout)
            self.assertTrue(signed_app.is_dir())

    def test_companion_cache_refuses_inventory_inspection_errors(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            cache_root = (
                Path(temp_dir)
                / "checkout/derived-data/companion-build-validation"
            )
            app_path = cache_root / "Build/Products/Context Panel.app"
            unreadable_path = app_path / "Unreadable"
            unreadable_path.mkdir(parents=True)
            unreadable_path.chmod(0)
            try:
                result = self.run_companion_cache_helper("quarantine", cache_root)
            finally:
                unreadable_path.chmod(0o700)

            self.assertEqual(result.returncode, 2, result.stdout)
            self.assertIn("inventory=FAILED", result.stdout)
            self.assertNotIn(str(unreadable_path), result.stdout)
            self.assertTrue(app_path.is_dir())

    def test_companion_cache_rejects_symlinked_quarantine_destination(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)
            checkout_root = temp_path / "checkout"
            cache_root = (
                checkout_root
                / "derived-data/companion-build-validation"
            )
            app_path = cache_root / "Build/Products/Context Panel.app"
            app_path.mkdir(parents=True)
            external_quarantine = temp_path / "external quarantine"
            external_quarantine.mkdir()
            quarantine_base = checkout_root / ".context-panel-companion-quarantine"
            quarantine_base.symlink_to(
                external_quarantine,
                target_is_directory=True,
            )

            result = self.run_companion_cache_helper("quarantine", cache_root)

            self.assertEqual(result.returncode, 3, result.stdout)
            self.assertIn("unsafe-quarantine-base", result.stdout)
            self.assertTrue(app_path.is_dir())
            self.assertEqual(list(external_quarantine.iterdir()), [])

    def test_companion_cache_fails_when_nested_bundle_cannot_be_neutralized(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)
            checkout_root = temp_path / "checkout"
            cache_root = (
                checkout_root
                / "derived-data/companion-build-validation"
            )
            app_path = cache_root / "Build/Products/Context Panel.app"
            watch_parent = app_path / "Watch"
            watch_widget = (
                watch_parent
                / "Context Panel.app/PlugIns/ContextPanelWatchWidgetExtension.appex"
            )
            watch_widget.mkdir(parents=True)
            watch_parent.chmod(0o555)
            try:
                result = self.run_companion_cache_helper("quarantine", cache_root)
            finally:
                watch_parent.chmod(0o755)

            self.assertEqual(result.returncode, 3, result.stdout)
            self.assertIn("bundle-neutralization", result.stdout)
            self.assertTrue(app_path.is_dir())
            quarantine_base = checkout_root / ".context-panel-companion-quarantine"
            self.assertEqual(
                list(quarantine_base.rglob("*.app"))
                + list(quarantine_base.rglob("*.appex")),
                [],
            )

    def test_companion_cache_preflight_discovers_current_and_legacy_retry_roots(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)
            runner_temp = temp_path / "runner temp"
            temporary_directory = temp_path / "temporary"
            runner_temp.mkdir()
            temporary_directory.mkdir()
            retry_root = (
                runner_temp
                / "context-panel-companion-retry.fixture"
                / "derived-data/companion-build-validation"
            )
            residue = retry_root / "Build/Products/ContextPanelRefreshAgent.app"
            residue.mkdir(parents=True)
            legacy_retry_root = (
                runner_temp
                / "context-panel-companion-retry.legacy"
                / "tvos"
            )
            legacy_residue = (
                legacy_retry_root
                / "Build/Products/ContextPanelTVTopShelfExtension.appex"
            )
            legacy_residue.mkdir(parents=True)
            environment = os.environ.copy()
            environment["RUNNER_TEMP"] = str(runner_temp)
            environment["TMPDIR"] = str(temporary_directory)
            environment["CONTEXT_PANEL_ARTIFACT_CACHE_ROOT"] = str(
                temp_path / "absent artifact cache"
            )

            result = self.run_companion_cache_helper(
                "preflight",
                environment=environment,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("preflight=FAIL", result.stdout)
            self.assertRegex(result.stdout, r"refresh-agents=[1-9][0-9]*")
            self.assertRegex(result.stdout, r"top-shelf=[1-9][0-9]*")
            self.assertTrue(residue.is_dir())
            self.assertTrue(legacy_residue.is_dir())

    def test_companion_validation_quarantines_after_failure(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)
            artifact_cache_root = temp_path / "artifact cache"
            artifact_cache_root.mkdir()
            checkout_root = temp_path / "checkout"
            fake_xcodebuild = """#!/bin/bash
derived_data=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-derivedDataPath" ]]; then
    derived_data="$2"
    shift 2
  else
    shift
  fi
done
mkdir -p "$derived_data/Build/Products/Release-iphoneos/Context Panel.app"
printf '** BUILD FAILED **\n'
exit 7
"""

            result = self.run_companion_cache_fixture(
                checkout_root,
                artifact_cache_root,
                fake_xcodebuild_body=fake_xcodebuild,
            )
            cache_root = (
                artifact_cache_root
                / "checkouts"
                / self.expected_checkout_cache_key(checkout_root)
                / "derived-data/companion-build-validation"
            )

            self.assertEqual(result.returncode, 7, result.stdout)
            self.assertIn("quarantine=OK moved=1", result.stdout)
            self.assertFalse(
                (cache_root / "ios/Build/Products/Release-iphoneos/Context Panel.app").exists()
            )
            quarantine_base = (
                cache_root.parent.parent / ".context-panel-companion-quarantine"
            )
            self.assertEqual(
                len(
                    list(
                        quarantine_base.glob(
                            "*/ios/Build/Products/Release-iphoneos/Context Panel.app.quarantined"
                        )
                    )
                ),
                1,
            )

    def test_companion_validation_preserves_failure_status_when_cleanup_refuses(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)
            artifact_cache_root = temp_path / "artifact cache"
            artifact_cache_root.mkdir()
            checkout_root = temp_path / "checkout"
            fake_xcodebuild = """#!/bin/bash
derived_data=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-derivedDataPath" ]]; then
    derived_data="$2"
    shift 2
  else
    shift
  fi
done
app="$derived_data/Build/Products/Release-iphoneos/Context Panel.app"
mkdir -p "$app"
printf 'signed' > "$app/embedded.mobileprovision"
printf '** BUILD FAILED **\n'
exit 7
"""

            result = self.run_companion_cache_fixture(
                checkout_root,
                artifact_cache_root,
                fake_xcodebuild_body=fake_xcodebuild,
            )
            cache_root = (
                artifact_cache_root
                / "checkouts"
                / self.expected_checkout_cache_key(checkout_root)
                / "derived-data/companion-build-validation"
            )

            self.assertEqual(result.returncode, 7, result.stdout)
            self.assertIn("protected-signed-bundles=1", result.stdout)
            self.assertIn(
                "preserving validation status 7",
                result.stdout,
            )
            self.assertTrue(
                (cache_root / "ios/Build/Products/Release-iphoneos/Context Panel.app").is_dir()
            )

    def test_companion_validation_quarantines_after_interruption(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)
            artifact_cache_root = temp_path / "artifact cache"
            artifact_cache_root.mkdir()
            checkout_root = temp_path / "checkout"
            result = self.run_companion_interrupt_fixture(
                checkout_root,
                artifact_cache_root,
            )
            cache_root = (
                artifact_cache_root
                / "checkouts"
                / self.expected_checkout_cache_key(checkout_root)
                / "derived-data/companion-build-validation"
            )

            self.assertEqual(result.returncode, 143, result.stdout)
            self.assertIn("quarantine=OK moved=1", result.stdout)
            self.assertFalse(
                (cache_root / "ios/Build/Products/Release-iphoneos/Context Panel.app").exists()
            )

    def test_companion_validation_reports_cleanup_failure_after_success(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)
            artifact_cache_root = temp_path / "artifact cache"
            artifact_cache_root.mkdir()
            checkout_root = temp_path / "checkout"
            fake_xcodebuild = """#!/bin/bash
derived_data=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-derivedDataPath" ]]; then
    derived_data="$2"
    shift 2
  else
    shift
  fi
done
app="$derived_data/Build/Products/Release-iphoneos/Context Panel.app"
mkdir -p "$app"
printf 'signed' > "$app/embedded.mobileprovision"
printf '** BUILD SUCCEEDED **\n'
exit 0
"""

            result = self.run_companion_cache_fixture(
                checkout_root,
                artifact_cache_root,
                fake_xcodebuild_body=fake_xcodebuild,
            )

            self.assertEqual(result.returncode, 3, result.stdout)
            self.assertIn("protected-signed-bundles=1", result.stdout)

    def test_codeql_namespaces_trusted_swiftpm_cache_by_checkout(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)
            artifact_cache_root = temp_path / "artifact cache"
            artifact_cache_root.mkdir()
            checkout_root = temp_path / "checkout"
            checkout_root.mkdir()

            trusted = self.run_codeql_cache_fixture(
                checkout_root, artifact_cache_root, trusted_run=True
            )
            trusted_scratch = (
                artifact_cache_root
                / "checkouts"
                / self.expected_checkout_cache_key(checkout_root)
                / "codeql-swiftpm"
            )
            self.assertEqual(trusted.returncode, 0, trusted.stdout)
            self.assertIn(
                f"CodeQL SwiftPM scratch path: {trusted_scratch}", trusted.stdout
            )

            untrusted = self.run_codeql_cache_fixture(
                checkout_root, artifact_cache_root, trusted_run=False
            )
            local_scratch = checkout_root.resolve() / ".build"
            self.assertEqual(untrusted.returncode, 0, untrusted.stdout)
            self.assertIn(
                f"CodeQL SwiftPM scratch path: {local_scratch}", untrusted.stdout
            )
            self.assertNotIn(str(artifact_cache_root / "checkouts"), untrusted.stdout)

            missing_hash_tool = self.run_codeql_cache_fixture(
                checkout_root,
                artifact_cache_root,
                trusted_run=True,
                include_standard_path=False,
            )
            self.assertEqual(
                missing_hash_tool.returncode, 0, missing_hash_tool.stdout
            )
            self.assertIn(
                f"CodeQL SwiftPM scratch path: {local_scratch}",
                missing_hash_tool.stdout,
            )

    def test_companion_build_validation_supports_ios_visionos_watchos_and_tvos_without_signing(self):
        workflow = self.read(".github/workflows/ci.yml")
        script = self.read("scripts/validate-companion-builds.sh")
        cache_helper = self.read("scripts/context-panel-companion-cache.sh")
        release_docs = self.read("docs/release.md")
        github_metadata = json.loads(self.read(".github/github.json"))

        self.assertIn("scripts/commit-gate.sh", workflow)
        self.assertIn("Run routine Python test lane", workflow)
        self.assertIn("timeout-minutes: 5", workflow)
        self.assertIn("--lane routine-ci-python", workflow)
        self.assertIn("Upload test lane timings", workflow)
        self.assertIn("test-lane-timings-${{ github.run_attempt }}", workflow)
        self.assertIn(".build/test-lane-timings/fast-local-python.json", workflow)
        self.assertIn(".build/test-lane-timings/routine-ci-python.json", workflow)
        self.assertIn(".build/test-lane-timings/routine-ci-swift.json", workflow)
        self.assertIn("scripts/validate-companion-builds.sh", workflow)
        self.assertIn("--configuration Release --archive ios", workflow)
        self.assertIn("scripts/validate-companion-builds.sh --configuration Release watchos", workflow)
        self.assertIn("scripts/validate-companion-builds.sh --configuration Release --archive tvos", workflow)
        self.assertIn("--archive", script)
        self.assertIn("archive validation is not supported for standalone watchOS", script)
        self.assertNotIn("archive validation is not supported for standalone tvOS", script)
        self.assertIn("Validating $scheme archive for $destination", script)
        self.assertIn("-archivePath \"$archive_path\"", script)
        self.assertIn("validate_archive_contents()", script)
        self.assertIn('marker="** BUILD SUCCEEDED **"', script)
        self.assertIn('marker="** ARCHIVE SUCCEEDED **"', script)
        self.assertIn("xcodebuild did not reach a terminal result within 30 minutes", script)
        self.assertIn("xcodebuild produced no output for 5 minutes", script)
        self.assertIn("xcodebuild validation requires exactly one build or archive action", script)
        self.assertIn("Retrying $platform validation once with isolated DerivedData", script)
        self.assertIn("context-panel-companion-retry.XXXXXX", script)
        self.assertIn("if ((status != 124)); then", script)
        self.assertIn('/usr/bin/tee "$log_file"', script)
        self.assertIn('/usr/bin/tail -n 500 "$log_file"', script)
        self.assertIn('signal_xcodebuild_processes TERM "$process_group"', script)
        self.assertIn('signal_xcodebuild_processes KILL "$process_group"', script)
        self.assertIn('/usr/bin/pgrep -P "$parent_pid"', script)
        self.assertIn('process_group="$job_pid"', script)
        self.assertNotIn("/bin/ps -o pgid=", script)
        self.assertNotIn("disown -a", script)
        self.assertNotIn("killall", script)
        self.assertNotIn("launchctl kill", script)
        self.assertIn("iOS companion archive is missing embedded watch app", script)
        self.assertIn("iOS companion archive is missing embedded watch widget", script)
        self.assertIn("visionOS companion archive unexpectedly contains watch content", script)
        self.assertIn("tvOS companion archive unexpectedly contains watch content", script)
        self.assertIn("tvOS companion archive unexpectedly contains the iOS/visionOS companion widget", script)
        self.assertIn("tvOS companion archive is missing embedded Top Shelf extension", script)
        self.assertIn("tvOS Top Shelf extension is missing the required arm64 device capability", script)
        self.assertIn("UIRequiredDeviceCapabilities", script)
        self.assertIn("tvOS companion archive is missing compiled brand assets", script)
        self.assertIn("tvOS companion archive is missing the primary layered app icon", script)
        self.assertIn("tvOS companion archive is missing required standard or wide Top Shelf artwork", script)
        self.assertIn("Products/Applications/Context Panel.app", script)
        self.assertIn("Watch/Context Panel.app", script)
        self.assertIn("PlugIns/ContextPanelWatchWidgetExtension.appex", script)
        self.assertIn("PlugIns/ContextPanelTVTopShelfExtension.appex", script)
        self.assertIn("platforms=(ios visionos watchos tvos)", script)
        self.assertIn("generic/platform=iOS", script)
        self.assertIn(
            'companion_cache_helper="$repo_root/scripts/context-panel-companion-cache.sh"',
            script,
        )
        self.assertIn("trap finalize_companion_validation EXIT", script)
        self.assertIn("trap 'handle_validation_signal 129' HUP", script)
        self.assertIn("trap 'handle_validation_signal 130' INT", script)
        self.assertIn("trap 'handle_validation_signal 143' TERM", script)
        self.assertIn('"$companion_cache_helper" quarantine --root "$root"', script)
        self.assertIn("preserving validation status $original_status", script)
        self.assertIn("context-panel-companion-retry.XXXXXX", script)
        self.assertIn("derived-data/companion-build-validation", script)
        self.assertIn("/usr/bin/find -P", cache_helper)
        self.assertIn("-print0 -prune", cache_helper)
        self.assertIn("protected-signed-bundles", cache_helper)
        self.assertIn(".context-panel-companion-quarantine", cache_helper)
        self.assertIn("neutralize_bundle_tree", cache_helper)
        self.assertIn("trap '' HUP INT TERM", cache_helper)
        self.assertIn("trap '' HUP INT TERM", script)
        self.assertNotIn("rm -rf", cache_helper)
        self.assertIn(
            "scripts/context-panel-companion-cache.sh preflight",
            release_docs,
        )
        validate_commands = github_metadata["qualityGate"]["validate"]
        self.assertEqual(
            validate_commands["companionCachePreflight"],
            "scripts/context-panel-companion-cache.sh preflight",
        )
        self.assertIn(
            "context-panel-companion-cache.sh quarantine --root",
            validate_commands["companionCacheQuarantine"],
        )
        self.assertIn("generic/platform=visionOS", script)
        self.assertIn("generic/platform=watchOS", script)
        self.assertIn("generic/platform=tvOS", script)
        self.assertIn("CODE_SIGNING_ALLOWED=NO", script)
        self.assertIn("ContextPanelCompanion", script)
        self.assertIn("ContextPanelWatch", script)
        self.assertIn("ContextPanelTV", script)
        self.assertIn("PATH=\"$(xcodebuild_system_path)\" /usr/bin/xcodebuild", script)

    def test_companion_build_validation_retries_only_a_stalled_xcodebuild(self):
        completed, invocation_count, sentinel_alive = self.run_companion_validation_watchdog_fixture(
            """#!/usr/bin/env bash
set -euo pipefail
counter="${FAKE_XCODEBUILD_COUNTER:?}"
count=0
if [[ -f "$counter" ]]; then
    count="$(cat "$counter")"
fi
count=$((count + 1))
printf '%s' "$count" > "$counter"
if ((count == 1)); then
    echo "fake xcodebuild started"
    set -m
    /bin/sleep 30 &
    wait
fi
echo "** BUILD SUCCEEDED **"
"""
        )

        self.assertEqual(completed.returncode, 0, completed.stdout)
        self.assertEqual(invocation_count, 2)
        self.assertTrue(sentinel_alive)
        self.assertIn("xcodebuild produced no output", completed.stdout)
        self.assertIn("Retrying ios validation once with isolated DerivedData", completed.stdout)

    def test_companion_build_validation_does_not_retry_a_build_failure(self):
        completed, invocation_count, sentinel_alive = self.run_companion_validation_watchdog_fixture(
            """#!/usr/bin/env bash
set -euo pipefail
counter="${FAKE_XCODEBUILD_COUNTER:?}"
count=0
if [[ -f "$counter" ]]; then
    count="$(cat "$counter")"
fi
count=$((count + 1))
printf '%s' "$count" > "$counter"
echo "** BUILD FAILED **"
exit 65
"""
        )

        self.assertNotEqual(completed.returncode, 0)
        self.assertEqual(invocation_count, 1)
        self.assertTrue(sentinel_alive)
        self.assertNotIn("Retrying ios validation once with isolated DerivedData", completed.stdout)

    def test_companion_upload_requires_tvos_layered_app_icon(self):
        script = self.read("scripts/upload-app-store-connect-companion-app.sh")
        project = self.read("project.yml")
        entitlements = self.read("Config/ContextPanelTV.entitlements")

        self.assertIn("assert_tvos_archive_ready()", script)
        self.assertIn("tvOS archive unexpectedly contains the iOS/visionOS companion widget", script)
        self.assertIn("tvOS archive is missing the embedded Top Shelf extension", script)
        self.assertIn("tvOS Top Shelf extension is missing the required arm64 device capability", script)
        self.assertIn("UIRequiredDeviceCapabilities", script)
        self.assertIn("tvOS archive is missing compiled brand assets", script)
        self.assertIn("tvOS archive is missing the primary layered app icon", script)
        self.assertIn("tvOS archive is missing required standard or wide Top Shelf artwork", script)
        self.assertIn('extract_signed_entitlements "$app_path" "tvOS app"', script)
        self.assertIn(
            "'com.apple.developer.icloud-container-environment' 'Production'",
            script,
        )
        self.assertIn("'aps-environment' 'production'", script)
        self.assertIn(
            "'com.apple.developer.user-management' 'runs-as-current-user-with-user-independent-keychain'",
            script,
        )
        self.assertIn("<key>com.apple.developer.icloud-container-environment</key>", entitlements)
        self.assertIn("<string>$(CLOUDKIT_ENVIRONMENT)</string>", entitlements)
        self.assertIn("CLOUDKIT_ENVIRONMENT: Development", project)
        self.assertIn("CLOUDKIT_ENVIRONMENT: Production", project)
        self.assertIn('if [[ "$platform" == "tvos" ]]; then\n\tassert_tvos_archive_ready', script)

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
        self.assertIn("profile_platforms=(tvOS)", script)
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

    def test_companion_upload_tvos_uses_dedicated_profile_without_widget(self):
        script = self.read("scripts/upload-app-store-connect-companion-app.sh")
        result = self.run_companion_upload_script(
            [
                "--platform",
                "tvos",
                "--version",
                "1.0.99",
                "--build-number",
                "168011",
                "--export-only",
                "--app-profile",
                ".build/missing-tvos-app.provisionprofile",
            ]
        )

        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("missing-tvos-app.provisionprofile", result.stdout)
        self.assertNotIn("companion widget provisioning profile not found", result.stdout)
        self.assertNotIn("visionOS companion packaging is blocked", result.stdout)
        self.assertIn("tv_top_shelf_profile_uuid", script)
        self.assertIn("ContextPanelTVTopShelfExtension.provisionprofile", script)
        self.assertIn("CONTEXT_PANEL_APP_STORE_TV_TOP_SHELF_PROFILE_SPECIFIER", script)

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

    def test_companion_upload_preflights_cloudkit_app_widget_and_watch_profiles(self):
        script = self.read("scripts/upload-app-store-connect-companion-app.sh")

        self.assertIn("assert_profile_icloud_service()", script)
        self.assertIn("assert_profile_icloud_environment()", script)
        self.assertIn("assert_profile_ubiquity_container()", script)
        self.assertIn("assert_profile_push_notifications()", script)
        self.assertIn("assert_profile_icloud_service \"$app_profile\" \"companion app\" \"CloudDocuments\"", script)
        self.assertIn("assert_profile_icloud_service \"$app_profile\" \"companion app\" \"CloudKit\"", script)
        self.assertIn(
            "assert_profile_icloud_environment \"$app_profile\" \"companion app\" \"Production\"",
            script,
        )
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
        self.assertIn(
            "assert_profile_icloud_environment \"$watch_profile\" \"companion watch\" \"Production\"",
            script,
        )
        self.assertIn(
            "assert_profile_icloud_environment \"$watch_widget_profile\" \"companion watch widget\" \"Production\"",
            script,
        )
        self.assertIn(
            "assert_profile_app_group \"$watch_profile\" \"companion watch\"",
            script,
        )
        self.assertIn(
            "assert_profile_app_group \"$watch_widget_profile\" \"companion watch widget\"",
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
        self.assertIn(
            "assert_profile_icloud_service \"$widget_profile\" \"companion widget\" \"CloudKit\"",
            script,
        )
        self.assertIn(
            "assert_profile_icloud_environment \"$widget_profile\" \"companion widget\" \"Production\"",
            script,
        )
        self.assertNotIn("assert_profile_ubiquity_container \"$widget_profile\"", script)
        self.assertNotIn("assert_profile_push_notifications \"$widget_profile\"", script)

    def test_companion_upload_validates_signed_widget_and_watch_entitlements_before_export(self):
        script = self.read("scripts/upload-app-store-connect-companion-app.sh")

        self.assertIn("assert_companion_widget_archive_ready()", script)
        self.assertIn("assert_ios_watch_archive_ready()", script)
        self.assertIn("assert_bundle_version()", script)
        self.assertIn("assert_bundle_info_value()", script)
        self.assertIn("assert_code_signature_valid()", script)
        self.assertIn("/usr/bin/codesign -d --entitlements - --xml", script)
        self.assertIn("assert_signed_entitlement_array_value_absent()", script)
        self.assertIn("assert_signed_entitlement_value()", script)
        self.assertNotIn("assert_signed_app_group_exact", script)
        self.assertNotIn("group.com.shinycomputers.contextpanel.watch", script)
        self.assertIn(
            "assert_signed_entitlement_array_value \"$watch_app_entitlements\" \"companion Watch app\" \\",
            script,
        )
        self.assertIn(
            "assert_signed_entitlement_array_value \"$watch_widget_entitlements\" \"companion Watch widget\" \\",
            script,
        )
        self.assertGreaterEqual(
            script.count("'com.apple.security.application-groups' 'group.com.shinycomputers.contextpanel'"),
            3,
        )
        self.assertIn("'com.apple.developer.icloud-services' 'CloudKit'", script)
        self.assertIn(
            "'com.apple.developer.icloud-services' 'CloudDocuments'",
            script,
        )
        self.assertIn(
            "'com.apple.developer.icloud-container-identifiers' 'iCloud.com.shinycomputers.contextpanel'",
            script,
        )
        self.assertEqual(
            script.count("'com.apple.developer.icloud-container-identifiers' 'iCloud.com.shinycomputers.contextpanel'"),
            4,
        )
        self.assertEqual(
            script.count("'com.apple.developer.icloud-container-environment' 'Production'"),
            4,
        )
        assert_lines_in_order(
            script,
            'run_xcodebuild "${archive_args[@]}" archive',
            "assert_companion_widget_archive_ready",
            "assert_ios_watch_archive_ready",
            "-exportArchive \\",
        )

    def test_companion_upload_retains_generic_watch_archive_evidence(self):
        script = self.read("scripts/upload-app-store-connect-companion-app.sh")
        workflow = self.read(
            ".github/workflows/app-store-connect-companion-upload.yml"
        )

        self.assertIn(
            "iOS companion releases require both --version and --build-number.",
            script,
        )
        self.assertIn("write_ios_watch_archive_receipt()", script)
        self.assertIn("matching_dsym_relative_path()", script)
        self.assertIn("bundle_executable_uuids()", script)
        self.assertIn('rm -f "$watch_archive_receipt_path"', script)
        self.assertIn("receipt_schema_version=1", script)
        self.assertIn("archive_retained=true", script)
        self.assertIn("distribution_mode=%s", script)
        self.assertIn("local_ipa_expected=%s", script)
        self.assertIn("export-only mode did not emit a local IPA", script)
        self.assertIn("companion_signature=valid", script)
        self.assertIn("watch_app_signature=valid", script)
        self.assertIn("watch_widget_signature=valid", script)
        self.assertIn("companion_entitlements_sha256", script)
        self.assertIn("watch_app_entitlements_sha256", script)
        self.assertIn("watch_widget_entitlements_sha256", script)
        self.assertIn("companion_executable_sha256", script)
        self.assertIn("watch_app_executable_sha256", script)
        self.assertIn("watch_widget_executable_sha256", script)
        self.assertIn("companion_dsym=%s", script)
        self.assertIn("watch_app_dsym=%s", script)
        self.assertIn("watch_widget_dsym=%s", script)
        self.assertIn("'WKApplication' 'true'", script)
        self.assertIn(
            "'WKCompanionAppBundleIdentifier' 'com.shinycomputers.contextpanel'",
            script,
        )
        self.assertIn(
            "'NSExtension:NSExtensionPointIdentifier' 'com.apple.widgetkit-extension'",
            script,
        )
        self.assertNotIn("ContextPanelWatchUpgradeCanary", script)
        self.assertNotIn("watch_canary_marker", script)
        self.assertIn("WatchArchiveReceipt-*.txt", workflow)
        self.assertIn(".build/app-store-connect-companion/*.xcarchive", workflow)
        self.assertIn(".build/app-store-connect-companion/upload-*", workflow)

    def test_companion_upload_enforces_local_ipa_only_for_export_mode(self):
        script = self.read("scripts/upload-app-store-connect-companion-app.sh")
        result_block = script[script.rindex('if [[ "$upload" == "true" ]]; then') :]

        with tempfile.TemporaryDirectory() as temp_dir:
            export_path = Path(temp_dir)
            environment = os.environ.copy()
            environment["export_path"] = str(export_path)
            environment["platform_label"] = "iOS"

            environment["upload"] = "true"
            upload_result = subprocess.run(
                ["/bin/bash", "-c", result_block],
                env=environment,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                check=False,
            )
            self.assertEqual(upload_result.returncode, 0, upload_result.stdout)
            self.assertIn("Uploaded Context Panel companion (iOS)", upload_result.stdout)

            environment["upload"] = "false"
            missing_ipa_result = subprocess.run(
                ["/bin/bash", "-c", result_block],
                env=environment,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                check=False,
            )
            self.assertEqual(missing_ipa_result.returncode, 1)
            self.assertIn(
                "export-only mode did not emit a local IPA",
                missing_ipa_result.stdout,
            )

            ipa_path = export_path / "ContextPanelCompanion.ipa"
            ipa_path.write_bytes(b"signed-ipa-fixture")
            exported_ipa_result = subprocess.run(
                ["/bin/bash", "-c", result_block],
                env=environment,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                check=False,
            )
            self.assertEqual(exported_ipa_result.returncode, 0, exported_ipa_result.stdout)
            self.assertIn(str(ipa_path), exported_ipa_result.stdout)

    def test_post_canary_cleanup_keeps_the_production_watch_complication(self):
        widget = self.read(
            "Sources/ContextPanelWatchWidget/ContextPanelWatchWidget.swift"
        )
        watch_app = self.read("Sources/ContextPanelWatch/ContextPanelWatchApp.swift")

        self.assertIn("import ContextPanelCloudKitSync", widget)
        self.assertIn("WatchCompanionLoader", widget)
        self.assertIn("WatchCompanionCache", widget)
        self.assertIn("WatchComplicationTimelineReloadPolicy.shouldReload", watch_app)
        self.assertNotIn('Text("C")', widget)
        self.assertFalse(
            (REPO_ROOT / "Sources/ContextPanelWatchSupport/WatchUpgradeCanary.swift").exists()
        )
        self.assertNotIn(
            "ContextPanelWatchUpgradeCanary",
            self.read("Config/ContextPanelWatch-Info.plist"),
        )
        self.assertNotIn(
            "ContextPanelWatchUpgradeCanary",
            self.read("Config/ContextPanelWatchWidget-Info.plist"),
        )

    def test_release_runbook_requires_watch_restart_and_correct_artifact_modes(self):
        release_docs = self.read("docs/release.md")
        agent_notes = self.read("AGENTS.md")
        normalized_agent_notes = " ".join(agent_notes.split())

        self.assertIn("#### Routine Watch Complication Test", release_docs)
        self.assertIn("Restart the Watch after the installation completes.", release_docs)
        self.assertIn("Do not treat stale or blank pre-restart output", release_docs)
        self.assertIn("Upload mode may not emit a local IPA", release_docs)
        self.assertIn("Export-only mode must emit a local IPA.", release_docs)
        self.assertIn("WatchArchiveReceipt-iOS.txt", release_docs)
        self.assertIn("signed `.xcarchive`", release_docs)
        self.assertNotIn("### Watch Upgrade Canary", release_docs)
        self.assertIn(
            "first confirm that the new build has reached the Watch, then restart the Watch",
            normalized_agent_notes,
        )
        self.assertIn(
            "Do not use uninstall/reinstall or complication reselection as the routine workaround.",
            normalized_agent_notes,
        )

    def test_release_docs_describe_cloudkit_companion_testflight_validation(self):
        release_docs = self.read("docs/release.md")

        self.assertIn("Issue #274 records the completed initial iOS/visionOS validation", release_docs)
        self.assertIn("`testflight_beta_source=companion`", release_docs)
        self.assertIn("--platform MAC_OS", release_docs)
        self.assertIn("--version <active-companion-app-store-version>", release_docs)
        self.assertIn("--build-number <yyyymmddHHMM>", release_docs)
        self.assertIn("Mac-to-companion CloudKit dependency", release_docs)
        self.assertIn("CloudKit-backed companion snapshot", release_docs)
        self.assertIn("check --require-production-runtime", release_docs)
        self.assertIn("run that as separate `Ship` dispatches", release_docs)
        self.assertIn("companion widget timeline reads Production CloudKit directly", release_docs)
        self.assertIn("Production CloudKit environment", release_docs)
        self.assertIn("Before launching the companion app", release_docs)
        self.assertIn("Watch app and complication both read Production CloudKit", release_docs)
        self.assertIn("coordinate one Watch-local App Group cache", release_docs)
        self.assertIn("`COMPANION_APP_STORE_TV_PROVISIONING_PROFILE_BASE64`", release_docs)
        self.assertIn("`platform=TV_OS` for tvOS builds", release_docs)
        self.assertIn("`platform: TV_OS`", release_docs)
        self.assertNotIn("issue #174", release_docs)
        self.assertNotIn("Mac-published iCloud companion document", release_docs)
        self.assertNotIn("read-only companion surfaces can sync fresh snapshots", release_docs)
        self.assertNotIn("runtime-baseline.sh install --launch` or", release_docs)
        self.assertNotIn("--version 1.0.32", release_docs)

    def test_runtime_baseline_reports_refresh_agent_bookmark_access(self):
        script = self.read("scripts/context-panel-runtime-baseline.sh")
        refresh_agent = self.read("Sources/ContextPanelRefreshAgent/ContextPanelRefreshAgent.swift")

        self.assertIn("bookmark_access_state()", script)
        self.assertIn("verify_bookmark_access_expectations()", script)
        self.assertIn("--bookmark-access-summary", script)
        self.assertIn("--expect-bookmark-current", script)
        self.assertIn("--expect-bookmark-resolvable", script)
        self.assertIn("privacy-safe bookmark access summary", script)
        self.assertIn('"--bookmark-access-summary"', refresh_agent)
        self.assertIn("SecureFileBookmarkStore", refresh_agent)
        self.assertIn("summary.resolvable", refresh_agent)

    def test_runtime_baseline_rejects_unexpected_bookmark_counts(self):
        command = """
        source scripts/context-panel-runtime-baseline.sh --source-only
        failures=0
        expected_bookmark_current=2
        expected_bookmark_resolvable=2
        verify_bookmark_access_expectations \
          'bookmarks store=readable total=3 current=2 legacy=1 document-scoped=0 invalid=0 resolvable=2'
        [[ "$failures" -gt "0" ]]
        """
        result = subprocess.run(
            ["bash", "-lc", command],
            cwd=REPO_ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("bookmark current count matches expected value 2", result.stdout)
        self.assertIn("bookmark resolvable count matches expected value 2", result.stdout)
        self.assertIn("strict bookmark gate requires total=3 to equal current=2", result.stdout)
        self.assertIn("strict bookmark gate found legacy=1", result.stdout)

    def test_release_docs_do_not_claim_tvos_metadata_is_pending(self):
        release_docs = self.read("docs/release.md")

        self.assertNotIn("still needs its description and screenshots", release_docs)

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
            self.assertTrue(body.lstrip().startswith("guard_installed_runtime_replacement"))
            guard_positions = [match.start() for match in re.finditer("guard_installed_runtime_replacement", body)]
            self.assertGreaterEqual(len(guard_positions), 2)
            self.assertLess(guard_positions[0], body.index("build_checkout_app"))
            self.assertGreater(guard_positions[1], body.index("preflight_built_runtime_profiles"))
            self.assertLess(guard_positions[1], body.index("stop_context_panel"))
            self.assertLess(body.index("preflight_built_runtime_profiles"), body.index("install_checkout_app"))

        install_checkout_app = re.search(r"install_checkout_app\(\) \{(?P<body>.*?)\n\}", script, re.S)
        self.assertIsNotNone(install_checkout_app)
        assert install_checkout_app is not None
        install_body = install_checkout_app.group("body")
        self.assertLess(install_body.index("guard_installed_runtime_replacement"), install_body.index("rsync"))

    def test_runtime_baseline_guard_allows_absent_or_development_runtime(self):
        absent = self.run_runtime_identity_fixture(None)
        development = self.run_runtime_identity_fixture(
            "app-entitlements.plist",
            "app-entitlements.plist",
        )

        self.assertEqual(absent.returncode, 0, absent.stdout)
        self.assertIn("no existing canonical app will be replaced", absent.stdout)
        self.assertEqual(development.returncode, 0, development.stdout)
        self.assertIn("app-cloudkit=Development", development.stdout)
        self.assertIn("existing canonical runtime is verified as Development", development.stdout)

    def test_runtime_baseline_guard_blocks_production_runtime(self):
        result = self.run_runtime_identity_fixture(
            "app-entitlements-production.plist",
            "app-entitlements-production.plist",
        )

        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("app-cloudkit=Production", result.stdout)
        self.assertIn("refusing to replace", result.stdout)
        self.assertIn("check --require-production-runtime", result.stdout)

    def test_runtime_baseline_guard_blocks_production_refresh_agent(self):
        result = self.run_runtime_identity_fixture(
            "app-entitlements.plist",
            "app-entitlements-production.plist",
        )

        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("app-cloudkit=Development", result.stdout)
        self.assertIn("refresh-agent-cloudkit=Production", result.stdout)
        self.assertIn("installed refresh agent uses Production CloudKit", result.stdout)

    def test_runtime_baseline_guard_blocks_testflight_without_embedded_profile(self):
        result = self.run_runtime_identity_fixture(
            "runtime-testflight-entitlements.plist",
            "app-entitlements-production.plist",
        )

        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("distribution=testflight", result.stdout)
        self.assertIn("installed app is a TestFlight runtime", result.stdout)

    def test_runtime_baseline_guard_blocks_store_receipt_even_with_development_entitlements(self):
        result = self.run_runtime_identity_fixture(
            "app-entitlements.plist",
            "app-entitlements.plist",
            receipt=True,
        )

        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("distribution=app-store", result.stdout)
        self.assertIn("installed app has an App Store receipt", result.stdout)

    def test_runtime_baseline_guard_fails_closed_for_unverified_runtime(self):
        result = self.run_runtime_identity_fixture("runtime-unknown-entitlements.plist")

        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("app-cloudkit=unknown", result.stdout)
        self.assertIn("not verified as Development", result.stdout)

    def test_runtime_baseline_production_check_requires_matching_cloudkit_environments(self):
        production = self.run_runtime_identity_fixture(
            "app-entitlements-production.plist",
            "app-entitlements-production.plist",
            operation="production-check",
        )
        development = self.run_runtime_identity_fixture(
            "app-entitlements.plist",
            "app-entitlements.plist",
            operation="production-check",
        )

        self.assertEqual(production.returncode, 0, production.stdout)
        self.assertIn("app uses Production CloudKit", production.stdout)
        self.assertIn("refresh agent uses Production CloudKit", production.stdout)
        self.assertNotEqual(development.returncode, 0, development.stdout)
        self.assertIn("app must use Production CloudKit", development.stdout)
        self.assertIn("refresh agent must use Production CloudKit", development.stdout)

    def test_runtime_baseline_built_preflight_requires_development_cloudkit(self):
        development = self.run_runtime_identity_fixture(
            "app-entitlements.plist",
            "app-entitlements.plist",
            operation="development-check",
        )
        production = self.run_runtime_identity_fixture(
            "app-entitlements-production.plist",
            "app-entitlements-production.plist",
            operation="development-check",
        )

        self.assertEqual(development.returncode, 0, development.stdout)
        self.assertIn("built app uses Development CloudKit", development.stdout)
        self.assertIn("built refresh agent uses Development CloudKit", development.stdout)
        self.assertNotEqual(production.returncode, 0, production.stdout)
        self.assertIn("built app must use Development CloudKit", production.stdout)
        self.assertIn("built refresh agent must use Development CloudKit", production.stdout)

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

    def test_runtime_baseline_discovers_legacy_and_namespaced_companion_caches(self):
        script = self.read("scripts/context-panel-runtime-baseline.sh")
        root_function = re.search(
            r"artifact_cache_companion_build_validation_root\(\) \{(?P<body>.*?)\n\}",
            script,
            re.S,
        )
        self.assertIsNotNone(root_function)
        assert root_function is not None

        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)
            artifact_cache_root = temp_path / "artifact cache"
            legacy_root = (
                artifact_cache_root
                / "derived-data"
                / "companion-build-validation"
            )
            first_namespaced_root = (
                artifact_cache_root
                / "checkouts"
                / "1111111111111111"
                / "derived-data"
                / "companion-build-validation"
            )
            second_namespaced_root = (
                artifact_cache_root
                / "checkouts"
                / "2222222222222222"
                / "derived-data"
                / "companion-build-validation"
            )
            explicit_root = temp_path / "explicit DerivedData"
            for path in (
                legacy_root,
                first_namespaced_root,
                second_namespaced_root,
                explicit_root,
            ):
                path.mkdir(parents=True)

            shell_script = "\n".join(
                [
                    "set -euo pipefail",
                    f"artifact_cache_root={shlex.quote(str(artifact_cache_root))}",
                    f"companion_derived_data_root={shlex.quote(str(explicit_root))}",
                    root_function.group(0),
                    "artifact_cache_companion_build_validation_root",
                ]
            )
            completed = subprocess.run(
                ["/bin/bash", "-c", shell_script],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                check=False,
            )

            self.assertEqual(completed.returncode, 0, completed.stdout)
            discovered_roots = set(completed.stdout.splitlines())
            self.assertTrue(
                {
                    str(explicit_root),
                    str(legacy_root),
                    str(first_namespaced_root),
                    str(second_namespaced_root),
                }.issubset(discovered_roots),
                completed.stdout,
            )

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

    def test_runtime_baseline_profile_fixture_accepts_environment_array_grant(self):
        result = self.run_runtime_preflight_fixture("profile-environment-array.plist")

        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("fixture-app provisioning profile covers signed entitlements", result.stdout)

    def test_runtime_baseline_profile_fixture_rejects_environment_array_without_expected_value(self):
        result = self.run_runtime_preflight_fixture("profile-environment-array-production-only.plist")

        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("does not authorize com.apple.developer.icloud-container-environment", result.stdout)

    def test_runtime_baseline_profile_fixture_rejects_cloudkit_environment_mismatch(self):
        result = self.run_runtime_preflight_fixture(
            "profile-good.plist",
            "app-entitlements-production.plist",
        )

        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("does not authorize com.apple.developer.icloud-container-environment", result.stdout)

    def test_runtime_baseline_profile_fixture_rejects_wildcard_profile(self):
        result = self.run_runtime_preflight_fixture("profile-wildcard.plist")

        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("does not authorize application identifier", result.stdout)


if __name__ == "__main__":
    unittest.main()
