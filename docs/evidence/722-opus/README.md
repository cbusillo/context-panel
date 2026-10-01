# Design alternative (Claude Opus) for #722

An independent pass on the Mac overview, account detail and account widgets,
for comparison with the account-first design on
`work/722-account-design-implementation` (draft #733). It answers Chris's
feedback on #722: the current build went simple and lost information, and it
is not beautiful.

## One source for every surface

Chris chose this direction on #722 with one condition: terms, amounts and style
consistent across all apps and surfaces. `Sources/ContextPanelCore/AccountPresentation.swift`
is that source:

- `AccountTerms`: every word ("% left", "Tightest", "Use next", "Banked resets",
  "out Fri ~11 PM", "measuring", "NEXT", "LAST").
- `AccountNumbers`: whole percent left (never "used" on a glance surface) and pace as `3.6×`.
- `AccountPaceText` (in `AccountPace.swift`): dates. Time only today, weekday and
  time within a week, month and day beyond; projections to the hour with `~`;
  countdowns `in 1d 0h`.
- `AccountTone` and `AccountColorToken`: headroom tones and sRGB light/dark tokens.
  Each UI module turns tokens into `Color` and defines no colour values of its own.
- `AccountCapacityState.displayText`, `glyphName`, `colorToken`, and
  `UsageStatus.accountState`: one set of status words and marks. Top Shelf, TV runway
  and Watch lane status words now map through it: "Saved" where a saved value is shown (not
  "Saved data" or "stale"), and "Not updating" for a failed read with nothing saved (not
  "Needs attention" or "refresh failed").

| Surface | Views | Shows |
| --- | --- | --- |
| Mac overview and detail | `AccountDashboardPanel`, `AccountDashboardDetail` | everything |
| Mac and iPhone/iPad widgets | `AccountGlanceWidget` | up to six accounts; small: rings; medium: both windows; large: pace and three deadlines |
| iPhone app | the Mac views with `compact: true`; iPad keeps the table | everything, stacked |
| Watch app | `WatchAccountRow`, `WatchBankedLine` (WatchSupport) | percent, both windows, run-out or reset, next deadline |
| Watch complications | `WatchAccountRectangularFace`, `WatchAccountCircularFace` (WatchSupport) | tightest account, both windows, next deadline or run-out; inline and corner keep their lane text |
| Apple TV | `TVAccountBoard`, `TVAccountTile`, `TVAccountAnswers` (TVSupport) | everything but the week lane; fixed row heights keep the large percentages on one baseline |
| Agent snapshot | `AgentAccountSnapshot.Display` | the same strings per account, plus `answers.tightestAccountID` |

Companions omit pace when the synced payload carries no per-account burn (today it does
not), rather than saying "measuring" while the Mac shows a number.

## Rationale

The account stays the unit, as #722 agreed. What changes is how much each
account row says at a glance:

- **Both windows, not one number.** Every row shows the 5-hour and weekly
  windows side by side, each with its percent left, its reset time and a bar.
  The second column holds the tightest of the account's longer windows, so the
  binding window is never hidden; its number is bold.
- **Pace without reading.** Each bar carries a thin tick where an even spend
  across the window would be now. A bar ending left of its tick is burning
  ahead of plan. Where this account has observed burn history, a pace ratio
  (`3.6×`) and a projected run-out time ("out Fri ~11 PM") appear, in red only
  when the run-out comes before the reset. The estimator's window-average
  fallback is not shown as burn, saved or stale data gets no pace or run-out,
  and windows whose label names no fixed length get no even-pace tick. Projections are shown to the hour,
  with `~`, because they are estimates; resets and banked expiries stay to the
  minute.
- **The week as a picture.** The Mac overview ends each row with a seven-day
  lane: the bar runs to the weekly reset, turns red where this pace would run
  out first, and diamonds mark banked-reset expiries. Reading down the column
  answers "what happens this week" for every account at once.
- **Three answers on top, with numbers.** Tightest (ring, window, reset,
  run-out), Use next (one per provider, with its headroom), and Banked resets
  (next expiry with a countdown, then the following two).
- **Widgets show up to six accounts**, with a `+N` count beyond that. Small
  is a 3×2 grid of rings (tightest percent per account, a blue dot on the
  use-next account) with the next banked expiry; with one or two accounts it
  shows the closest one large, with both windows. Medium is a six-row table: 5h and week with bars, then the next
  reset or a red run-out. Large gives each account two lines (name, banked
  count, run-out and pace; then both windows with their reset times) and lists
  the next three banked expiries.
- **Colour means status only.** The row mark is the provider-reported
  account status; bar and number colours are the window's own headroom: calm
  green until 25% left (amber) and 10% (red). So an account can be Available
  while one window is already amber. Banked resets use cyan with a reset glyph, never purple. Every
  text colour meets WCAG AA (4.5:1) on its surface in light and dark;
  status also has a shape (circle, triangle, octagon, clock).
- **No slogans.** Labels are nouns and times. State words ("Available") are
  dropped from normal rows because the mark already says it; unusual states
  ("Saved", "Not connected", "Paused") still show in words.

## What each design shows that the other does not

| Shown only in this design | Shown only in #733 |
| --- | --- |
| Both windows per account, each with its own reset time | Month and day on every reset ("Tue, Oct 6 at 2:07 PM"); this design uses weekday and time within a week |
| Even-pace mark on every bar | The state word on every row ("Available") |
| Burn pace ratio and projected run-out time | "dates incomplete" next to a row's banked count (this design shows it on account detail only) |
| A seven-day lane of resets, run-outs and banked expiries | The full account name in the small widget (this design uses short names, e.g. "primary", "backup") |
| Use-next headroom percent, and use-next marks in rows and widgets | A Deadlines explanatory line ("expiration does not use a reset") |
| Up to six accounts in the small and medium widgets, with a `+N` count (#733: one and four) | |
| The next three banked expiries in the overview and large widget (#733: one) | |
| Burn per hour, even-pace share and run-out on account detail | |

## Review by another model

OpenAI gpt-6.1-sol reviewed this rationale, the screenshots and the code
read-only. Verdict: this direction better meets the stated goal; the overview
reads dense rather than cluttered, and the medium widget is near its
readability limit. Its data findings were fixed and covered by
`Tests/ContextPanelCoreTests/AccountPaceTests.swift`: the limiting window is
always visible; saved data shows no pace or run-out and banked dates say "last
seen"; the window-average burn fallback is not shown as observed burn; window
length is no longer guessed from "session" or "day"; detail shows run-out to
the hour; VoiceOver reads both windows, pace, run-out and use-next; widgets
show a `+N` overflow count. Not changed: 8–9 pt secondary text in the medium
and large widgets (the density trade-off is the point of this comparison), and
the row mark versus bar colour difference (explained above).

## Data

No new provider reads. Pace uses the per-account burn the app already
estimates (`AccountBurnRateEstimator`); `WidgetSnapshot` gains an optional
`accountBurnRates` so widgets get the same figures. Older payloads decode
unchanged and show "measuring" instead of a ratio. Even-pace marks need only
the window length and reset time, so they work without history.

## Screenshots

`before/` is #733's head `2109f20`; `after/` is this branch. `surfaces/` adds the
iPhone, Watch and Apple TV captures from the same fixture. Both come from
`Tools/ContextPanelSharedViewRenderer` with the same synthetic six-account
fixture (fixed time Thu Oct 1, 2026, 2:07 PM UTC) at 2× scale:

```sh
swift run ContextPanelSharedViewRenderer --fixture healthy --family systemMedium \
  --appearance dark --presentation account-overview --scale 2 --output /absolute/out.png
```

Widgets use `--presentation widget --scenario six-accounts` with
`--family systemSmall|systemMedium|systemLarge`.

They are shared SwiftUI views rendered headlessly, not captures of the
installed app or a placed widget.
