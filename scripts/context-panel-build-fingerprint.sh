#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

files=(
	Config/ContextPanel-Info.plist
	Config/ContextPanelAppStore.entitlements
	Config/ContextPanel.entitlements
	Config/ContextPanelRefreshAgent-Info.plist
	Config/ContextPanelRefreshAgentAppStore.entitlements
	Config/ContextPanelRefreshAgent.entitlements
	Config/ContextPanelWidget-Info.plist
	Config/ContextPanelWidget.entitlements
	Package.swift
	project.yml
)

while IFS= read -r file; do files+=("$file"); done < <(find Sources/ContextPanelCore -type f -name '*.swift' | sort)
while IFS= read -r file; do files+=("$file"); done < <(find Sources/ContextPanelApp -type f -name '*.swift' | sort)
while IFS= read -r file; do files+=("$file"); done < <(find Sources/ContextPanelCloudKitSync -type f -name '*.swift' | sort)
while IFS= read -r file; do files+=("$file"); done < <(find Sources/ContextPanelSettingsUI -type f -name '*.swift' | sort)
while IFS= read -r file; do files+=("$file"); done < <(find Sources/ContextPanelWidgetUI -type f -name '*.swift' | sort)
while IFS= read -r file; do files+=("$file"); done < <(find Sources/ContextPanelRefreshAgent -type f -name '*.swift' | sort)
while IFS= read -r file; do files+=("$file"); done < <(find Sources/ContextPanelWidget -type f -name '*.swift' | sort)
while IFS= read -r file; do files+=("$file"); done < <(find Resources/Assets.xcassets -type f ! -name '.DS_Store' | sort)

{
	for file in "${files[@]}"; do
		if [[ ! -f "$file" ]]; then
			printf 'missing build fingerprint input: %s\n' "$file" >&2
			exit 1
		fi
		printf 'FILE %s\n' "$file"
		shasum -a 256 "$file"
	done
} | shasum -a 256 | awk '{print $1}'
