# Context Panel

Context Panel is a planned macOS widget for seeing AI usage limits across
providers at a glance. The first target providers are OpenAI, Anthropic, and
Google.

The product goal is a small, native Mac utility that can answer the everyday
question before you prompt: which models are still available, which limits are
close, and when each allowance resets.

## Current Status

This repository is a native starter shell. It currently includes a Swift package
for shared provider and usage-limit domain types, CI, Dependabot, and repository
workflow metadata. The macOS widget target will be added once the first data and
UI contracts settle.

## Product Direction

- Native macOS first, with WidgetKit as the primary surface.
- Provider-neutral usage state for OpenAI, Anthropic, Google, and later services.
- Local-first handling of account credentials and usage snapshots.
- Clear reset times and remaining capacity instead of billing-dashboard noise.
- Small enough to share with friends without setup becoming a project.

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
