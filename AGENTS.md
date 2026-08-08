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

The only valid local runtime for app/widget testing is the canonical installed
app:

```text
/Applications/Context Panel.app
```

Do not test app, widget, login-item, provider, sandbox, or storage behavior from
an arbitrary DerivedData, `.build`, `/tmp`, or worktree app bundle. Build outputs
are allowed as intermediate artifacts only; the runtime gate must install the
fresh build to `/Applications/Context Panel.app`, register that app and its
embedded widget, and quarantine or unregister competing bundles with the same
bundle identifiers.

Before telling Chris the app/widget are ready to test, run the runtime baseline
receipt and require it to pass:

```sh
scripts/context-panel-runtime-baseline.sh check
```

For TestFlight, App Store, or other signed Production companion validation, use
the read-only Production receipt and require both the app and refresh agent to
report `Production` CloudKit:

```sh
scripts/context-panel-runtime-baseline.sh check --require-production-runtime
```

For routine physical watchOS complication testing, first confirm that the new
build has reached the Watch, then restart the Watch before judging complication
UI or behavior. The current TestFlight/watchOS runtime can keep the previous
WidgetKit extension or render active until a post-install restart, so do not
treat pre-restart stale or blank complication output as an application-code
regression. Skip the restart only when Chris explicitly asks to investigate the
in-place upgrade path; in that case preserve existing placements and capture the
installed build, face state, app diagnostics, and extension-process evidence
before any recovery action. Do not use uninstall/reinstall or complication
reselection as the routine workaround.

Never run `install` or `reset` while preserving a signed Production publisher.
Those modes build a local Debug runtime with Development CloudKit and now refuse
to replace a Production, TestFlight, App Store, or unverified canonical app.

After rebuilding or reinstalling during normal development, use the in-place
install gate. This is the Development runtime path: it updates
`/Applications/Context Panel.app` and verifies the same runtime receipt while
preserving the user's placed widget:

```sh
scripts/context-panel-runtime-baseline.sh install --launch
```

Use the full reset gate only when Chris explicitly asks for a fresh install,
container/storage reset, or when cleaning up a mixed runtime:

```sh
scripts/context-panel-runtime-baseline.sh reset --launch
```

Do not claim readiness unless the receipt shows `baseline=OK`, the running app
process in `Active Processes`, PluginKit widget registration, the refresh agent,
and the `contextpanel://` URL handler all point to
`/Applications/Context Panel.app`, and the build fingerprint in that app matches
the current source tree. A receipt that says `OK: no Context Panel processes are
running` is acceptable only for passive cleanup checks; it is not enough before
asking Chris to test app, widget, provider, sandbox, storage, or login-item
behavior. If the app was closed, launch the canonical app with
`open -a "/Applications/Context Panel.app"`, rerun the baseline check, and require
the active process path to be the installed app before saying it is ready to test.
When a fresh install was requested, also require the storage/cache check to
report no persisted account config, bookmarks, snapshots, widget timelines,
background-refresh settings, limit-warning settings, limit-warning notification
state, pending limit-warning notifications, webhook settings, webhook delivery
state, or webhook credentials.
Treat any mismatch as a blocker. Avoid repeatedly opening `contextpanel://`
during ordinary validation; use that only for explicit widget click-through
testing, because URL activation can change the visible app window state.
For launched app/widget readiness, the WidgetKit cache receipt must show real
Context Panel render snapshot or timeline files; placeholder-only Chrono cache
files are a blocker even if WidgetKit has cache files on disk.

The install gate is the normal "ready to test" path. The reset gate can make
macOS refresh widget registrations and may still disturb placement; after a
reset, verify whether the widget is still present before asking Chris to test
widget UI. Do not clear WidgetKit/Chrono placement directories or restart
`chronod` unless explicitly testing widget placement/reset behavior; use
`--reset-widget-placement` only when removing the widget from the UI is
acceptable.

- Record the current branch, default branch, and dirty state with
  `git status --short --branch` before editing, packaging, or installing.
