#!/usr/bin/env python3
import argparse
import base64
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol
from urllib.parse import quote

COMMIT_PATTERN = re.compile(r"^[0-9a-fA-F]{40}$")
IDENTITY_MARKER_PATTERN = re.compile(
    r"<!-- context-panel-release-identity:v1:([A-Za-z0-9_-]+) -->"
)


class PublicationError(RuntimeError):
    pass


@dataclass(frozen=True)
class AssetIdentity:
    name: str
    sha256: str
    size: int
    path: Path

    def record(self) -> dict[str, object]:
        return {"name": self.name, "sha256": self.sha256, "size": self.size}


@dataclass(frozen=True)
class ReleaseIdentity:
    tag: str
    source_commit: str
    version: str
    build_number: str
    assets: tuple[AssetIdentity, ...]

    def record(self) -> dict[str, object]:
        return {
            "schemaVersion": 1,
            "tag": self.tag,
            "sourceCommit": self.source_commit,
            "version": self.version,
            "buildNumber": self.build_number,
            "assets": [asset.record() for asset in self.assets],
        }


class ReleaseClient(Protocol):
    def resolve_tag(self, tag: str) -> str | None: ...

    def get_release(self, tag: str) -> dict[str, object] | None: ...

    def create_draft(
        self,
        tag: str,
        commit: str,
        title: str,
        notes: str,
        *,
        tag_exists: bool,
    ) -> None: ...

    def upload_asset(self, tag: str, path: Path) -> None: ...

    def download_asset(self, asset_id: int) -> bytes: ...

    def delete_asset(self, asset_id: int) -> None: ...

    def publish_draft(self, tag: str) -> None: ...


