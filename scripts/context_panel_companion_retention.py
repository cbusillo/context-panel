"""Explicit retention of unsigned, neutralized companion build quarantine.

Directory descriptors and no-follow opens confine inventory and removal even
when a descendant is a symlink. Live cache cleanup is never called by a build.
"""

from __future__ import annotations

import argparse
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
import os
from pathlib import Path
import re
import stat
import sys
from typing import Iterator


ENTRY_NAME = re.compile(r"(\d{8}T\d{6}Z)\.[A-Za-z0-9]{6}")
BUNDLE_NAMES = {
    "Context Panel.app.quarantined",
    "ContextPanelWidgetExtension.appex.quarantined",
    "ContextPanelCompanionWidgetExtension.appex.quarantined",
    "ContextPanelRefreshAgent.app.quarantined",
    "ContextPanelWatchWidgetExtension.appex.quarantined",
    "ContextPanelTVTopShelfExtension.appex.quarantined",
}
PROTECTED_NAMES = {
    "embedded.mobileprovision", "embedded.provisionprofile", "_CodeSignature", "CodeResources",
}
DIRECTORY_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW


class UnsafeEntry(ValueError):
    """Preserve content that is not demonstrably disposable build output."""


@contextmanager
def directory(name: str, parent: int) -> Iterator[int]:
    descriptor = os.open(name, DIRECTORY_FLAGS, dir_fd=parent)
    try:
        yield descriptor
    finally:
        os.close(descriptor)


@contextmanager
def open_path(path: Path) -> Iterator[int | None]:
    descriptor = os.open("/", DIRECTORY_FLAGS)
    try:
        # Check each ancestor independently: resolving the final path first
        # would follow symlinks and lose the evidence needed for confinement.
        for component in path.parts[1:]:
            try:
                child = os.open(component, DIRECTORY_FLAGS, dir_fd=descriptor)
            except FileNotFoundError:
                yield None
                return
            os.close(descriptor)
            descriptor = child
        yield descriptor
    finally:
        os.close(descriptor)


@contextmanager
def open_base(validation_root: str) -> Iterator[int | None]:
    path = Path(validation_root)
    if (not path.is_absolute() or ".." in path.parts or "\n" in validation_root
            or path.name != "companion-build-validation"
            or path.parent.name not in {".build", "derived-data"}
            or path.parent.parent == Path("/")):
        raise ValueError("invalid companion validation root")
    # Independently enforce the shell entrypoint's contract for direct callers.
    with open_path(path):
        pass
    container = path.parent if path.parent.name == ".build" else path.parent.parent
    with open_path(container / ".context-panel-companion-quarantine") as base:
        yield base


def inventory(descriptor: int, cutoff: float, inside_bundle: bool = False) -> dict:
    """Snapshot identities for removal, refusing evidence and recent writes."""
    result = {}
    for name in os.listdir(descriptor):
        info = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
        if name in PROTECTED_NAMES or name.endswith((".app", ".appex")):
            raise UnsafeEntry("signed or non-neutralized material")
        if info.st_mtime >= cutoff or info.st_ctime >= cutoff:
            raise UnsafeEntry("recently modified material")
        if stat.S_ISREG(info.st_mode) and info.st_nlink > 1:
            raise UnsafeEntry("hard-linked material")
        is_bundle = inside_bundle or name in BUNDLE_NAMES
        children = None
        if stat.S_ISDIR(info.st_mode):
            with directory(name, descriptor) as child:
                children = inventory(child, cutoff, is_bundle)
        elif not ((is_bundle and (stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode)))
                  or (name == ".DS_Store" and stat.S_ISREG(info.st_mode))):
            raise UnsafeEntry("unrecognized material outside a quarantined bundle")
        result[name] = (info.st_dev, info.st_ino, info.st_mode, info.st_size,
                        info.st_mtime_ns, info.st_ctime_ns, children)
    return result


def remove_contents(descriptor: int, snapshot: dict) -> None:
    for name, expected in snapshot.items():
        info = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
        if (info.st_dev, info.st_ino, info.st_mode, info.st_size,
                info.st_mtime_ns, info.st_ctime_ns) != expected[:6]:
            raise UnsafeEntry("entry changed during removal")
        children = expected[-1]
        if children is not None:
            with directory(name, descriptor) as child:
                if (os.fstat(child).st_dev, os.fstat(child).st_ino) != expected[:2]:
                    raise UnsafeEntry("directory changed during removal")
                remove_contents(child, children)
            os.rmdir(name, dir_fd=descriptor)
        else:
            # unlink removes the link itself; its target is never opened.
            os.unlink(name, dir_fd=descriptor)


def prune(validation_root: str, days: int, apply: bool, *, now: datetime) -> dict[str, int]:
    if days < 1:
        raise ValueError("retention must be at least one day")
    cutoff = (now - timedelta(days=days)).timestamp()
    counts = {"eligible": 0, "removed": 0, "preserved": 0}
    with open_base(validation_root) as base:
        if base is None:
            return counts
        for name in sorted(os.listdir(base)):
            match = ENTRY_NAME.fullmatch(name)
            try:
                created = datetime.strptime(match[1], "%Y%m%dT%H%M%SZ").replace(
                    tzinfo=timezone.utc) if match else None
            except ValueError:
                created = None
            info = os.stat(name, dir_fd=base, follow_symlinks=False)
            if (created is None or created.timestamp() >= cutoff
                    or not stat.S_ISDIR(info.st_mode)
                    or info.st_mtime >= cutoff or info.st_ctime >= cutoff):
                counts["preserved"] += 1
                continue
            removal_started = False
            try:
                with directory(name, base) as entry:
                    if (os.fstat(entry).st_dev, os.fstat(entry).st_ino) != (info.st_dev, info.st_ino):
                        raise UnsafeEntry("entry changed before inventory")
                    snapshot = inventory(entry, cutoff)
                    if apply:
                        if snapshot != inventory(entry, cutoff):
                            raise UnsafeEntry("entry changed after inventory")
                        removal_started = True
                        remove_contents(entry, snapshot)
                if apply:
                    current = os.stat(name, dir_fd=base, follow_symlinks=False)
                    if (current.st_dev, current.st_ino) != (info.st_dev, info.st_ino):
                        raise UnsafeEntry("entry changed before final removal")
                    os.rmdir(name, dir_fd=base)
                    counts["removed"] += 1
                counts["eligible"] += 1
            except UnsafeEntry:
                if removal_started:
                    raise
                counts["preserved"] += 1
    return counts


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--validation-root", required=True)
    parser.add_argument("--older-than-days", type=int, default=7)
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    try:
        counts = prune(args.validation_root, args.older_than_days, args.apply,
                       now=datetime.now(timezone.utc))
    except (OSError, ValueError) as error:
        # Do not print host paths from OS exceptions.
        print(f"companion-cache prune=REFUSED {type(error).__name__}", file=sys.stderr)
        return 3
    mode = "apply" if args.apply else "dry-run"
    print(f"companion-cache prune=OK mode={mode} older-than-days={args.older_than_days} "
          + " ".join(f"{key}={value}" for key, value in counts.items()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
