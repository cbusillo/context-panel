from __future__ import annotations

import hashlib
import json
import re
import struct
from typing import Any


SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
ARCHITECTURE_PATTERN = re.compile(r"^[A-Za-z0-9_.+-]{1,64}$")
UUID_PATTERN = re.compile(
    r"^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$"
)
SIGNING_CLASSES = frozenset(
    {
        "3rd Party Mac Developer Application",
        "3rd Party Mac Developer Installer",
        "Apple Development",
        "Apple Distribution",
        "Apple Mac OS Application Signing",
        "Developer ID Application",
        "Developer ID Installer",
        "Mac Developer",
        "TestFlight Beta Distribution",
        "iPhone Developer",
        "iPhone Distribution",
        "ad-hoc",
    }
)
DISTRIBUTION_SIGNING_CLASSES = SIGNING_CLASSES - {"ad-hoc"}


def canonical_json(value: Any) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=True,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")


def hash_parts(domain: str, parts: list[bytes | str]) -> str:
    digest = hashlib.sha256()
    for part in [domain, *parts]:
        encoded = part if isinstance(part, bytes) else part.encode("utf-8")
        digest.update(struct.pack(">Q", len(encoded)))
        digest.update(encoded)
    return digest.hexdigest()