class GitHubCLIClient:
    def __init__(self, repository: str) -> None:
        self.repository = repository

    def _run(
        self,
        arguments: list[str],
        *,
        text: bool = True,
    ) -> subprocess.CompletedProcess:
        return subprocess.run(
            ["gh", *arguments],
            capture_output=True,
            text=text,
            check=False,
        )

    def _api_json(
        self,
        endpoint: str,
        *,
        allow_not_found: bool = False,
    ) -> dict[str, object] | None:
        result = self._run(["api", endpoint])
        if result.returncode != 0:
            if allow_not_found and (
                "HTTP 404" in result.stderr or "Not Found" in result.stderr
            ):
                return None
            raise PublicationError(
                result.stderr.strip() or f"GitHub API failed: {endpoint}"
            )
        try:
            value = json.loads(result.stdout)
        except json.JSONDecodeError as error:
            raise PublicationError(
                f"GitHub API returned invalid JSON: {endpoint}"
            ) from error
        if not isinstance(value, dict):
            raise PublicationError(
                f"GitHub API returned an unexpected value: {endpoint}"
            )
        return value

    def _api_pages(self, endpoint: str) -> list[dict[str, object]]:
        result = self._run(["api", "--paginate", "--slurp", endpoint])
        if result.returncode != 0:
            raise PublicationError(
                result.stderr.strip() or f"GitHub API failed: {endpoint}"
            )
        try:
            pages = json.loads(result.stdout)
        except json.JSONDecodeError as error:
            raise PublicationError(
                f"GitHub API returned invalid paginated JSON: {endpoint}"
            ) from error
        if not isinstance(pages, list):
            raise PublicationError(
                f"GitHub API returned unexpected paginated data: {endpoint}"
            )
        values: list[dict[str, object]] = []
        for page in pages:
            if not isinstance(page, list):
                raise PublicationError(
                    f"GitHub API returned a malformed page: {endpoint}"
                )
            for value in page:
                if not isinstance(value, dict):
                    raise PublicationError(
                        f"GitHub API returned a malformed release: {endpoint}"
                    )
                values.append(value)
        return values

    def resolve_tag(self, tag: str) -> str | None:
        reference = self._api_json(
            f"repos/{self.repository}/git/ref/tags/{quote(tag, safe='')}",
            allow_not_found=True,
        )
        if reference is None:
            return None
        current = reference.get("object")
        seen: set[str] = set()
        for _ in range(8):
            if not isinstance(current, dict):
                raise PublicationError(f"tag {tag} has no Git object")
            object_type = current.get("type")
            object_sha = current.get("sha")
            if not isinstance(object_sha, str) or not COMMIT_PATTERN.fullmatch(
                object_sha
            ):
                raise PublicationError(f"tag {tag} has an invalid Git object SHA")
            object_sha = object_sha.lower()
            if object_type == "commit":
                return object_sha
            if object_type != "tag" or object_sha in seen:
                raise PublicationError(f"tag {tag} does not resolve to a commit")
            seen.add(object_sha)
            annotated = self._api_json(f"repos/{self.repository}/git/tags/{object_sha}")
            current = annotated.get("object") if annotated is not None else None
        raise PublicationError(f"tag {tag} exceeded the tag resolution limit")

    def get_release(self, tag: str) -> dict[str, object] | None:
        published = self._api_json(
            f"repos/{self.repository}/releases/tags/{quote(tag, safe='')}",
            allow_not_found=True,
        )
        if published is not None:
            return published
        matches = [
            release
            for release in self._api_pages(
                f"repos/{self.repository}/releases?per_page=100"
            )
            if release.get("tag_name") == tag
        ]
        if len(matches) > 1:
            raise PublicationError(f"multiple GitHub Releases use tag name {tag}")
        return matches[0] if matches else None

    def create_draft(
        self,
        tag: str,
        commit: str,
        title: str,
        notes: str,
        *,
        tag_exists: bool,
    ) -> None:
        with tempfile.NamedTemporaryFile("w", encoding="utf-8") as notes_file:
            notes_file.write(notes)
            notes_file.flush()
            arguments = [
                "release",
                "create",
                tag,
                "--draft",
                "--title",
                title,
                "--notes-file",
                notes_file.name,
            ]
            if tag_exists:
                arguments.append("--verify-tag")
            else:
                arguments.extend(["--target", commit])
            result = self._run(arguments)
        if result.returncode != 0:
            raise PublicationError(
                result.stderr.strip() or "could not create draft release"
            )

    def upload_asset(self, tag: str, path: Path) -> None:
        result = self._run(["release", "upload", tag, str(path)])
        if result.returncode != 0:
            raise PublicationError(
                result.stderr.strip() or f"could not upload release asset: {path.name}"
            )

    def download_asset(self, asset_id: int) -> bytes:
        result = self._run(
            [
                "api",
                "-H",
                "Accept: application/octet-stream",
                f"repos/{self.repository}/releases/assets/{asset_id}",
            ],
            text=False,
        )
        if result.returncode != 0:
            stderr = result.stderr.decode(errors="replace").strip()
            raise PublicationError(
                stderr or f"could not download release asset {asset_id}"
            )
        return result.stdout

    def delete_asset(self, asset_id: int) -> None:
        result = self._run(
            [
                "api",
                "--method",
                "DELETE",
                f"repos/{self.repository}/releases/assets/{asset_id}",
            ]
        )
        if result.returncode != 0:
            raise PublicationError(
                result.stderr.strip() or f"could not delete draft asset {asset_id}"
            )

    def publish_draft(self, tag: str) -> None:
        result = self._run(["release", "edit", tag, "--draft=false"])
        if result.returncode != 0:
            raise PublicationError(
                result.stderr.strip() or "could not publish draft release"
            )


def asset_identity(path: Path) -> AssetIdentity:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return AssetIdentity(path.name, digest.hexdigest(), path.stat().st_size, path)


def canonical_identity(identity: ReleaseIdentity) -> bytes:
    return json.dumps(identity.record(), sort_keys=True, separators=(",", ":")).encode()


def identity_marker(identity: ReleaseIdentity) -> str:
    encoded = (
        base64.urlsafe_b64encode(canonical_identity(identity)).decode().rstrip("=")
    )
    return f"<!-- context-panel-release-identity:v1:{encoded} -->"


def parse_identity_marker(body: str) -> dict[str, object]:
    matches = IDENTITY_MARKER_PATTERN.findall(body)
    if len(matches) != 1:
        raise PublicationError("release notes must contain exactly one identity marker")
    encoded = matches[0]
    encoded += "=" * (-len(encoded) % 4)
    try:
        value = json.loads(base64.urlsafe_b64decode(encoded).decode())
    except (UnicodeDecodeError, ValueError, json.JSONDecodeError) as error:
        raise PublicationError("release identity marker is malformed") from error
    if not isinstance(value, dict):
        raise PublicationError("release identity marker is not a JSON object")
    return value