- Do not package or install from a dirty multi-workstream tree unless Chris
  explicitly asks for a scratch dogfood build. If the tree already contains
  broad unrelated changes, pause and propose a cleanup/split plan first.
- Before judging UI, widget, login-item, provider, sandbox, or storage behavior,
  verify that the foreground app process, WidgetKit extension, URL handler, and
  refresh agent all resolve under `/Applications/Context Panel.app`. A DerivedData
  app, widget, or login item is a mixed runtime and must not be called fixed.
- Auto-review or agent worktrees must not leave globally registered WidgetKit or
  LaunchServices bundles behind. Prefer `swift build`/`swift test` for review
  work. If an agent must build the Xcode app target, run the runtime reset gate
  afterward so stale `.code/working`, DerivedData, `/tmp`, and repo `.build`
  app/widget artifacts are quarantined or unregistered.
- For signed/App Store-style validation, terminal success is not proof that the
  app works. Reproduce provider reads from the signed app or signed refresh
  agent, because sandbox, TCC prompts, security-scoped bookmarks, app groups,
  and login-item environment differ from an interactive shell.
- When touching app groups, widget mirrors, bookmarks, account IDs, or snapshot
  merging, inspect the active storage roots before and after validation:
  `~/Library/Application Support/Context Panel`,
  <!-- markdownlint-disable-next-line MD013 -->
  `~/Library/Group Containers/MM5YXC7T6E.group.com.shinycomputers.contextpanel/Context Panel`,
  and
  <!-- markdownlint-disable-next-line MD013 -->
  `~/Library/Containers/com.shinycomputers.contextpanel.widget/Data/Library/Application Support/Context Panel`.
- Snapshot merge or account-ID changes must include a duplicate-account check.
  Preserving failed provider data is useful, but old logical account IDs must not
  accumulate as separate live lanes.
- App Store/TestFlight work must not remove, hide, or narrow product UI such as
  provider setup, diagnostics, history, settings, or account management without
  an explicit product decision from Chris.
- Before planning, uploading, or submitting an App Store/TestFlight build, read
  the versioning flow in `docs/release.md`. Release trains use the workflow
  `version` and `build_number` inputs, not a source-controlled bump to
  `project.yml`; every new shippable train after an accepted or rejected App
  Store version needs a fresh marketing version/build input, and the uploaded
  build's pre-release marketing version must match the App Store Review version.
- When Chris asks to check App Store Connect through the API, first use the
  direct local ASC API route documented in `docs/release.md` under "Direct App
  Store Connect API Checks." If that private operator config is unavailable,
  say so explicitly before falling back to the GitHub workflow dry-run path.
  On Chris's local operator machine, the generic discovery path starts with the
  private shell env file `~/.appstoreconnect/asc.env` and private key directory
  `~/.appstoreconnect/private_keys/`; source values only into the command
  process and pass the key with `--api-key` when needed. Do not write
  host-specific paths, key IDs, issuer IDs, private key names, JWTs, or live App
  Store Connect object IDs into public repo docs, issues, PRs, or agent
  summaries.
- CloudKit live Production schema validation uses Apple's `cktool`, not the App
  Store Connect API credentials. Before companion TestFlight or App Store Review
  submission, run the live schema gate documented in `docs/release.md` under
  "CloudKit Production Schema Gate." The local operator machine should have a
  CloudKit management token saved by `xcrun cktool save-token --type management
  --method keychain --force`, or a `CLOUDKIT_MANAGEMENT_TOKEN` provided only to
  the command process. Never commit, print, or summarize the token value.
- Physical companion dogfood installs should clean stale Context Panel
  development provisioning profiles from the target device while preserving the
  profile embedded in the newly installed build and preserving App
  Store/TestFlight profiles. Use
  `scripts/cleanup-context-panel-device-profiles.sh --device <id>` for manual
  hygiene; the visionOS dogfood fixture calls it by default. Use
  `--no-profile-cleanup` only when investigating profile state itself.
