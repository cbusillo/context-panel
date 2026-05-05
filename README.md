# Context Panel

Context Panel is a planned macOS app and widget for seeing AI usage limits
across providers at a glance. The first target providers are OpenAI, Anthropic,
and Google.

The product goal is a small, native Mac utility that can answer the everyday
question before you prompt: which accounts and models are still available,
which limits are close, and when each allowance resets.

## Current Status

This repository is a native starter shell. It currently includes a Swift package
for shared provider and usage-limit domain types, CI, Dependabot, and repository
workflow metadata. The macOS app and widget targets will be added once the first
data and UI contracts settle.

## Product Direction

- Native macOS first, with WidgetKit as the primary glanceable surface.
- A companion app for account setup, provider connection health, and deeper
  usage detail.
- Multiple logins per provider, because friends, work accounts, personal
  accounts, and team accounts all need to coexist.
- Provider-neutral usage state for OpenAI, Anthropic, Google, and later services.
- Local-first handling of account credentials and usage snapshots.
- Beautiful compact charts and state widgets that emphasize remaining capacity,
  reset time, and trend instead of billing-dashboard noise.
- Small enough to share with friends without setup becoming a project.

## Planned Experience

The widget should be useful at a glance: provider/account rows, remaining usage,
reset timing, and compact visual indicators such as rings, bars, sparklines, or
small multiples when they make the state easier to read.

Clicking the widget should open the native app. The app is the place for account
setup, provider-specific status, refresh history, raw limit details, charts over
time, and troubleshooting when a provider changes behavior.

## Local Setup

```sh
swift build
swift test
scripts/commit-gate.sh
```

Useful entry points:

- [Product Goals](docs/product-goals.md)
- [Architecture](docs/architecture.md)
- [Repository Settings](docs/repo-settings.md)