def render_notes(notes: str, identity: ReleaseIdentity) -> str:
    human_notes = notes.rstrip()
    if human_notes:
        return f"{human_notes}\n\n{identity_marker(identity)}\n"
    return f"{identity_marker(identity)}\n"


def build_release_identity(
    *,
    tag: str,
    source_commit: str,
    version: str,
    build_number: str,
    metadata_path: Path,
    asset_paths: list[Path],
) -> ReleaseIdentity:
    if not COMMIT_PATTERN.fullmatch(source_commit):
        raise PublicationError("source commit must be a full 40-character SHA")
    if not metadata_path.is_file():
        raise PublicationError(f"release metadata not found: {metadata_path}")
    if not asset_paths:
        raise PublicationError("at least one payload asset is required")
    for path in asset_paths:
        if not path.is_file():
            raise PublicationError(f"release asset not found: {path}")
    paths = [*asset_paths, metadata_path]
    names = [path.name for path in paths]
    if len(names) != len(set(names)):
        raise PublicationError("release asset names must be unique")

    metadata = json.loads(metadata_path.read_text())
    sealed = metadata.get("releaseIdentity")
    if not isinstance(sealed, dict):
        raise PublicationError("release metadata is not sealed")
    expected_seal = {
        "schemaVersion": 1,
        "tag": tag,
        "sourceCommit": source_commit.lower(),
        "version": version,
        "buildNumber": build_number,
        "assets": [asset_identity(path).record() for path in asset_paths],
    }
    if sealed != expected_seal:
        raise PublicationError("release metadata identity does not match the build")
    identities = tuple(
        sorted((asset_identity(path) for path in paths), key=lambda item: item.name)
    )
    return ReleaseIdentity(
        tag=tag,
        source_commit=source_commit.lower(),
        version=version,
        build_number=build_number,
        assets=identities,
    )


def release_assets(release: dict[str, object]) -> dict[str, dict[str, object]]:
    raw_assets = release.get("assets", [])
    if not isinstance(raw_assets, list):
        raise PublicationError("GitHub Release assets are malformed")
    assets: dict[str, dict[str, object]] = {}
    for raw_asset in raw_assets:
        if not isinstance(raw_asset, dict):
            raise PublicationError("GitHub Release contains a malformed asset")
        name = raw_asset.get("name")
        asset_id = raw_asset.get("id")
        if not isinstance(name, str) or not isinstance(asset_id, int):
            raise PublicationError("GitHub Release asset identity is malformed")
        if name in assets:
            raise PublicationError(f"GitHub Release has duplicate asset names: {name}")
        assets[name] = raw_asset
    return assets


def verify_remote_assets(
    client: ReleaseClient,
    release: dict[str, object],
    identity: ReleaseIdentity,
    *,
    repair_draft: bool,
) -> list[AssetIdentity]:
    remote_assets = release_assets(release)
    expected_assets = {asset.name: asset for asset in identity.assets}
    unexpected = sorted(set(remote_assets) - set(expected_assets))
    if unexpected:
        raise PublicationError(
            f"GitHub Release contains unexpected assets: {', '.join(unexpected)}"
        )
    missing = [asset for asset in identity.assets if asset.name not in remote_assets]
    if missing and not repair_draft:
        raise PublicationError(
            "GitHub Release is missing assets: "
            + ", ".join(asset.name for asset in missing)
        )
    for name, remote in remote_assets.items():
        expected = expected_assets[name]
        asset_id = remote["id"]
        if not isinstance(asset_id, int):
            raise PublicationError(f"GitHub Release asset ID is malformed: {name}")
        state = remote.get("state")
        matches = state == "uploaded"
        if matches:
            content = client.download_asset(asset_id)
            digest = hashlib.sha256(content).hexdigest()
            matches = len(content) == expected.size and digest == expected.sha256
        if not matches:
            if not repair_draft:
                raise PublicationError(
                    f"GitHub Release asset bytes do not match: {name}"
                )
            client.delete_asset(asset_id)
            missing.append(expected)
    return missing


