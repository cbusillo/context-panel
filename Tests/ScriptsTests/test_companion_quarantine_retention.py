"""Exercise retention against disposable trees, without touching live caches."""

from datetime import datetime, timedelta, timezone
import importlib.util
import io
import os
from pathlib import Path
import subprocess
import tempfile
import sys
import unittest
from unittest.mock import patch


REPO = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "companion_retention", REPO / "scripts/context_panel_companion_retention.py")
assert SPEC is not None and SPEC.loader is not None
RETENTION = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RETENTION)


class RetentionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.checkout = Path(self.temp.name).resolve() / "checkout"
        self.root = self.checkout / "derived-data/companion-build-validation"
        self.root.mkdir(parents=True)
        self.base = self.checkout / ".context-panel-companion-quarantine"
        self.base.mkdir()
        # Future injected clock makes fixture ctime old too; no sleeps or
        # production clock override are needed.
        self.now = datetime.now(timezone.utc).replace(microsecond=0) + timedelta(days=30)

    def entry(self, age=8, suffix="ABC123", *, base=None):
        stamp = (self.now - timedelta(days=age)).strftime("%Y%m%dT%H%M%SZ")
        entry = (base or self.base) / f"{stamp}.{suffix}"
        bundle = entry / "ios/Build/Products/Context Panel.app.quarantined"
        bundle.mkdir(parents=True)
        (bundle / "binary").write_bytes(b"build output")
        return entry, bundle

    def prune(self, apply=True, days=7):
        return RETENTION.prune(str(self.root), days, apply, now=self.now)

    def test_preview_preserves_and_apply_removes_only_expired_entry(self):
        old, _ = self.entry()
        boundary, _ = self.entry(age=7, suffix="EDGE00")
        recent, _ = self.entry(age=1, suffix="NEW000")
        self.assertEqual(self.prune(False)["eligible"], 1)
        self.assertTrue(old.exists())
        self.assertEqual(self.prune()["removed"], 1)
        self.assertFalse(old.exists())
        self.assertTrue(boundary.exists())
        self.assertTrue(recent.exists())
        self.assertEqual(self.prune()["removed"], 0)

    def test_retention_window_is_configurable(self):
        entry, _ = self.entry(age=10)
        self.assertEqual(self.prune(days=14)["eligible"], 0)
        self.assertTrue(entry.exists())
        self.assertEqual(self.prune(days=3)["removed"], 1)

    def test_recently_modified_old_entry_is_preserved(self):
        entry, bundle = self.entry()
        os.utime(bundle / "binary", (self.now.timestamp(), self.now.timestamp()))
        self.assertEqual(self.prune()["removed"], 0)
        self.assertTrue(entry.exists())

    def test_signed_or_active_bundle_material_is_preserved(self):
        for marker in ("embedded.mobileprovision", "Contents/embedded.provisionprofile",
                       "_CodeSignature/CodeResources", "Watch.app/Info.plist"):
            with self.subTest(marker=marker):
                entry, bundle = self.entry(suffix=f"SIG{len(list(self.base.iterdir())):03}")
                protected = bundle / marker
                protected.parent.mkdir(parents=True, exist_ok=True)
                protected.write_text("preserve")
                self.assertEqual(self.prune()["removed"], 0)
                self.assertTrue(protected.exists())
                self.assertTrue(entry.exists())

    def test_unrelated_evidence_and_unknown_entries_are_preserved(self):
        entry, _ = self.entry()
        (entry / "ExpectedBuildManifest.json").write_text("evidence")
        unknown = self.base / "other-data"
        unknown.mkdir()
        invalid = self.base / "20261399T000000Z.ABC123"
        invalid.mkdir()
        self.assertEqual(self.prune()["removed"], 0)
        self.assertTrue(entry.exists())
        self.assertTrue(unknown.exists())
        self.assertTrue(invalid.exists())

    def test_symlink_inside_bundle_is_unlinked_without_following_target(self):
        entry, bundle = self.entry()
        external = self.checkout / "external"
        external.mkdir()
        (external / "keep").write_text("untouched")
        (bundle / "link").symlink_to(external, target_is_directory=True)
        (bundle / "broken").symlink_to(self.checkout / "absent")
        self.assertEqual(self.prune()["removed"], 1)
        self.assertFalse(entry.exists())
        self.assertEqual((external / "keep").read_text(), "untouched")

    def test_hard_links_preserve_entry_before_any_deletion(self):
        entry, bundle = self.entry()
        os.link(bundle / "binary", bundle / "linked-binary")
        self.assertEqual(self.prune()["removed"], 0)
        self.assertTrue(entry.exists())
        self.assertEqual((bundle / "binary").read_bytes(), b"build output")
        self.assertEqual((bundle / "linked-binary").read_bytes(), b"build output")

    def test_finder_metadata_and_empty_failed_entries_can_age_out(self):
        entry, _ = self.entry()
        (entry / ".DS_Store").write_bytes(b"finder metadata")
        empty, bundle = self.entry(suffix="EMPTY0")
        (bundle / "binary").unlink()
        bundle.rmdir()
        self.assertEqual(self.prune()["removed"], 2)
        self.assertFalse(entry.exists())
        self.assertFalse(empty.exists())

    def test_quarantine_refuses_macos_profile_before_moving_bundle(self):
        bundle = self.root / "Build/Products/Context Panel.app"
        profile = bundle / "Contents/embedded.provisionprofile"
        profile.parent.mkdir(parents=True)
        profile.write_text("profile fixture")
        result = subprocess.run([str(REPO / "scripts/context-panel-companion-cache.sh"),
                                 "quarantine", "--root", str(self.root)],
                                text=True, capture_output=True, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(profile.exists())
        self.assertIn("protected-signed-bundles", result.stderr)

    def test_real_quarantine_output_ages_out_including_nested_bundles_and_links(self):
        bundle = self.root / "ios/Build/Products/Context Panel.app"
        nested = bundle / "Watch/Context Panel.app/PlugIns/ContextPanelWatchWidgetExtension.appex"
        nested.mkdir(parents=True)
        (nested / "binary").write_text("widget fixture")
        outside = self.checkout / "outside-widget"
        outside.mkdir()
        (outside / "keep").write_text("untouched")
        (bundle.parent / "ContextPanelCompanionWidgetExtension.appex").symlink_to(outside)
        result = subprocess.run([str(REPO / "scripts/context-panel-companion-cache.sh"),
                                 "quarantine", "--root", str(self.root)],
                                text=True, capture_output=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(list(self.base.iterdir())), 1)
        self.assertEqual(self.prune(False)["eligible"], 1)
        self.assertEqual(self.prune()["removed"], 1)
        self.assertEqual(list(self.base.iterdir()), [])
        self.assertEqual((outside / "keep").read_text(), "untouched")

    def test_entry_symlink_is_preserved(self):
        entry, _ = self.entry()
        link = self.base / entry.name.replace("ABC123", "LINK00")
        link.symlink_to(entry, target_is_directory=True)
        self.prune()
        self.assertTrue(link.is_symlink())

    def test_base_and_ancestor_symlinks_are_refused(self):
        entry, _ = self.entry()
        other = self.checkout / "saved"
        self.base.rename(other)
        self.base.symlink_to(other, target_is_directory=True)
        with self.assertRaises(OSError):
            self.prune()
        self.assertTrue((other / entry.name).exists())
        alias = self.checkout.parent / "alias"
        alias.symlink_to(self.checkout, target_is_directory=True)
        with self.assertRaises(OSError):
            RETENTION.prune(str(alias / "derived-data/companion-build-validation"),
                            7, True, now=self.now)

    def test_local_build_layout_and_missing_base(self):
        self.root = self.checkout / ".build/companion-build-validation"
        self.root.mkdir(parents=True)
        self.assertEqual(self.prune()["removed"], 0)
        self.base = self.root.parent / ".context-panel-companion-quarantine"
        entry, _ = self.entry()
        self.assertEqual(self.prune()["removed"], 1)
        self.assertFalse(entry.exists())

    def test_unsafe_root_and_invalid_age_are_refused(self):
        for root in ("/companion-build-validation", "/.build/companion-build-validation",
                     str(self.root.parent), str(self.root.parent / "../companion-build-validation")):
            with self.subTest(root=root), self.assertRaises(ValueError):
                RETENTION.prune(root, 7, True, now=self.now)
        with self.assertRaises(ValueError):
            self.prune(days=0)

    def test_inventory_failure_never_deletes(self):
        entry, _ = self.entry()
        with patch.object(RETENTION, "inventory", side_effect=OSError("scan failure")):
            with self.assertRaises(OSError):
                self.prune()
        self.assertTrue(entry.exists())

    def test_later_inventory_failure_reports_prior_completed_deletions(self):
        removed, _ = self.entry(age=9)
        failed, _ = self.entry(age=8, suffix="FAILED")
        inode = failed.stat().st_ino
        original = RETENTION.inventory

        def fail_second(descriptor, cutoff, inside_bundle=False):
            if os.fstat(descriptor).st_ino == inode:
                raise PermissionError("fixture")
            return original(descriptor, cutoff, inside_bundle)

        with patch.object(RETENTION, "inventory", side_effect=fail_second):
            with self.assertRaises(RETENTION.PruneRunError) as raised:
                self.prune()
        self.assertEqual(raised.exception.removed, 1)
        self.assertEqual(raised.exception.entry, failed.name)
        self.assertFalse(removed.exists())
        self.assertTrue(failed.exists())

    def test_changed_inventory_is_preserved_before_deletion(self):
        entry, bundle = self.entry()
        original = RETENTION.inventory
        identity = entry.stat().st_ino
        calls = 0

        def changing_inventory(descriptor, cutoff, inside_bundle=False):
            nonlocal calls
            result = original(descriptor, cutoff, inside_bundle)
            if os.fstat(descriptor).st_ino == identity:
                calls += 1
                if calls == 1:
                    (bundle / "binary").write_text("changed during preview")
            return result

        with patch.object(RETENTION, "inventory", side_effect=changing_inventory):
            self.assertEqual(self.prune()["removed"], 0)
        self.assertTrue(entry.exists())

    def test_validation_root_symlink_is_refused_by_direct_helper(self):
        entry, _ = self.entry()
        self.root.rmdir()
        self.root.symlink_to(self.base, target_is_directory=True)
        with self.assertRaises(OSError):
            self.prune()
        self.assertTrue(entry.exists())

    def test_removal_failure_is_reported_instead_of_clean_preservation(self):
        entry, _ = self.entry()
        with patch.object(RETENTION, "remove_contents", side_effect=RETENTION.UnsafeEntry("changed")):
            with self.assertRaises(RETENTION.PartialRemovalError):
                self.prune()
        self.assertTrue(entry.exists())

    def test_partial_removal_reports_the_entry_without_host_paths(self):
        entry, _ = self.entry()
        error = RETENTION.PartialRemovalError(entry.name, PermissionError(str(entry)))
        stderr = io.StringIO()
        with patch.object(RETENTION, "prune", side_effect=error), \
                patch.object(sys, "argv", ["retention", "--validation-root", str(self.root), "--apply"]), \
                patch.object(sys, "stderr", stderr):
            self.assertEqual(RETENTION.main(), 3)
        self.assertIn(f"prune=PARTIAL entry={entry.name}", stderr.getvalue())
        self.assertNotIn(str(self.checkout), stderr.getvalue())

    def test_shell_command_defaults_to_preview_and_rejects_bad_options(self):
        entry, _ = self.entry()
        helper = REPO / "scripts/context-panel-companion-cache.sh"
        result = subprocess.run([str(helper), "prune", "--root", str(self.root)],
                                text=True, capture_output=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("mode=dry-run", result.stdout)
        self.assertTrue(entry.exists())
        for args in (["prune"], ["prune", "--root", str(self.root), "--older-than-days", "0"],
                     ["prune", "--root", str(self.root), "--older-than-days", "99999999"],
                     ["quarantine", "--root", str(self.root), "--apply"]):
            with self.subTest(args=args):
                result = subprocess.run([str(helper), *args], capture_output=True, check=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn(b"Traceback", result.stderr)
        self.assertTrue(entry.exists())


if __name__ == "__main__":
    unittest.main()