- Before opening a signed validation coordinator session, compare the previous
  and current full source manifests with
  `scripts/context-panel-surface-manifest.py compare --train <beta|rc|release>`.
  For beta work, do not open a runtime session when
  `requiresRuntimeSession=false`; automated shared-view evidence is the gate for
  render-only changes. When runtime proof is required, pass only the surfaces in
  `requiredSurfaces.actual-runtime` through repeated `--surface` arguments.
  `requiredEvidence`/`requiredSurfaces` are authoritative; `freshEvidence` is
  explanatory delta metadata and is not a complete gate. Simulator builds and
  galleries can satisfy shared-view evidence only; they never satisfy
  `actual-runtime`, which must come from the exact signed artifact.
  `requiresPlacementReview=true` remains a separate physical/OS-composited
  review requirement. RC and release train floors still require exact-build
  runtime proof for every capable shipping surface.
- After the coordinator final report is available, evaluate the full comparison
  with `scripts/context-panel-release-gate.py shadow`. Do not filter or rewrite
  `requiredSurfaces`. Carry-forward must bind to the previous approved ledger,
  the complete expected-build manifest set for every shipping surface, bounded retention, current runtime
  receipts, and compatible host OS evidence. Release evidence additionally
  binds the full comparison, configured policy, expected-build identity set,
  and exact coordinator report, and requires the exact selected approved RC.
  Final validation must also receive the same previous ledger, selected RC,
  host-OS evidence, and shadow evidence used during generation so it can
  reconstruct the ledger. Live submission requires those authoritative inputs
  even in shadow mode. Keep
  shadow mode and the current
  physical runbook authoritative until two signed shadow trains have resolved
  every disagreement; only then may the submission workflow use `enforce`.

Minimum runtime evidence before saying a signed dogfood build is ready:

```sh
git status --short --branch
ps axww -o pid,ppid,command | rg -i 'Context Panel|ContextPanel|RefreshAgent'
pluginkit -m -A -D -vvv | rg contextpanel
lsof -p <refresh-agent-pid> \
  | rg 'ContextPanelRefreshAgent|/Applications/Context Panel.app'
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

For widget/app UI changes, the SwiftPM gate is not sufficient by itself. Use the
Development install gate instead of manually opening or copying DerivedData
builds; it regenerates the Xcode project, builds the real Xcode app target,
installs the fresh app to `/Applications/Context Panel.app`, refreshes the
app/widget runtime, and prints the runtime receipt:

```sh
scripts/context-panel-runtime-baseline.sh install --launch
```

If the canonical app is a signed Production/TestFlight runtime, preserve it and
use `scripts/context-panel-runtime-baseline.sh check --require-production-runtime`
instead of installing a Development build.

Do not create backup copies of `/Applications/Context Panel.app` during normal
development installs.

The installed widget can still be older than the rebuilt app. Check
`pluginkit -m -A -D -vvv | rg contextpanel` and verify the registered extension
path is under `/Applications/Context Panel.app`. If WidgetKit is registered to
any other path, run the full reset gate before judging the widget.

The app, widget, refresh agent, and Claude cache scripts use
`MM5YXC7T6E.group.com.shinycomputers.contextpanel` as canonical shared storage.
Do not reintroduce `group.com.shinycomputers.contextpanel` as a runtime fallback;
probing that container can trigger macOS protected app-data prompts in local
builds and can split app/widget state. A wildcard Mac Team provisioning profile
may not carry the app-group entitlement, which can make the widget show a
`current-snapshot.json` read error even while the app can read data. For release,
use a provisioning profile with the app group enabled. For local development,
prefer an ad-hoc-signed install over a wildcard profile when testing the live
widget. If building with `CODE_SIGNING_ALLOWED=NO`, ad-hoc sign the app,
extension, and debug dylibs with their entitlements before installing. The app
also mirrors the current snapshot to the widget extension container as a
local-development fallback. The app-side copy path is the widget container under
`~/Library/Containers`, while the widget reads it through its sandbox-local
Application Support directory; keep that split in mind when debugging why the app
and widget disagree.

## Repo Workflow

- Default branch: `main`.
- Work on focused branches and open pull requests.
- Keep `.github/github.json` current when docs, validation gates,
  important workflows, or repo ownership assumptions change.
