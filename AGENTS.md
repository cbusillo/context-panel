# Context Panel Agent Notes

## Direction and Instruction Authority

Read the Director's [overall DIRECTION.md](https://github.com/cbusillo/direction/blob/HEAD/DIRECTION.md)
before this file. This repository has no DIRECTION.md of its own.
AGENTS.md is the only agent-instruction file; use nested AGENTS.md files when
path-specific instructions are needed.

## Product Shape

Client: the Director.

Context Panel is a native macOS app plus WidgetKit extension for tracking AI
usage limits across providers, with read-only iPhone, iPad, Vision Pro, Apple
Watch, and Apple TV companions. Treat multi-account support as a core product
requirement, not a later enhancement. The provider set is OpenAI, Anthropic,
and Google.

The widget is for glanceable state: remaining capacity, limit pressure, reset
time, and whether refreshes are healthy. The app is for setup and detail:
multiple logins, credential management, provider diagnostics, detailed charts,
history, and settings.

## Engineering Defaults

- Keep the repo native-first. Do not add web or Docker surfaces unless Chris
  explicitly asks for them.
- Prefer Swift, SwiftUI, WidgetKit, and Swift Package Manager.
- Keep provider-specific behavior behind adapters. Shared UI and storage should
  consume normalized provider/account/limit snapshots.
- Keep credentials local. Favor Keychain-backed storage for secrets and avoid
  logging tokens, account identifiers, or raw provider responses that may expose
  sensitive data.
- Model unknown and degraded states explicitly. Provider APIs and unofficial
  usage surfaces can change; the UI should make stale or partial data obvious.
- Design for multiple accounts per provider from the data model up through the
  widget layout.

## UX Direction

`docs/design-direction.md` is the design authority. The accepted Horizon
design (#722) is the default account layout; the points below are the
standing product rules.

- The widget should be beautiful, dense, and calm: compact charts, rings, bars,
  sparklines, reset countdowns, and provider/account grouping where useful.
- For weekly or rolling account limits, include forecast language that helps the
  user decide whether higher-burn modes are safe before reset.
- Avoid making the widget a dashboard crammed into a rectangle. Put setup,
  troubleshooting, raw details, and long histories in the app.
- Clicking the widget should open the app to the most relevant provider/account
  detail.
- Prefer plain language over status jargon. In the account layout, say when an
  account runs out or how much it has to spare at its reset, and keep red for
  an account that runs out before its reset. Account state words come from
  `Sources/ContextPanelCore/AccountOverviewText.swift` (for example Available,
  Close to limit, Saved, Paused, Not updating, Unknown).

## Validation

Start with [Validation Authority and Operator Route](docs/validation-authority.md).

## Test Rules

Follow the [shared Tests rule](https://github.com/cbusillo/codex-skills/blob/main/instructions/global.md#tests).
Use `qualityGate.test.local` in `.github/github.json` for focused Swift tests
of changed behavior; run selected Python fixture modules directly as described
in [test lanes](docs/test-lanes.md#commands). Run required lint, type checks and
IDE inspection alongside them. The complete `qualityGate.test.ci` sequence runs
only in CI and must pass on the current head before `ready` or merge.

For safety, authorization, approval rules, destructive helpers and shared
infrastructure, also run complete affected test modules locally. Trace changed
credential/account identity, sandbox, signing, approval, runtime-replacement and
cleanup behavior through its callers to the covering Swift test classes and
Python fixture files. Preserve the protected release, visual and runtime lanes;
record required unavailable local evidence as missing instead of treating green
CI as a waiver. [Validation authority](docs/validation-authority.md) continues
to own installed/runtime and release evidence.

Repository exception: the existing negative privacy and security text scans
retained by #695 remain until a linter or executable replacement covers them.

## Repo Workflow

- Default branch: `main`.
- Use the shared [executing loop](https://github.com/cbusillo/codex-skills/blob/main/skills/references/executing-loop.md)
  and its owning skills.
- Release operations: [the release procedure](docs/release.md).
- Release closeout and Supervisor reporting follow the single
  [definition of released](docs/release.md#definition-of-released).
- Keep `.github/github.json` current when docs, validation gates,
  important workflows, or repo ownership assumptions change.