def require_tag_commit(client: ReleaseClient, identity: ReleaseIdentity) -> None:
    tag_commit = client.resolve_tag(identity.tag)
    if tag_commit != identity.source_commit:
        rendered = tag_commit or "missing"
        raise PublicationError(
            f"tag {identity.tag} resolves to {rendered}, not {identity.source_commit}"
        )


def release_is_draft(
    release: dict[str, object],
    identity: ReleaseIdentity,
) -> bool:
    is_draft = release.get("draft")
    if not isinstance(is_draft, bool):
        raise PublicationError("GitHub Release draft state is malformed")
    body = release.get("body")
    if not isinstance(body, str) or parse_identity_marker(body) != identity.record():
        remedy = (
            "; inspect and delete the draft before intentionally rebuilding"
            if is_draft
            else ""
        )
        raise PublicationError(
            f"GitHub Release identity does not match the build{remedy}"
        )
    return is_draft


def require_draft_target(
    release: dict[str, object],
    identity: ReleaseIdentity,
) -> None:
    target = release.get("target_commitish")
    if target != identity.source_commit:
        rendered = target if isinstance(target, str) else "missing"
        raise PublicationError(
            f"draft target resolves to {rendered}, not {identity.source_commit}"
        )


def publish_release(
    client: ReleaseClient,
    identity: ReleaseIdentity,
    *,
    title: str,
    notes: str,
) -> str:
    tag_commit = client.resolve_tag(identity.tag)
    if tag_commit is not None and tag_commit != identity.source_commit:
        raise PublicationError(
            f"tag {identity.tag} resolves to {tag_commit}, not {identity.source_commit}"
        )
    release = client.get_release(identity.tag)
    if release is None:
        client.create_draft(
            identity.tag,
            identity.source_commit,
            title,
            render_notes(notes, identity),
            tag_exists=tag_commit is not None,
        )
        release = client.get_release(identity.tag)
        if release is None:
            raise PublicationError("draft GitHub Release was not created")

    is_draft = release_is_draft(release, identity)
    if tag_commit is None:
        if not is_draft:
            raise PublicationError("published GitHub Release has no matching tag")
        require_draft_target(release, identity)
    missing = verify_remote_assets(client, release, identity, repair_draft=is_draft)
    if not is_draft:
        require_tag_commit(client, identity)
        return "already-published"

    for asset in missing:
        client.upload_asset(identity.tag, asset.path)
    release = client.get_release(identity.tag)
    if release is None:
        raise PublicationError("draft GitHub Release disappeared during upload")
    if release_is_draft(release, identity) is not True:
        raise PublicationError("GitHub Release left draft state before verification")
    verify_remote_assets(client, release, identity, repair_draft=False)
    current_tag = client.resolve_tag(identity.tag)
    if current_tag is None:
        require_draft_target(release, identity)
    elif current_tag != identity.source_commit:
        raise PublicationError(
            f"tag {identity.tag} resolves to {current_tag}, not {identity.source_commit}"
        )
    client.publish_draft(identity.tag)
    release = client.get_release(identity.tag)
    if release is None or release_is_draft(release, identity) is not False:
        raise PublicationError("GitHub Release did not leave draft state")
    verify_remote_assets(client, release, identity, repair_draft=False)
    require_tag_commit(client, identity)
    return "published"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY", ""))
    parser.add_argument("--tag", required=True)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build-number", required=True)
    parser.add_argument("--title", required=True)
    parser.add_argument("--notes-file", type=Path, required=True)
    parser.add_argument("--metadata", type=Path, required=True)
    parser.add_argument("--asset", action="append", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if not args.repository:
        print("GitHub repository is required", file=sys.stderr)
        return 2
    try:
        identity = build_release_identity(
            tag=args.tag,
            source_commit=args.source_commit,
            version=args.version,
            build_number=args.build_number,
            metadata_path=args.metadata,
            asset_paths=args.asset,
        )
        result = publish_release(
            GitHubCLIClient(args.repository),
            identity,
            title=args.title,
            notes=args.notes_file.read_text(),
        )
    except (OSError, PublicationError, json.JSONDecodeError) as error:
        print(f"GitHub Release publication failed: {error}", file=sys.stderr)
        return 1
    print(f"GitHub Release publication {result}: {identity.tag}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
