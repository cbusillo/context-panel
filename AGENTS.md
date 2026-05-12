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
- For weekly or rolling account limits, include forecast language that helps the
  user decide whether higher-burn modes are safe before reset.
- Avoid making the widget a dashboard crammed into a rectangle. Put setup,
  troubleshooting, raw details, and long histories in the app.
- Clicking the widget should open the app to the most relevant provider/account
  detail.
- Prefer plain status language: available, close to limit, limited, unknown,
  stale, refreshing.

## Validation

Before changing or validating app/widget/provider behavior, identify the active
runtime. Mixed runtimes caused repeated false positives during App Store release
prep, so treat them as a blocker rather than background noise.

- Record the current branch, default branch, and dirty state with
  `git status --short --branch` before editing, packaging, or installing.
- Do not package or install from a dirty multi-workstream tree unless Chris
  explicitly asks for a scratch dogfood build. If the tree already contains
  broad unrelated changes, pause and propose a cleanup/split plan first.
- Before judging UI, widget, login-item, provider, sandbox, or storage behavior,
  verify that the foreground app process, WidgetKit extension, and refresh agent
  all come from the intended bundle root. A DerivedData app paired with a
  `/Applications` widget or login item is a mixed runtime and must not be called
  fixed.
- For signed/App Store-style validation, terminal success is not proof that the
  app works. Reproduce provider reads from the signed app or signed refresh
  agent, because sandbox, TCC prompts, security-scoped bookmarks, app groups,
  and login-item environment differ from an interactive shell.
- When touching app groups, widget mirrors, bookmarks, account IDs, or snapshot
  merging, inspect the active storage roots before and after validation:
  `~/Library/Application Support/Context Panel`,
  `~/Library/Group Containers/group.com.shinycomputers.contextpanel/Context Panel`,
  and
  <!-- markdownlint-disable-next-line MD013 -->
  `~/Library/Containers/com.shinycomputers.contextpanel.widget/Data/Library/Application Support/Context Panel`.
- Snapshot merge or account-ID changes must include a duplicate-account check.
  Preserving failed provider data is useful, but old logical account IDs must not
  accumulate as separate live lanes.
- App Store/TestFlight work must not remove, hide, or narrow product UI such as
  provider setup, diagnostics, history, settings, or account management without
  an explicit product decision from Chris.

Minimum runtime evidence before saying a signed dogfood build is ready:

```sh
git status --short --branch
ps axww -o pid,ppid,command | rg -i 'Context Panel|ContextPanel|RefreshAgent'
pluginkit -m -A -D -vvv | rg contextpanel
lsof -p <refresh-agent-pid> \
  | rg 'ContextPanelRefreshAgent|Context Panel.app|DerivedData|/Applications'
codesign -d --entitlements :- "/Applications/Context Panel.app" 2>/dev/null
shasum -a 256 \
  "/Applications/Context Panel.app/Contents/MacOS/Context Panel"
```

If any of those point to different build roots or unexpected entitlements, stop
and report the mixed-runtime state before making more fixes.

Run the commit gate before publishing changes:

```sh
scripts/commit-gate.sh
```

For UI work, also run the native app/widget locally and inspect the actual macOS
presentation before calling the work ready.

For widget/app UI changes, the SwiftPM gate is not sufficient by itself. Also
regenerate the Xcode project when `project.yml` or source membership changes,
build the real Xcode app target, replace the installed development app, and
restart the app/widget extension:

```sh
xcodegen generate
xcodebuild -project ContextPanel.xcodeproj -scheme ContextPanel \
  -configuration Debug -derivedDataPath .build/xcode-derived-signed build
pkill -9 -f '/Applications/Context Panel.app/Contents/MacOS/Context Panel' || true
pkill -9 -f 'ContextPanelWidgetExtension.appex' || true
rm -rf "/Applications/Context Panel.app"
ditto \
  ".build/xcode-derived-signed/Build/Products/Debug/Context Panel.app" \
  "/Applications/Context Panel.app"
open "/Applications/Context Panel.app"
```

Do not create backup copies of `/Applications/Context Panel.app` during normal
development installs.

The installed widget can still be older than the rebuilt app. Check
`pluginkit -m -A -D -vvv | rg contextpanel` and verify the registered extension
path. If WidgetKit is registered to an old DerivedData path, rebuild/register
that path or remove the stale registration before judging the widget.

The widget needs access to `group.com.shinycomputers.contextpanel`. A wildcard
Mac Team provisioning profile may not carry that app-group entitlement, which
can make the widget show a `current-snapshot.json` read error even while the app
can read data. For release, use a provisioning profile with the app group
enabled. For local development, prefer an ad-hoc-signed install over a wildcard
profile when testing the live widget. If building with `CODE_SIGNING_ALLOWED=NO`,
ad-hoc sign the app, extension, and debug dylibs with their entitlements before
installing. The app also mirrors the current snapshot to the widget extension
container as a local-development fallback. The app-side copy path is the widget
container under `~/Library/Containers`, while the widget reads it through its
sandbox-local Application Support directory; keep that split in mind when
debugging why the app and widget disagree.

## Repo Workflow

- Default branch: `main`.
- Work on focused branches and open pull requests.
- Keep `.github/github.json` current when docs, validation gates,
  important workflows, or repo ownership assumptions change.
