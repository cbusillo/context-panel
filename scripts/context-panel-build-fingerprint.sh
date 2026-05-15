#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

files=(
	Config/ContextPanel-Info.plist
	Config/ContextPanel.entitlements
	Config/ContextPanelRefreshAgent.entitlements
	Config/ContextPanelWidget-Info.plist
	Config/ContextPanelWidget.entitlements
	ContextPanel.xcodeproj/project.pbxproj
	Package.swift
)

while IFS= read -r file; do files+=("$file"); done < <(find Sources/ContextPanelCore -type f -name '*.swift' | sort)
while IFS= read -r file; do files+=("$file"); done < <(find Sources/ContextPanelPreview -type f -name '*.swift' | sort)
while IFS= read -r file; do files+=("$file"); done < <(find Sources/ContextPanelRefreshAgent -type f -name '*.swift' | sort)
while IFS= read -r file; do files+=("$file"); done < <(find Sources/ContextPanelWidget -type f -name '*.swift' | sort)

{
	for file in "${files[@]}"; do
		if [[ -f "$file" ]]; then
			printf 'FILE %s\n' "$file"
			shasum -a 256 "$file"
		fi
	done
} | shasum -a 256 | awk '{print $1}'
