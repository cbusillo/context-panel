#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

exec "$repo_root/scripts/context-panel-surface-manifest.py" fingerprint \
	--root "$repo_root" \
	--surface macos.app \
	--kind combined
