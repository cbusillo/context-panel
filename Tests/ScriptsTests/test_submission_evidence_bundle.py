import contextlib
import hashlib
import importlib.util
import io
import json
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[2] / "scripts" / "submission-evidence-bundle.py"
SPEC = importlib.util.spec_from_file_location("submission_evidence_bundle", MODULE_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"Unable to load {MODULE_PATH}")
bundle_tool = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bundle_tool)


class SubmissionEvidenceBundleTests(unittest.TestCase):
    def setUp(self) -> None:
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        # Odd spacing and key order: unpacking must return the exact file text.
        self.sources = {
            "validation-report": '{"z": 1,  "a": [1, 2]}\n',
            "release-evidence": '{\n  "ledgerID": "ledger"\n}',
            "comparison": '{\r\n  "comparison": true\r\n}\r\n',
            "rc-lineage": '{"selectedRCLedger": {"b": 2, "a": 1}}\n',
            "manifest-macos": '{"layout": "macos"}\n',
            "manifest-ios": '{"layout":"ios"}',
        }
        for name, text in self.sources.items():
            (self.root / f"{name}.json").write_bytes(text.encode())

    @staticmethod
    def run_tool(*arguments: str) -> tuple[int, str, str]:
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            code = bundle_tool.main(list(arguments))
        return code, stdout.getvalue(), stderr.getvalue()

    def create(self, version: str = "1.0.74", build_number: str = "202610180601") -> tuple[Path, str]:
        output = self.root / "submission-evidence.json"
        code, stdout, stderr = self.run_tool(
            "create", "--version", version, "--build-number", build_number,
            "--validation-report", str(self.root / "validation-report.json"),
            "--release-evidence-report", str(self.root / "release-evidence.json"),
            "--comparison", str(self.root / "comparison.json"),
            "--expected-build-manifest", str(self.root / "manifest-macos.json"),
            "--expected-build-manifest", str(self.root / "manifest-ios.json"),
            "--selected-rc-ledger", str(self.root / "rc-lineage.json"),
            "--output", str(output),
        )
        self.assertEqual(code, 0, stderr)
        self.assertIn(f"branch: release-evidence/{version}-{build_number}", stdout)
        return output, hashlib.sha256(output.read_bytes()).hexdigest()

    def extract(self, bundle: Path, digest: str, version: str = "1.0.74",
                build_number: str = "202610180601") -> tuple[int, list[str], str]:
        code, stdout, stderr = self.run_tool(
            "extract", "--bundle", str(bundle), "--sha256", digest,
            "--version", version, "--build-number", build_number,
            "--output-dir", str(self.root / "out"),
        )
        return code, stdout.splitlines(), stderr

    @staticmethod
    def flag_values(arguments: list[str], flag: str) -> list[str]:
        return [arguments[index + 1] for index, value in enumerate(arguments) if value == flag]

    def test_round_trip_returns_exact_files_as_submission_arguments(self) -> None:
        bundle, digest = self.create()
        code, arguments, stderr = self.extract(bundle, digest)
        self.assertEqual(code, 0, stderr)

        expected = {
            "--validation-report": ["validation-report"],
            "--release-evidence-report": ["release-evidence"],
            "--release-evidence-comparison": ["comparison"],
            "--release-evidence-selected-rc-ledger": ["rc-lineage"],
            "--release-evidence-expected-build-manifest": ["manifest-macos", "manifest-ios"],
        }
        for flag, names in expected.items():
            with self.subTest(flag=flag):
                paths = self.flag_values(arguments, flag)
                self.assertEqual(
                    [Path(path).read_bytes() for path in paths],
                    [self.sources[name].encode() for name in names],
                )
        self.assertEqual(self.flag_values(arguments, "--release-evidence-previous-ledger"), [])

    def test_large_bundle_round_trips(self) -> None:
        # A full release's lineage is far beyond the 65,535-character input cap.
        large = json.dumps({"entries": ["f" * 64] * 20000})
        (self.root / "rc-lineage.json").write_text(large)
        bundle, digest = self.create()
        self.assertGreater(bundle.stat().st_size, 1_000_000)
        code, arguments, stderr = self.extract(bundle, digest)
        self.assertEqual(code, 0, stderr)
        [ledger] = self.flag_values(arguments, "--release-evidence-selected-rc-ledger")
        self.assertEqual(Path(ledger).read_text(), large)

    def test_extract_refuses_mismatched_or_tampered_bundles(self) -> None:
        bundle, digest = self.create()
        original = bundle.read_bytes()

        def rewritten(change) -> tuple[Path, str]:
            document = json.loads(original)
            change(document)
            path = self.root / "rewritten.json"
            path.write_bytes(json.dumps(document).encode())
            return path, hashlib.sha256(path.read_bytes()).hexdigest()

        tampered = self.root / "tampered.json"
        tampered.write_bytes(original.replace(b"ledger", b"forged"))
        cases = {
            "digest mismatch": (tampered, digest, {}),
            "malformed digest": (bundle, "not-a-digest", {}),
            "missing bundle": (self.root / "absent.json", digest, {}),
            "other build": (bundle, digest, {"build_number": "202610180602"}),
            "other version": (bundle, digest, {"version": "1.0.75"}),
            "missing required member": (*rewritten(lambda d: d["members"].pop("comparison")), {}),
            "unknown member": (*rewritten(lambda d: d["members"].update(extra="{}")), {}),
            "member not JSON": (*rewritten(lambda d: d["members"].update(comparison="{")), {}),
            "no manifests": (*rewritten(lambda d: d.update(expectedBuildManifests=[])), {}),
            "manifest not an object": (*rewritten(lambda d: d.update(expectedBuildManifests=["[]"])), {}),
            "wrong kind": (*rewritten(lambda d: d.update(kind="other")), {}),
        }
        for name, (candidate, expected_digest, overrides) in cases.items():
            with self.subTest(name):
                code, arguments, stderr = self.extract(candidate, expected_digest, **overrides)
                self.assertEqual(code, 1)
                self.assertEqual(arguments, [])
                self.assertIn("refused", stderr)

    def test_create_refuses_files_that_are_not_json(self) -> None:
        (self.root / "comparison.json").write_text("not json")
        code, _, stderr = self.run_tool(
            "create", "--version", "1.0.74", "--build-number", "1",
            "--validation-report", str(self.root / "validation-report.json"),
            "--release-evidence-report", str(self.root / "release-evidence.json"),
            "--comparison", str(self.root / "comparison.json"),
            "--expected-build-manifest", str(self.root / "manifest-macos.json"),
            "--output", str(self.root / "bundle.json"),
        )
        self.assertEqual(code, 1)
        self.assertIn("comparison", stderr)
        self.assertFalse((self.root / "bundle.json").exists())


if __name__ == "__main__":
    unittest.main()
