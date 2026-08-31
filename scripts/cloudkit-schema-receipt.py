#!/usr/bin/env python3
import argparse
import base64
import binascii
import hashlib
import hmac
import json
import os
import re
import sys
import tempfile
from datetime import UTC, datetime, timedelta
from pathlib import Path

KEY_ENVIRONMENT_VARIABLE = "CONTEXT_PANEL_CLOUDKIT_SCHEMA_RECEIPT_KEY"
KIND = "context-panel-cloudkit-production-schema-receipt"
SCHEMA_VERSION = 1
PRODUCTION_ENVIRONMENT = "production"
CONTAINER_IDENTIFIER = "iCloud.com.shinycomputers.contextpanel"
MAXIMUM_TTL_SECONDS = 24 * 60 * 60
MAXIMUM_CLOCK_SKEW_SECONDS = 5 * 60
COMMIT_PATTERN = re.compile(r"^[0-9a-fA-F]{40}$")
RECEIPT_KEYS = {
    "schemaVersion",
    "kind",
    "environment",
    "containerIdentifier",
    "contractDigest",
    "sourceCommit",
    "validatedAt",
    "expiresAt",
    "seal",
}


class ReceiptError(RuntimeError):
    pass


def require_key(environment: dict[str, str] | None = None) -> bytes:
    source = environment if environment is not None else os.environ
    value = source.get(KEY_ENVIRONMENT_VARIABLE, "")
    if len(value.encode()) < 32:
        raise ReceiptError(f"{KEY_ENVIRONMENT_VARIABLE} must contain at least 32 bytes")
    return value.encode()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def contract_digest(schema_path: Path, cktool_schema_path: Path) -> str:
    for path in (schema_path, cktool_schema_path):
        if not path.is_file():
            raise ReceiptError(f"CloudKit schema contract not found: {path}")
    digest = hashlib.sha256()
    digest.update(b"context-panel-cloudkit-schema-contract-v1\0")
    for label, path in (
        ("json", schema_path),
        ("ckdb", cktool_schema_path),
    ):
        digest.update(label.encode())
        digest.update(b"\0")
        digest.update(sha256_file(path).encode())
        digest.update(b"\0")
    return f"sha256:{digest.hexdigest()}"


