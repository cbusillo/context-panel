# iPhone and iPad companion for #809

The account-first Horizon design (#722) already draws on the companion. This change fixes two gaps the
[design note](https://github.com/cbusillo/context-panel/issues/809#issuecomment-6104785815) found, in the
companion only; the Mac app is unchanged.

- **Account table by measured width, not size class.** `CompanionLayoutPolicy.usesAccountTable(width:)` uses
  the Mac table only when the companion window is at least 900 points wide, the width of the Mac account pane.
  Narrower windows, including regular-width iPad portrait (834) and iPad mini portrait (744), use the stacked
  rows, so account names no longer break mid-word. iPad landscape (1194) keeps the table.
- **One "Sync and settings" row** replaces the closed "Settings, pace and sync details" disclosure. It opens a
  page with sync status first, then the widget preview, the keep-working card, provider access, banked
  resets, and the display and refresh settings. Nothing was removed.

Stale presentation is #807's and is not changed here.

## Evidence

`before/` is `main` at `d29abb0`; `after/` is this branch. Both are synthetic captures at 2× from a
throwaway harness that renders the companion's composition with the shared views and the six-account
fixture of `Tools/ContextPanelSharedViewRenderer` (Thu Oct 1 2026, 2:07 PM UTC) on iOS 27 simulators.
The navigation bar is a stand-in, and these are not the installed app. Files are reduced to 256 colours
to keep them small.

| File | Shows |
|---|---|
| `before/ipad-portrait-overview-light.png`, `after/…` | iPad portrait, 834 pt: wrapped names, then stacked rows |
| `before/ipad-mini-portrait-overview-light.png`, `after/…` | iPad mini portrait, 744 pt |
| `after/ipad-landscape-overview-light.png` | iPad landscape, 1194 pt: the table, unchanged |
| `before/iphone-overview-details-expanded-light.png` | iPhone with the old disclosure opened |
| `after/iphone-overview-light.png` | iPhone main screen ending in the Sync and settings row |
| `after/iphone-sync-and-settings-light.png` | The Sync and settings page on iPhone |
