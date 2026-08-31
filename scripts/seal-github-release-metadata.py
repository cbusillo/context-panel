#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import re
import sys
import tempfile
from pathlib import Path

COMMIT_PATTERN = re.compile(r"^[0-9a-fA-F]{40}$")


def asset_identity(path: Path) -> dict[str, object]:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return {
        "name": path.name,
        "sha256": digest.hexdigest(),
        "size": path.stat().st_size,
    }


def seal_metadata(
    metadata_path: Path,
    *,
    tag: str,
    source_commit: str,
    version: str,
    build_number: str,
    asset_paths: list[Path],
) -> dict[str, object]:
    if not COMMIT_PATTERN.fullmatch(source_commit):
        raise ValueError("source commit must be a full 40-character SHA")
    metadata = json.loads(metadata_path.read_text())
    if metadata.get("version") != version:
        raise ValueError("release metadata version does not match the workflow version")
    if str(metadata.get("buildNumber", "")) != build_number:
        raise ValueError(
            "release metadata build number does not match the workflow build number"
        )
    if not asset_paths:
        raise ValueError("at least one release asset is required")
    names = [path.name for path in asset_paths]
    if len(names) != len(set(names)):
        raise ValueError("release asset names must be unique")
    for path in asset_paths:
        if not path.is_file():
            raise ValueError(f"release asset not found: {path}")

    metadata["releaseIdentity"] = {
        "schemaVersion": 1,
        "tag": tag,
        "sourceCommit": source_commit.lower(),
        "version": version,
        "buildNumber": build_number,
        "assets": [asset_identity(path) for path in asset_paths],
    }
    serialized = json.dumps(metadata, indent=2, sort_keys=True) + "\n"
    with tempfile.NamedTemporaryFile(
        "w",
        encoding="utf-8",
        dir=metadata_path.parent,
        delete=False,
    ) as handle:
        handle.write(serialized)
        temporary_path = Path(handle.name)
    os.replace(temporary_path, metadata_path)
    return metadata


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--metadata", type=Path, required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build-number", required=True)
    parser.add_argument("--asset", action="append", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        seal_metadata(
            args.metadata,
            tag=args.tag,
            source_commit=args.source_commit,
            version=args.version,
            build_number=args.build_number,
            asset_paths=args.asset,
        )
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"could not seal GitHub Release metadata: {error}", file=sys.stderr)
        return 1
    print(f"sealed GitHub Release metadata: {args.metadata}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