def format_timestamp(value: datetime) -> str:
    return (
        value.astimezone(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    )


def parse_timestamp(value: object, label: str) -> datetime:
    if not isinstance(value, str) or not value.endswith("Z"):
        raise ReceiptError(f"receipt {label} must be a UTC timestamp")
    try:
        parsed = datetime.fromisoformat(value.removesuffix("Z") + "+00:00")
    except ValueError as error:
        raise ReceiptError(f"receipt {label} is invalid") from error
    return parsed.astimezone(UTC)


def canonical_payload(receipt: dict[str, object]) -> bytes:
    payload = {key: value for key, value in receipt.items() if key != "seal"}
    return json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()


def seal_payload(receipt: dict[str, object], key: bytes) -> str:
    return f"hmac-sha256:{hmac.new(key, canonical_payload(receipt), hashlib.sha256).hexdigest()}"


def issue_receipt(
    *,
    environment: str,
    container_identifier: str,
    schema_path: Path,
    cktool_schema_path: Path,
    source_commit: str,
    ttl_seconds: int,
    key: bytes,
    now: datetime | None = None,
) -> dict[str, object]:
    if environment != PRODUCTION_ENVIRONMENT:
        raise ReceiptError("schema receipts may be issued only for production")
    if container_identifier != CONTAINER_IDENTIFIER:
        raise ReceiptError(
            "schema receipts may be issued only for the Context Panel container"
        )
    if not COMMIT_PATTERN.fullmatch(source_commit):
        raise ReceiptError("source commit must be a full 40-character SHA")
    if ttl_seconds < 300 or ttl_seconds > MAXIMUM_TTL_SECONDS:
        raise ReceiptError("receipt TTL must be between 300 and 86400 seconds")
    validated_at = (now or datetime.now(UTC)).astimezone(UTC)
    receipt: dict[str, object] = {
        "schemaVersion": SCHEMA_VERSION,
        "kind": KIND,
        "environment": environment,
        "containerIdentifier": container_identifier,
        "contractDigest": contract_digest(schema_path, cktool_schema_path),
        "sourceCommit": source_commit.lower(),
        "validatedAt": format_timestamp(validated_at),
        "expiresAt": format_timestamp(validated_at + timedelta(seconds=ttl_seconds)),
    }
    receipt["seal"] = seal_payload(receipt, key)
    return receipt


def verify_receipt(
    receipt: dict[str, object],
    *,
    environment: str,
    container_identifier: str,
    schema_path: Path,
    cktool_schema_path: Path,
    source_commit: str,
    key: bytes,
    now: datetime | None = None,
) -> None:
    if environment != PRODUCTION_ENVIRONMENT:
        raise ReceiptError("schema receipts may be verified only for production")
    if container_identifier != CONTAINER_IDENTIFIER:
        raise ReceiptError(
            "schema receipts may be verified only for the Context Panel container"
        )
    if set(receipt) != RECEIPT_KEYS:
        raise ReceiptError("receipt fields do not match schema version 1")
    if receipt.get("schemaVersion") != SCHEMA_VERSION or receipt.get("kind") != KIND:
        raise ReceiptError("receipt schema identity is invalid")
    if receipt.get("environment") != environment:
        raise ReceiptError("receipt CloudKit environment does not match")
    if receipt.get("containerIdentifier") != container_identifier:
        raise ReceiptError("receipt CloudKit container does not match")
    if not COMMIT_PATTERN.fullmatch(source_commit):
        raise ReceiptError("source commit must be a full 40-character SHA")
    if receipt.get("sourceCommit") != source_commit.lower():
        raise ReceiptError("receipt source commit does not match")
    expected_contract_digest = contract_digest(schema_path, cktool_schema_path)
    if receipt.get("contractDigest") != expected_contract_digest:
        raise ReceiptError("receipt checked-in contract digest does not match")
    seal = receipt.get("seal")
    if not isinstance(seal, str) or not hmac.compare_digest(
        seal,
        seal_payload(receipt, key),
    ):
        raise ReceiptError("receipt seal is invalid")
    validated_at = parse_timestamp(receipt.get("validatedAt"), "validatedAt")
    expires_at = parse_timestamp(receipt.get("expiresAt"), "expiresAt")
    current = (now or datetime.now(UTC)).astimezone(UTC)
    if validated_at > current + timedelta(seconds=MAXIMUM_CLOCK_SKEW_SECONDS):
        raise ReceiptError("receipt validation time is in the future")
    if expires_at <= validated_at:
        raise ReceiptError("receipt expiry is not after validation time")
    if expires_at - validated_at > timedelta(seconds=MAXIMUM_TTL_SECONDS):
        raise ReceiptError("receipt validity window is too long")
    if expires_at <= current:
        raise ReceiptError("receipt has expired")


def load_receipt(path: Path) -> dict[str, object]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ReceiptError(f"receipt is unavailable or invalid: {path}") from error
    if not isinstance(value, dict):
        raise ReceiptError("receipt must be a JSON object")
    return value


def load_receipt_base64(value: str) -> dict[str, object]:
    if not value:
        raise ReceiptError("CloudKit schema receipt input is required")
    normalized = re.sub(r"[ \t\r\n]+", "", value)
    try:
        decoded = base64.b64decode(normalized, validate=True).decode()
        receipt = json.loads(decoded)
    except (binascii.Error, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ReceiptError("CloudKit schema receipt base64 is invalid") from error
    if not isinstance(receipt, dict):
        raise ReceiptError("receipt must be a JSON object")
    return receipt


def write_receipt(path: Path, receipt: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    serialized = json.dumps(receipt, indent=2, sort_keys=True) + "\n"
    temporary_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            "w",
            encoding="utf-8",
            dir=path.parent,
            delete=False,
        ) as handle:
            handle.write(serialized)
            temporary_path = Path(handle.name)
        os.replace(temporary_path, path)
    finally:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)


def add_contract_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--environment", default="production")
    parser.add_argument(
        "--container-id",
        default=CONTAINER_IDENTIFIER,
    )
    parser.add_argument(
        "--schema",
        type=Path,
        default=Path("CloudKit/companion-sync.schema.json"),
    )
    parser.add_argument(
        "--cktool-schema",
        type=Path,
        default=Path("CloudKit/companion-sync.schema.ckdb"),
    )
    parser.add_argument("--source-commit", required=True)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    issue = subparsers.add_parser("issue")
    add_contract_arguments(issue)
    issue.add_argument("--ttl-seconds", type=int, default=6 * 60 * 60)
    issue.add_argument("--output", type=Path, required=True)
    verify = subparsers.add_parser("verify")
    add_contract_arguments(verify)
    receipt_source = verify.add_mutually_exclusive_group(required=True)
    receipt_source.add_argument("--receipt", type=Path)
    receipt_source.add_argument("--receipt-base64-env")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        key = require_key()
        if args.command == "issue":
            receipt = issue_receipt(
                environment=args.environment,
                container_identifier=args.container_id,
                schema_path=args.schema,
                cktool_schema_path=args.cktool_schema,
                source_commit=args.source_commit,
                ttl_seconds=args.ttl_seconds,
                key=key,
            )
            write_receipt(args.output, receipt)
            print(f"CloudKit Production schema receipt issued: {args.output}")
        else:
            if args.receipt is not None:
                receipt = load_receipt(args.receipt)
            else:
                assert args.receipt_base64_env is not None
                receipt = load_receipt_base64(
                    os.environ.get(args.receipt_base64_env, "")
                )
            verify_receipt(
                receipt,
                environment=args.environment,
                container_identifier=args.container_id,
                schema_path=args.schema,
                cktool_schema_path=args.cktool_schema,
                source_commit=args.source_commit,
                key=key,
            )
            print("CloudKit Production schema receipt OK")
    except ReceiptError as error:
        print(f"CloudKit schema receipt validation failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
