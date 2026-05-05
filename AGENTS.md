# Context Panel Agent Notes

## Product Shape

Context Panel is a native macOS app plus WidgetKit extension for tracking AI
usage limits across providers. Treat multi-account support as a core product
requirement, not a later enhancement. The initial provider set is OpenAI,
Anthropic, and Google.

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

- The widget should be beautiful, dense, and calm: compact charts, rings, bars,
  sparklines, reset countdowns, and provider/account grouping where useful.
- Avoid making the widget a dashboard crammed into a rectangle. Put setup,
  troubleshooting, raw details, and long histories in the app.
- Clicking the widget should open the app to the most relevant provider/account
  detail.
- Prefer plain status language: available, close to limit, limited, unknown,
  stale, refreshing.

## Validation

Run the commit gate before publishing changes:

```sh
scripts/commit-gate.sh
```

For UI work, also run the native app/widget locally and inspect the actual macOS
presentation before calling the work ready.

## Repo Workflow

- Default branch: `main`.
- Work on focused branches and open pull requests.
- Keep `.github/github-repo-workflow.json` current when docs, validation gates,
  important workflows, or repo ownership assumptions change.
