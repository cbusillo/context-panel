# Account design implementation

The implementation branch is `work/722-account-design-implementation`, stacked
on #720 source `1942caa`. #723 remains the original design record. #722 authorizes
this independent source work while #720's installed hand test waits for Chris.

## Shared behavior

`AccountOverview` is the common account projection for the Mac app, widgets,
iPhone/iPad, Vision Pro, TV and credential-free agent reader. The tightest known
window supplies remaining capacity. Reliable closest and per-provider Use next
answers require current, quantified windows; Use next also requires room in every
window and skips Use last. Saved order breaks ties. Saved/unknown/reset-assumed
rows are never live recommendations. Known expired banked offers disappear at
the deadline; missing dates stay unknown. Saved offers remain marked last seen.

Display metadata adds only opaque IDs, typed local labels, and display/status
flags to the existing companion payload. Older payloads remain readable. No
credential contents, paths or provider-derived identity are added. Presentation
receipts bind changed labels, order, visibility, Use last and layout through
hashes rather than emitting those private values. No CloudKit server schema or
entitlement changed. Remote metadata follows all retained account feeds, including
other Macs; it preserves newest settings for the same configured source.
Chris's recorded decision makes removal global. Explicit opaque deletion markers
are merged independently of usage age; updated Macs consume them before provider
reads, and companions omit removed usage, status, cache and display rows. Offline
publishers cannot revive the lane. Re-adding creates a new membership. Historical local removals are not promoted
to global decisions. Shared built-in configuration IDs are not deletion keys:
the observed provider lane identifies a default login, preserving another Mac's different login. Unread built-in defaults use a persistent random publisher
identity to distinguish their setup memberships; old anonymous placeholders are
retired during migration, with duplicate-account checks. Local credential keys
and observed companion identities do not change. Deletion markers bind to the resolved CloudKit user scope. Credentials,
bookmarks, home folders and local history remain. Configured but never-connected
rows from another Mac survive until explicitly removed. Older builds must be
updated to consume the deletion markers; their next remote publish is still filtered
by an updated merger.

## Product screens

- Mac navigation has named accounts, Overview and Deadlines. Account details
  show each window and banked inventory. Pace/cache/history/provider diagnostics
  remain in detail disclosures and existing provider navigation.
- Settings uses Accounts, Updates, Alerts and Display tabs. Show in widgets
  does not pause active collection/warnings. Use last affects recommendations.
  Remove/reorder remain supported; removal confirms its all-Macs/companions scope.
  Name edits persist on submit/focus loss. The actual text input has a 220pt minimum,
  and the Settings window enforces a usable minimum size. Source-unavailable warnings
  remain visible outside Advanced without exposing paths.
  Older paused accounts retain Resume updates while the owner migration question
  is pending. Session/auth file controls are in Advanced.
- Add account offers existing Codex homes discovered by file metadata within a
  user-selected folder, owned Claude sign-in, or the existing Antigravity setup.
  It never scans ungranted home folders or displays credential contents. Codex
  addition commits the source and bookmark under the existing refresh lock; a
  busy refresh saves no empty account and leaves the sheet open to retry. Home
  changes/auth-mode switches/resume also prevent two enabled entries sharing a
  reserved home, with Change home and Remove available as supported remedies.
- Widgets default to account rows, preserving Windows layout as a Display
  setting. Medium/large rows open their own account; small opens closest or the
  displayed saved account. Exact reset/expiry minutes remain visible. A More
  accounts link handles bounded widget space. No macOS extra-large family added.
- iPhone/iPad and Vision Pro share account pages and links. Existing settings,
  pace and sync diagnostics remain available, including an Accounts/Windows
  layout switch so retained limit selection and reorder controls still work. TV full detail uses six named
  cards with fixed name/number areas; focus changes only the outline. Privacy
  modes and legacy provider detail remain. Top Shelf shows up to six account
  cards when typed display metadata is present; legacy/privacy payloads keep
  anonymous provider cards. Top Shelf's single composited item opens the TV
  account overview. Watch hierarchy is unchanged.

## Evidence and limits

`native/` contains actual shared SwiftUI captures, generated without launching or
registering an app/widget bundle and using synthetic accounts only. The original
HTML design evidence in `proposed/` is distinct from these captures. These are
shared-view evidence, not installed app, WidgetKit placement, sandbox or device
acceptance. Chris authorized signed installation and desktop interaction in #719 comment
5931669062. The agent inspected the canonical app and installed the signed candidate
in place, preserving Production CloudKit, entitlements, data and widget placements.
Private desktop captures stay outside the repository. Final source identity and
runtime acceptance are recorded on #719/#722; no Development installation, widget
placement reset or daemon restart occurred. Chris's own acceptance remains required.

Widget text contrast against the documented surface palette, computed with the
WCAG relative-luminance formula:

| Theme | Primary | Secondary/reset/expiry text |
| --- | ---: | ---: |
| Light | 18.96:1 | 6.88:1 |
| Dark | 14.12:1 | 7.77:1 |

The installed Overview exposed bright purple banked text on the dark pane. Shared
views now use primary text for banked counts and expiry text; the reset icon and
labels convey the meaning. The TV focus/percentage change is built natively; physical focus and composited
Top Shelf acceptance await the matching signed build. Companion publication,
release integration and #720 acceptance remain separate gates.

Reproduce one synthetic capture after `swift build`:

```sh
swift run ContextPanelSharedViewRenderer --fixture healthy \
  --family systemMedium --appearance light --presentation widget \
  --scenario six-accounts --output /absolute/private-output/widget.png
```

Use `account-overview`, `account-deadlines` or `account-detail` for the new shared
panels. The output must not already exist. Widget-family support remains the
operator gallery's supported macOS family set.

## Open review boundary

Claude Opus 5.5 rechecked `9618da6` and found one remaining low-severity case:
configured no-data rows from a secondary Mac can disappear when another Mac
publishes. Rows with observed data are retained correctly, including settings
edits. Publisher provenance/removal scope is unresolved on #722; this remains
open before PR readiness. The current single-Mac saved-data read returns all six
configured accounts without reading credentials.
