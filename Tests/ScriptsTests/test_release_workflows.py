import base64
import hashlib
import importlib.util
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
from datetime import UTC, datetime, timedelta
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
FIXTURE_SIGNING_CERTIFICATE = b"context-panel-fixture-signing-certificate"
FIXTURE_SIGNING_FINGERPRINT = hashlib.sha1(FIXTURE_SIGNING_CERTIFICATE).hexdigest().upper()


def load_script_module(module_name: str, relative_path: str):
    spec = importlib.util.spec_from_file_location(module_name, REPO_ROOT / relative_path)
    if spec is None or spec.loader is None:
        raise AssertionError(f"could not load script module: {relative_path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


class FakeGitHubReleaseClient:
    def __init__(self) -> None:
        self.tags: dict[str, str] = {}
        self.release: dict[str, object] | None = None
        self.asset_bytes: dict[int, bytes] = {}
        self.create_count = 0
        self.upload_count = 0
        self.publish_count = 0
        self.fail_upload_name = ""
        self.corrupt_upload_name = ""
        self.next_asset_id = 1

    def resolve_tag(self, tag: str) -> str | None:
        return self.tags.get(tag)

    def get_release(self, tag: str) -> dict[str, object] | None:
        if self.release is None or self.release.get("tag_name") != tag:
            return None
        raw_assets = self.release.get("assets", [])
        if not isinstance(raw_assets, list):
            raise TypeError("release assets are malformed")
        return {
            **self.release,
            "assets": [dict(asset) for asset in raw_assets],
        }

    def create_draft(
        self,
        tag: str,
        commit: str,
        title: str,
        notes: str,
        *,
        tag_exists: bool,
    ) -> None:
        self.create_count += 1
        if tag_exists and tag not in self.tags:
            raise AssertionError("tag existence contract was violated")
        self.release = {
            "tag_name": tag,
            "name": title,
            "body": notes,
            "draft": True,
            "target_commitish": commit,
            "assets": [],
        }

    def upload_asset(self, tag: str, path: Path) -> None:
        if path.name == self.fail_upload_name:
            raise RuntimeError(f"simulated upload failure: {path.name}")
        if self.release is None or self.release.get("tag_name") != tag:
            raise AssertionError("release does not exist")
        assets = self.release["assets"]
        assert isinstance(assets, list)
        asset_id = self.next_asset_id
        self.next_asset_id += 1
        content = path.read_bytes()
        if path.name == self.corrupt_upload_name:
            content += b"corrupted"
        assets.append(
            {
                "id": asset_id,
                "name": path.name,
                "size": len(content),
                "state": "uploaded",
            }
        )
        self.asset_bytes[asset_id] = content
        self.upload_count += 1

    def download_asset(self, asset_id: int) -> bytes:
        return self.asset_bytes[asset_id]

    def delete_asset(self, asset_id: int) -> None:
        if self.release is None:
            raise AssertionError("release does not exist")
        assets = self.release["assets"]
        assert isinstance(assets, list)
        self.release["assets"] = [asset for asset in assets if asset["id"] != asset_id]
        self.asset_bytes.pop(asset_id, None)

    def publish_draft(self, tag: str) -> None:
        if self.release is None or self.release.get("tag_name") != tag:
            raise AssertionError("release does not exist")
        target = self.release.get("target_commitish")
        if not isinstance(target, str):
            raise AssertionError("release target is missing")
        self.tags.setdefault(tag, target)
        self.release["draft"] = False
        self.publish_count += 1


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
        stripped = line.strip().removeprefix("- ")
        if not stripped.startswith("run:"):
            continue
        inline = stripped.removeprefix("run:").strip()
        if inline not in {"|", "|-", ">", ">-"}:
            blocks.append(inline)
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


class ReleaseWorkflowTests(unittest.TestCase):
    def read(self, relative_path: str) -> str:
        return (REPO_ROOT / relative_path).read_text()

    def cloudkit_schema_receipt_module(self):
        return load_script_module(
            "context_panel_cloudkit_schema_receipt",
            "scripts/cloudkit-schema-receipt.py",
        )

    def github_release_fixture(self, root: Path):
        publisher = load_script_module(
            "context_panel_publish_github_release",
            "scripts/publish-github-release.py",
        )
        sealer = load_script_module(
            "context_panel_seal_github_release_metadata",
            "scripts/seal-github-release-metadata.py",
        )
        tag = "v1.2.3"
        version = "1.2.3"
        build_number = "42"
        source_commit = "a" * 40
        zip_path = root / "ContextPanel-1.2.3-macOS.zip"
        metadata_path = root / "release-metadata.json"
        zip_path.write_bytes(b"signed release zip")
        metadata_path.write_text(
            json.dumps(
                {
                    "version": version,
                    "buildNumber": build_number,
                    "signingIdentity": "-",
                    "notarized": False,
                }
            )
            + "\n"
        )
        sealer.seal_metadata(
            metadata_path,
            tag=tag,
            source_commit=source_commit,
            version=version,
            build_number=build_number,
            asset_paths=[zip_path],
        )
        identity = publisher.build_release_identity(
            tag=tag,
            source_commit=source_commit,
            version=version,
            build_number=build_number,
            metadata_path=metadata_path,
            asset_paths=[zip_path],
        )
        return publisher, identity, zip_path, metadata_path

    def seed_fake_release(
        self,
        client: FakeGitHubReleaseClient,
        publisher,
        identity,
        *,
        draft: bool,
        marker_identity=None,
        content_overrides: dict[str, bytes] | None = None,
    ) -> None:
        if not draft:
            client.tags[identity.tag] = identity.source_commit
        client.release = {
            "tag_name": identity.tag,
            "name": f"Context Panel {identity.version}",
            "body": publisher.render_notes("release notes", marker_identity or identity),
            "draft": draft,
            "target_commitish": identity.source_commit,
            "assets": [],
        }
        overrides = content_overrides or {}
        assets = client.release["assets"]
        assert isinstance(assets, list)
        for asset in identity.assets:
            asset_id = client.next_asset_id
            client.next_asset_id += 1
            content = overrides.get(asset.name, asset.path.read_bytes())
            assets.append(
                {
                    "id": asset_id,
                    "name": asset.name,
                    "size": len(content),
                    "state": "uploaded",
                }
            )
            client.asset_bytes[asset_id] = content

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

    def run_runtime_replacement_trace(
        self,
        entry_point: str,
        *,
        production_after: str | None,
    ) -> tuple[subprocess.CompletedProcess[str], list[str]]:
        """Run install/reset with every non-guard function traced instead of executed.

        The installed fixture runtime reports Production CloudKit from the start when
        production_after is None, or only once the named step has run.
        """
        fixture_dir = REPO_ROOT / "Tests/ScriptsTests/fixtures/runtime-preflight"
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            app = root / "Applications/Context Panel.app"
            (app / "Contents/Library/LoginItems/ContextPanelRefreshAgent.app").mkdir(parents=True)
            built_app = root / "Build/Context Panel.app"
            built_app.mkdir(parents=True)
            trace = root / "trace"
            trace.touch()
            flipped = root / "flipped"
            if production_after is None:
                flipped.touch()
            command = f"""
            export HOME={shlex.quote(str(root / 'home'))}
            mkdir -p "$HOME"
            source {shlex.quote(str(REPO_ROOT / 'scripts/context-panel-runtime-baseline.sh'))} --source-only
            app_path={shlex.quote(str(app))}
            widget_path="$app_path/Contents/PlugIns/ContextPanelWidgetExtension.appex"
            refresh_agent_path="$app_path/Contents/Library/LoginItems/ContextPanelRefreshAgent.app"
            built_app_path={shlex.quote(str(built_app))}
            lsregister=traced_lsregister
            trace={shlex.quote(str(trace))}
            flipped={shlex.quote(str(flipped))}
            production_after={shlex.quote(production_after or '')}
            keep=" {entry_point} guard_installed_runtime_replacement bundle_cloudkit_environment \
bundle_beta_reports_active bundle_store_receipt_status runtime_distribution_identity \
signed_entitlement_value plist_scalar_value section ok note fail "
            for name in $(declare -F | awk '{{print $3}}') \
                traced_lsregister rsync ditto codesign open pluginkit launchctl pkill killall sleep; do
              [[ "$keep" == *" $name "* ]] && continue
              eval "$name() {{ trace_step $name; }}"
            done
            trace_step() {{
              echo "$1" >>"$trace"
              if [[ "$1" == "$production_after" ]]; then touch "$flipped"; fi
            }}
            signed_entitlements_plist() {{
              if [[ -e "$flipped" ]]; then
                cp {shlex.quote(str(fixture_dir / 'app-entitlements-production.plist'))} "$2"
              else
                cp {shlex.quote(str(fixture_dir / 'app-entitlements.plist'))} "$2"
              fi
            }}
            set +e
            ( set -e; {entry_point} )
            exit $?
            """
            result = subprocess.run(
                ["bash", "-c", command],
                cwd=REPO_ROOT,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                check=False,
            )
            return result, trace.read_text().split()

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
        receipt_output: Path | None = None,
        receipt_key: str | None = None,
        source_commit: str = "a" * 40,
        fail_export: bool = False,
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
if [[ "${FAKE_CKTOOL_FAIL:-}" == "1" ]]; then
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
            if receipt_key is not None:
                env["CONTEXT_PANEL_CLOUDKIT_SCHEMA_RECEIPT_KEY"] = receipt_key
            if fail_export:
                env["FAKE_CKTOOL_FAIL"] = "1"
            receipt_args: list[str] = []
            if receipt_output is not None:
                receipt_args = [
                    "--receipt-output",
                    str(receipt_output),
                    "--source-commit",
                    source_commit,
                ]
            return subprocess.run(
                [
                    "/bin/bash",
                    str(REPO_ROOT / "scripts/validate-cloudkit-companion-schema.sh"),
                    "--live",
                    "--environment",
                    "production",
                ]
                + checked_in_schema_args
                + receipt_args,
                cwd=REPO_ROOT,
                env=env,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                check=False,
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

    def test_live_release_mutations_verify_production_cloudkit_schema_receipt(self):
        workflows = (
            (
                ".github/workflows/release.yml",
                "macos",
                "if: ${{ inputs.create_github_release }}",
                "      - name: Publish GitHub Release",
            ),
            (
                ".github/workflows/app-store-connect-upload.yml",
                "upload",
                "if: ${{ inputs.upload }}",
                "      - name: Archive and Upload",
            ),
            (
                ".github/workflows/app-store-connect-companion-upload.yml",
                "upload",
                "if: ${{ inputs.upload }}",
                "      - name: Archive and Upload",
            ),
            (
                ".github/workflows/testflight-beta-distribution.yml",
                "distribute",
                "if: ${{ !inputs.dry_run }}",
                "      - name: Distribute Beta",
            ),
            (
                ".github/workflows/submit-app-store-review.yml",
                "submit",
                "if: ${{ !inputs.dry_run && !inputs.cancel_review_only }}",
                "      - name: Submit Review",
            ),
        )

        for workflow_path, job_name, condition, mutation_step in workflows:
            with self.subTest(workflow=workflow_path):
                workflow = self.read(workflow_path)
                job = workflow_job(workflow, job_name)
                guard = workflow_job(workflow, "guard")
                self.assertIn("cloudkit_schema_receipt_base64:", workflow)
                self.assertIn("environment: release", job)
                self.assertIn(
                    "      - name: Verify Production CloudKit Schema Receipt",
                    job,
                )
                self.assertIn(condition, job)
                self.assertIn(
                    "secrets.CONTEXT_PANEL_CLOUDKIT_SCHEMA_RECEIPT_KEY",
                    job,
                )
                self.assertIn(
                    "--receipt-base64-env CONTEXT_PANEL_CLOUDKIT_SCHEMA_RECEIPT_BASE64",
                    job,
                )
                self.assertLess(
                    job.index("Verify Production CloudKit Schema Receipt"),
                    job.index(mutation_step),
                )
                self.assertNotIn("CONTEXT_PANEL_CLOUDKIT_SCHEMA_RECEIPT_KEY", guard)

    def test_workflow_shell_blocks_do_not_expand_actions_expressions(self):
        workflow_paths = sorted((REPO_ROOT / ".github/workflows").glob("*.yml"))
        self.assertTrue(workflow_paths)

        for workflow_path in workflow_paths:
            with self.subTest(workflow=workflow_path.name):
                for run_block in workflow_run_blocks(workflow_path.read_text()):
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

    def test_release_metadata_seal_records_source_and_payload_digest(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            _, identity, zip_path, metadata_path = self.github_release_fixture(root)
            metadata = json.loads(metadata_path.read_text())

            self.assertEqual(
                metadata["releaseIdentity"],
                {
                    "schemaVersion": 1,
                    "tag": identity.tag,
                    "sourceCommit": identity.source_commit,
                    "version": identity.version,
                    "buildNumber": identity.build_number,
                    "assets": [
                        {
                            "name": zip_path.name,
                            "sha256": hashlib.sha256(zip_path.read_bytes()).hexdigest(),
                            "size": zip_path.stat().st_size,
                        }
                    ],
                },
            )

    def test_github_release_publication_is_idempotent(self):
        with tempfile.TemporaryDirectory() as directory:
            publisher, identity, _, _ = self.github_release_fixture(Path(directory))
            client = FakeGitHubReleaseClient()

            first_result = publisher.publish_release(
                client,
                identity,
                title=f"Context Panel {identity.version}",
                notes="release notes",
            )
            self.assertEqual(first_result, "published")
            self.assertEqual(client.create_count, 1)
            self.assertEqual(client.upload_count, 2)
            self.assertEqual(client.publish_count, 1)
            self.assertIsNotNone(client.release)
            assert client.release is not None
            self.assertIs(client.release["draft"], False)

            second_result = publisher.publish_release(
                client,
                identity,
                title=f"Context Panel {identity.version}",
                notes="changed human notes do not rewrite identity",
            )
            self.assertEqual(second_result, "already-published")
            self.assertEqual(client.create_count, 1)
            self.assertEqual(client.upload_count, 2)
            self.assertEqual(client.publish_count, 1)

    def test_github_release_publication_rejects_mismatched_tag(self):
        with tempfile.TemporaryDirectory() as directory:
            publisher, identity, _, _ = self.github_release_fixture(Path(directory))
            client = FakeGitHubReleaseClient()
            client.tags[identity.tag] = "b" * 40

            with self.assertRaisesRegex(
                publisher.PublicationError,
                "resolves to",
            ):
                publisher.publish_release(
                    client,
                    identity,
                    title=f"Context Panel {identity.version}",
                    notes="release notes",
                )
            self.assertIsNone(client.release)

    def test_github_release_publication_rejects_mismatched_build_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            publisher, identity, _, _ = self.github_release_fixture(Path(directory))
            client = FakeGitHubReleaseClient()
            mismatched_identity = publisher.ReleaseIdentity(
                tag=identity.tag,
                source_commit=identity.source_commit,
                version=identity.version,
                build_number="43",
                assets=identity.assets,
            )
            self.seed_fake_release(
                client,
                publisher,
                identity,
                draft=False,
                marker_identity=mismatched_identity,
            )

            with self.assertRaisesRegex(
                publisher.PublicationError,
                "identity does not match",
            ):
                publisher.publish_release(
                    client,
                    identity,
                    title=f"Context Panel {identity.version}",
                    notes="release notes",
                )

    def test_github_release_publication_rejects_changed_asset_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            publisher, identity, zip_path, _ = self.github_release_fixture(Path(directory))
            client = FakeGitHubReleaseClient()
            self.seed_fake_release(
                client,
                publisher,
                identity,
                draft=False,
                content_overrides={zip_path.name: b"different release bytes"},
            )

            with self.assertRaisesRegex(
                publisher.PublicationError,
                "asset bytes do not match",
            ):
                publisher.publish_release(
                    client,
                    identity,
                    title=f"Context Panel {identity.version}",
                    notes="release notes",
                )

    def test_github_release_partial_upload_stays_draft_until_retry(self):
        with tempfile.TemporaryDirectory() as directory:
            publisher, identity, _, metadata_path = self.github_release_fixture(
                Path(directory)
            )
            client = FakeGitHubReleaseClient()
            client.fail_upload_name = metadata_path.name

            with self.assertRaisesRegex(RuntimeError, "simulated upload failure"):
                publisher.publish_release(
                    client,
                    identity,
                    title=f"Context Panel {identity.version}",
                    notes="release notes",
                )
            self.assertIsNotNone(client.release)
            assert client.release is not None
            self.assertIs(client.release["draft"], True)
            self.assertEqual(client.publish_count, 0)
            self.assertEqual(client.upload_count, 1)

            client.fail_upload_name = ""
            result = publisher.publish_release(
                client,
                identity,
                title=f"Context Panel {identity.version}",
                notes="release notes",
            )
            self.assertEqual(result, "published")
            self.assertIs(client.release["draft"], False)
            self.assertEqual(client.upload_count, 2)
            self.assertEqual(client.publish_count, 1)

    def test_github_release_remote_verification_failure_keeps_draft(self):
        with tempfile.TemporaryDirectory() as directory:
            publisher, identity, zip_path, _ = self.github_release_fixture(
                Path(directory)
            )
            client = FakeGitHubReleaseClient()
            client.corrupt_upload_name = zip_path.name

            with self.assertRaisesRegex(
                publisher.PublicationError,
                "asset bytes do not match",
            ):
                publisher.publish_release(
                    client,
                    identity,
                    title=f"Context Panel {identity.version}",
                    notes="release notes",
                )
            self.assertIsNotNone(client.release)
            assert client.release is not None
            self.assertIs(client.release["draft"], True)
            self.assertEqual(client.publish_count, 0)

            client.corrupt_upload_name = ""
            result = publisher.publish_release(
                client,
                identity,
                title=f"Context Panel {identity.version}",
                notes="release notes",
            )
            self.assertEqual(result, "published")
            self.assertIs(client.release["draft"], False)
            self.assertEqual(client.publish_count, 1)

    def test_github_release_draft_lookup_falls_back_to_release_listing(self):
        publisher = load_script_module(
            "context_panel_publish_github_release_draft_lookup",
            "scripts/publish-github-release.py",
        )
        draft = {
            "tag_name": "v1.2.3",
            "draft": True,
            "target_commitish": "a" * 40,
            "body": "draft",
            "assets": [],
        }

        class DraftLookupClient(publisher.GitHubCLIClient):
            def _api_json(self, endpoint, *, allow_not_found=False):
                return None

            def _api_pages(self, endpoint):
                return [draft]

        client = DraftLookupClient("cbusillo/context-panel")
        self.assertEqual(client.get_release("v1.2.3"), draft)

    def test_github_release_rejects_tagless_published_release(self):
        with tempfile.TemporaryDirectory() as directory:
            publisher, identity, _, _ = self.github_release_fixture(Path(directory))
            client = FakeGitHubReleaseClient()
            self.seed_fake_release(
                client,
                publisher,
                identity,
                draft=False,
            )
            client.tags.clear()

            with self.assertRaisesRegex(
                publisher.PublicationError,
                "published GitHub Release has no matching tag",
            ):
                publisher.publish_release(
                    client,
                    identity,
                    title=f"Context Panel {identity.version}",
                    notes="release notes",
                )

    def run_ship_validate_inputs(
        self,
        guard_exit: int = 0,
        **overrides: str,
    ) -> tuple[subprocess.CompletedProcess[str], list[list[str]], str]:
        """Run scripts/ship-validate-inputs.sh with a recording python3 stub as the version guard."""
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            stub_dir = root / "bin"
            stub_dir.mkdir()
            guard_log = root / "guard.log"
            stub = stub_dir / "python3"
            stub.write_text(
                "#!/bin/sh\n"
                f"printf '%s\\n' \"$*\" >>{shlex.quote(str(guard_log))}\n"
                f"exit {guard_exit}\n"
            )
            stub.chmod(0o755)
            output = root / "output"
            environment = {
                "PATH": f"{stub_dir}:/usr/bin:/bin",
                "GITHUB_OUTPUT": str(output),
                "GITHUB_STEP_SUMMARY": str(root / "summary"),
                "GITHUB_SHA": "0" * 40,
                "INPUT_VERSION": "9.9.9",
                "INPUT_BUILD_NUMBER": "202601010000",
                "INPUT_GITHUB_RELEASE": "false",
                "INPUT_NOTARIZE_GITHUB_RELEASE": "false",
                "INPUT_APP_STORE_CHANNEL": "skip",
                "INPUT_COMPANION_APP_STORE_CHANNEL": "skip",
                "INPUT_COMPANION_PLATFORM": "ios",
                "INPUT_TESTFLIGHT_BETA": "false",
                "INPUT_TESTFLIGHT_BETA_SOURCE": "companion",
                "INPUT_TESTFLIGHT_BETA_GROUPS": "",
                "INPUT_INCLUDE_INTERNAL_TESTFLIGHT_GROUPS": "false",
                "INPUT_CLOUDKIT_SCHEMA_RECEIPT_BASE64": "cmVjZWlwdA==",
                "APP_STORE_CONNECT_KEY_ID": "key",
                "APP_STORE_CONNECT_ISSUER_ID": "issuer",
                "APP_STORE_CONNECT_API_KEY_P8_BASE64": "cDg=",
            }
            environment.update(overrides)
            result = subprocess.run(
                [str(REPO_ROOT / "scripts/ship-validate-inputs.sh")],
                env=environment,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                check=False,
            )
            guard_calls = [line.split() for line in guard_log.read_text().splitlines()] if guard_log.exists() else []
            return result, guard_calls, output.read_text() if output.exists() else ""

    @staticmethod
    def guard_platform(call: list[str]) -> str:
        return call[call.index("--platform") + 1]

    def test_ship_preflights_every_companion_platform_the_workflow_offers(self):
        workflow = self.read(".github/workflows/ship.yml")
        platforms = {}
        for option in workflow_choice_options(workflow, "companion_platform"):
            with self.subTest(companion_platform=option):
                result, guard_calls, output = self.run_ship_validate_inputs(
                    INPUT_COMPANION_APP_STORE_CHANNEL="upload",
                    INPUT_COMPANION_PLATFORM=option,
                )

                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertEqual(len(guard_calls), 1)
                self.assertIn("9.9.9", guard_calls[0])
                platforms[option] = self.guard_platform(guard_calls[0])
                self.assertIn("build_number=202601010000", output)

        self.assertEqual(len(set(platforms.values())), len(platforms), platforms)
        self.assertNotIn("MAC_OS", platforms.values())

    def test_ship_rejects_an_unknown_companion_platform_without_preflight(self):
        result, guard_calls, output = self.run_ship_validate_inputs(
            INPUT_COMPANION_APP_STORE_CHANNEL="upload",
            INPUT_COMPANION_PLATFORM="watchos",
        )

        self.assertEqual(result.returncode, 2, result.stdout)
        self.assertIn("unsupported companion_platform", result.stdout)
        self.assertEqual(guard_calls, [])
        self.assertEqual(output, "")

    def test_ship_preflights_the_mac_app_store_channel(self):
        result, guard_calls, _ = self.run_ship_validate_inputs(INPUT_APP_STORE_CHANNEL="upload")

        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual([self.guard_platform(call) for call in guard_calls], ["MAC_OS"])

    def test_ship_stops_when_the_version_guard_rejects_the_version(self):
        result, guard_calls, output = self.run_ship_validate_inputs(
            guard_exit=3,
            INPUT_APP_STORE_CHANNEL="upload",
        )

        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(len(guard_calls), 1)
        self.assertEqual(output, "")

    def test_ship_refuses_live_channels_without_required_inputs(self):
        cases = {
            "no channel": {},
            "no schema receipt": {
                "INPUT_GITHUB_RELEASE": "true",
                "INPUT_CLOUDKIT_SCHEMA_RECEIPT_BASE64": "",
            },
            "no App Store Connect credentials": {
                "INPUT_APP_STORE_CHANNEL": "upload",
                "APP_STORE_CONNECT_API_KEY_P8_BASE64": "",
            },
            "TestFlight source without its upload": {
                "INPUT_GITHUB_RELEASE": "true",
                "INPUT_TESTFLIGHT_BETA": "true",
                "INPUT_TESTFLIGHT_BETA_SOURCE": "macos",
            },
            "closed version": {"INPUT_GITHUB_RELEASE": "true", "INPUT_VERSION": "1.0"},
        }
        for name, overrides in cases.items():
            with self.subTest(name):
                result, guard_calls, output = self.run_ship_validate_inputs(**overrides)

                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertEqual(guard_calls, [])
                self.assertEqual(output, "")

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
                    ".build/release-evidence-policy-archive.json",
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
                        "INPUT_RELEASE_EVIDENCE_HISTORICAL_POLICY_ARCHIVE_BASE64": "present",
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
                self.assertIn("--release-evidence-historical-policy-archive", arguments)

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

    def test_cloudkit_schema_receipt_round_trip_binds_contract_and_source(self):
        receipt_module = self.cloudkit_schema_receipt_module()
        key = b"cloudkit-schema-receipt-test-key-32-bytes"
        source_commit = "a" * 40
        now = datetime(2026, 8, 31, 12, 0, tzinfo=UTC)

        receipt = receipt_module.issue_receipt(
            environment="production",
            container_identifier="iCloud.com.shinycomputers.contextpanel",
            schema_path=REPO_ROOT / "CloudKit/companion-sync.schema.json",
            cktool_schema_path=REPO_ROOT / "CloudKit/companion-sync.schema.ckdb",
            source_commit=source_commit,
            ttl_seconds=3600,
            key=key,
            now=now,
        )

        receipt_module.verify_receipt(
            receipt,
            environment="production",
            container_identifier="iCloud.com.shinycomputers.contextpanel",
            schema_path=REPO_ROOT / "CloudKit/companion-sync.schema.json",
            cktool_schema_path=REPO_ROOT / "CloudKit/companion-sync.schema.ckdb",
            source_commit=source_commit,
            key=key,
            now=now + timedelta(minutes=1),
        )
        serialized = json.dumps(receipt)
        self.assertNotIn(key.decode(), serialized)
        self.assertNotIn("recordName", serialized)
        self.assertEqual(receipt["environment"], "production")
        self.assertEqual(
            receipt["containerIdentifier"],
            "iCloud.com.shinycomputers.contextpanel",
        )
        self.assertEqual(receipt["sourceCommit"], source_commit)
        self.assertRegex(str(receipt["contractDigest"]), r"^sha256:[0-9a-f]{64}$")

    def test_cloudkit_schema_receipt_rejects_tampering_and_identity_drift(self):
        receipt_module = self.cloudkit_schema_receipt_module()
        key = b"cloudkit-schema-receipt-test-key-32-bytes"
        source_commit = "a" * 40
        now = datetime(2026, 8, 31, 12, 0, tzinfo=UTC)
        receipt = receipt_module.issue_receipt(
            environment="production",
            container_identifier="iCloud.com.shinycomputers.contextpanel",
            schema_path=REPO_ROOT / "CloudKit/companion-sync.schema.json",
            cktool_schema_path=REPO_ROOT / "CloudKit/companion-sync.schema.ckdb",
            source_commit=source_commit,
            ttl_seconds=3600,
            key=key,
            now=now,
        )

        tampered = dict(receipt)
        tampered["seal"] = "hmac-sha256:" + "0" * 64
        with self.assertRaisesRegex(receipt_module.ReceiptError, "seal is invalid"):
            receipt_module.verify_receipt(
                tampered,
                environment="production",
                container_identifier="iCloud.com.shinycomputers.contextpanel",
                schema_path=REPO_ROOT / "CloudKit/companion-sync.schema.json",
                cktool_schema_path=REPO_ROOT / "CloudKit/companion-sync.schema.ckdb",
                source_commit=source_commit,
                key=key,
                now=now,
            )
        with self.assertRaisesRegex(receipt_module.ReceiptError, "source commit"):
            receipt_module.verify_receipt(
                receipt,
                environment="production",
                container_identifier="iCloud.com.shinycomputers.contextpanel",
                schema_path=REPO_ROOT / "CloudKit/companion-sync.schema.json",
                cktool_schema_path=REPO_ROOT / "CloudKit/companion-sync.schema.ckdb",
                source_commit="b" * 40,
                key=key,
                now=now,
            )
        with tempfile.TemporaryDirectory() as temp_dir:
            changed_contract = Path(temp_dir) / "companion-sync.schema.ckdb"
            changed_contract.write_text(
                self.read("CloudKit/companion-sync.schema.ckdb") + "\n// drift\n"
            )
            with self.assertRaisesRegex(receipt_module.ReceiptError, "contract digest"):
                receipt_module.verify_receipt(
                    receipt,
                    environment="production",
                    container_identifier="iCloud.com.shinycomputers.contextpanel",
                    schema_path=REPO_ROOT / "CloudKit/companion-sync.schema.json",
                    cktool_schema_path=changed_contract,
                    source_commit=source_commit,
                    key=key,
                    now=now,
                )

    def test_cloudkit_schema_receipt_rejects_stale_future_and_unknown_fields(self):
        receipt_module = self.cloudkit_schema_receipt_module()
        key = b"cloudkit-schema-receipt-test-key-32-bytes"
        source_commit = "a" * 40
        now = datetime(2026, 8, 31, 12, 0, tzinfo=UTC)
        receipt = receipt_module.issue_receipt(
            environment="production",
            container_identifier="iCloud.com.shinycomputers.contextpanel",
            schema_path=REPO_ROOT / "CloudKit/companion-sync.schema.json",
            cktool_schema_path=REPO_ROOT / "CloudKit/companion-sync.schema.ckdb",
            source_commit=source_commit,
            ttl_seconds=300,
            key=key,
            now=now,
        )
        verification = {
            "environment": "production",
            "container_identifier": "iCloud.com.shinycomputers.contextpanel",
            "schema_path": REPO_ROOT / "CloudKit/companion-sync.schema.json",
            "cktool_schema_path": REPO_ROOT / "CloudKit/companion-sync.schema.ckdb",
            "source_commit": source_commit,
            "key": key,
        }

        with self.assertRaisesRegex(receipt_module.ReceiptError, "expired"):
            receipt_module.verify_receipt(
                receipt,
                **verification,
                now=now + timedelta(minutes=5),
            )
        future = receipt_module.issue_receipt(
            **verification,
            ttl_seconds=300,
            now=now + timedelta(minutes=6),
        )
        with self.assertRaisesRegex(receipt_module.ReceiptError, "in the future"):
            receipt_module.verify_receipt(future, **verification, now=now)
        unknown = dict(receipt)
        unknown["unexpected"] = True
        with self.assertRaisesRegex(receipt_module.ReceiptError, "fields"):
            receipt_module.verify_receipt(unknown, **verification, now=now)
        missing = dict(receipt)
        del missing["contractDigest"]
        with self.assertRaisesRegex(receipt_module.ReceiptError, "fields"):
            receipt_module.verify_receipt(missing, **verification, now=now)

    def test_cloudkit_schema_receipt_cli_rejects_missing_and_invalid_base64(self):
        environment = os.environ.copy()
        environment["CONTEXT_PANEL_CLOUDKIT_SCHEMA_RECEIPT_KEY"] = (
            "cloudkit-schema-receipt-test-key-32-bytes"
        )
        command = [
            "python3",
            str(REPO_ROOT / "scripts/cloudkit-schema-receipt.py"),
            "verify",
            "--receipt-base64-env",
            "TEST_SCHEMA_RECEIPT_BASE64",
            "--source-commit",
            "a" * 40,
        ]

        missing = subprocess.run(
            command,
            cwd=REPO_ROOT,
            env=environment,
            text=True,
            capture_output=True,
            check=False,
        )
        environment["TEST_SCHEMA_RECEIPT_BASE64"] = "not base64!"
        invalid = subprocess.run(
            command,
            cwd=REPO_ROOT,
            env=environment,
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertEqual(missing.returncode, 1)
        self.assertIn("receipt input is required", missing.stderr)
        self.assertEqual(invalid.returncode, 1)
        self.assertIn("receipt base64 is invalid", invalid.stderr)

    def test_cloudkit_schema_receipt_accepts_wrapped_base64_transport(self):
        receipt_module = self.cloudkit_schema_receipt_module()
        key = b"cloudkit-schema-receipt-test-key-32-bytes"
        source_commit = "a" * 40
        receipt = receipt_module.issue_receipt(
            environment="production",
            container_identifier="iCloud.com.shinycomputers.contextpanel",
            schema_path=REPO_ROOT / "CloudKit/companion-sync.schema.json",
            cktool_schema_path=REPO_ROOT / "CloudKit/companion-sync.schema.ckdb",
            source_commit=source_commit,
            ttl_seconds=3600,
            key=key,
        )
        encoded = base64.b64encode(json.dumps(receipt).encode()).decode()
        wrapped = "\r\n".join(
            encoded[index : index + 32] for index in range(0, len(encoded), 32)
        )
        environment = os.environ.copy()
        environment["CONTEXT_PANEL_CLOUDKIT_SCHEMA_RECEIPT_KEY"] = key.decode()
        environment["TEST_SCHEMA_RECEIPT_BASE64"] = wrapped

        result = subprocess.run(
            [
                "python3",
                str(REPO_ROOT / "scripts/cloudkit-schema-receipt.py"),
                "verify",
                "--receipt-base64-env",
                "TEST_SCHEMA_RECEIPT_BASE64",
                "--source-commit",
                source_commit,
            ],
            cwd=REPO_ROOT,
            env=environment,
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_live_cloudkit_schema_gate_issues_receipt_and_fails_closed(self):
        key = "cloudkit-schema-receipt-test-key-32-bytes"
        with tempfile.TemporaryDirectory() as temp_dir:
            receipt_path = Path(temp_dir) / "schema-receipt.json"
            success = self.run_cloudkit_schema_validator_with_fake_cktool(
                self.read("CloudKit/companion-sync.schema.ckdb"),
                receipt_output=receipt_path,
                receipt_key=key,
            )
            receipt = json.loads(receipt_path.read_text())

            self.assertEqual(success.returncode, 0, success.stdout)
            self.assertEqual(receipt["sourceCommit"], "a" * 40)
            self.assertNotIn(key, receipt_path.read_text())

            failed_receipt_path = Path(temp_dir) / "failed-receipt.json"
            failure = self.run_cloudkit_schema_validator_with_fake_cktool(
                self.read("CloudKit/companion-sync.schema.ckdb"),
                receipt_output=failed_receipt_path,
                receipt_key=key,
                fail_export=True,
            )

            self.assertEqual(failure.returncode, 1, failure.stdout)
            self.assertIn("live schema validation failed", failure.stdout)
            self.assertFalse(failed_receipt_path.exists())

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

    def test_runtime_baseline_install_and_reset_do_nothing_when_production_is_installed(self):
        for entry_point in ("install_runtime", "reset_runtime"):
            with self.subTest(entry_point=entry_point):
                result, steps = self.run_runtime_replacement_trace(entry_point, production_after=None)

                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn("refusing to replace", result.stdout)
                self.assertEqual(steps, [])

    def test_runtime_baseline_install_and_reset_recheck_the_guard_after_building(self):
        for entry_point in ("install_runtime", "reset_runtime"):
            with self.subTest(entry_point=entry_point):
                result, steps = self.run_runtime_replacement_trace(
                    entry_point,
                    production_after="preflight_built_runtime_profiles",
                )

                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn("refusing to replace", result.stdout)
                self.assertEqual(steps, ["build_checkout_app", "preflight_built_runtime_profiles"])

    def test_runtime_baseline_install_copy_rechecks_the_guard_before_writing(self):
        result, steps = self.run_runtime_replacement_trace("install_checkout_app", production_after=None)

        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("refusing to replace", result.stdout)
        self.assertEqual(steps, [])

    def test_runtime_baseline_install_proceeds_for_a_development_runtime(self):
        result, steps = self.run_runtime_replacement_trace("install_runtime", production_after="never")

        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertLess(steps.index("preflight_built_runtime_profiles"), steps.index("stop_context_panel"))
        self.assertLess(steps.index("stop_context_panel"), steps.index("install_checkout_app"))

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
