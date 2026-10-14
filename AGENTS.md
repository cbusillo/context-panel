# Context Panel Agent Notes

## Direction and Instruction Authority

Read the Director's [overall DIRECTION.md](https://github.com/cbusillo/direction/blob/HEAD/DIRECTION.md)
before this file. This repository has no DIRECTION.md of its own; the overall
file governs work selection, stop boundaries, and retired guidance.
AGENTS.md is the only agent-instruction file; use nested AGENTS.md files when
path-specific instructions are needed.

## Product Shape

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

A test stays only if it fails when the product is broken and passes when
someone makes an intended change.

- No test may assert a literal defined elsewhere (versions, build numbers,
  toolchain versions, identifiers, hashes). Compare against the single source
  of truth, or do not test it.
- No new test may assert workflow, config, script, doc, or Swift source text.
  Enforce a rule where it executes: the workflow itself, a helper script with
  its own behavioural test, or a linter. Issue #695 removed the existing text
  tests; the only ones kept on purpose are negative privacy and security scans
  that still lack a linter or executable replacement.
- Verification and loading code, and the tests for it, must not depend on
  working-tree or Git state; check live state only on the path that acts on
  it. Release and runtime receipts bound to an exact commit are that acting
  path.
- Generated inventories and snapshots must not need a regeneration commit for
  unrelated changes.
- Keep byte-exact and hash gates only on real artifacts and immutable evidence.
- Tests must not wait on real time. Inject or patch sleeps, clocks, and retry
  delays.

## Repo Workflow

- Default branch: `main`.
- Use the shared [executing loop](https://github.com/cbusillo/codex-skills/blob/main/skills/references/executing-loop.md)
  and its owning skills. Read the issue and every comment, recheck ownership,
  and run `gh-plan.py claim` before creating the linked task worktree.
- Work on focused branches and open pull requests. Commit and push through the
  configured bot helpers. GitHub issues hold durable plans and Current Status.
- Follow the overall DIRECTION.md and the shared
  [merge-train procedure](https://github.com/cbusillo/codex-skills/blob/main/skills/launchplane/references/merge-train.md)
  for landing. Launchplane's active policy owns enrollment and routing.
  Apply [reviews by another model](https://github.com/cbusillo/codex-skills/blob/main/skills/references/model-review.md)
  to execution guidance and other changes it covers: account for findings with
  evidence; reviewer approval is not a merge or completion gate.
- Merging a PR does not publish a release. Use [the release procedure](docs/release.md)
  for separately authorized release work and preserve its implemented gates.
- Release closeout and Supervisor reporting follow the single
  [definition of released](docs/release.md#definition-of-released).
- Keep `.github/github.json` current when docs, validation gates,
  important workflows, or repo ownership assumptions change.
