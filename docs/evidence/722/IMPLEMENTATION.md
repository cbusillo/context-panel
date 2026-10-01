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
entitlement changed.

## Product screens

- Mac navigation has named accounts, Overview and Deadlines. Account details
  show each window and banked inventory. Pace/cache/history/provider diagnostics
  remain in detail disclosures and existing provider navigation.
- Settings uses Accounts, Updates, Alerts and Display tabs. Show in widgets
  does not pause active collection/warnings. Use last affects recommendations.
  Remove/reorder remain supported. Name edits persist on submit/focus loss.
  Older paused accounts retain Resume updates while the owner migration question
  is pending. Session/auth file controls are in Advanced.
- Add account offers existing Codex homes discovered by file metadata within a
  user-selected folder, owned Claude sign-in, or the existing Antigravity setup.
  It never scans ungranted home folders or displays credential contents.
- Widgets default to account rows, preserving Windows layout as a Display
  setting. Medium/large rows open their own account; small opens closest or the
  displayed saved account. Exact reset/expiry minutes remain visible. A More
  accounts link handles bounded widget space. No macOS extra-large family added.
- iPhone/iPad and Vision Pro share account pages and links. Existing settings,
  pace and sync diagnostics remain available. TV full detail uses six named
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
acceptance. The signed canonical Production app was preserved. Its fingerprint
is from #720, not this source. Its timeline freshness check remains pending; no
Development installation, widget-placement reset or daemon restart occurred.

Widget text contrast against the documented surface palette, computed with the
WCAG relative-luminance formula:

| Theme | Primary | Secondary/reset/expiry text |
| --- | ---: | ---: |
| Light | 18.96:1 | 6.88:1 |
| Dark | 14.12:1 | 7.77:1 |

The TV focus/percentage change is built natively; physical focus and composited
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
