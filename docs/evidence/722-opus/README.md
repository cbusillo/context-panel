# Design alternative (Claude Opus) for #722

An independent pass on the Mac overview, account detail and account widgets,
for comparison with the account-first design on
`work/722-account-design-implementation` (draft #733). It answers Chris's
feedback on #722: the current build went simple and lost information, and it
is not beautiful.

## Rationale

The account stays the unit, as #722 agreed. What changes is how much each
account row says at a glance:

- **Both windows, not one number.** Every row shows the 5-hour and weekly
  windows side by side, each with its percent left, its reset time and a bar.
  The tightest window's number is bold, so "which window is binding" needs no
  extra label.
- **Pace without reading.** Each bar carries a thin tick where an even spend
  across the window would be now. A bar ending left of its tick is burning
  ahead of plan. Where per-account burn history exists, a pace ratio
  (`3.6×`) and a projected run-out time ("out Fri ~11 PM") appear, in red only
  when the run-out comes before the reset. Projections are shown to the hour,
  with `~`, because they are estimates; resets and banked expiries stay to the
  minute.
- **The week as a picture.** The Mac overview ends each row with a seven-day
  lane: the bar runs to the weekly reset, turns red where this pace would run
  out first, and diamonds mark banked-reset expiries. Reading down the column
  answers "what happens this week" for every account at once.
- **Three answers on top, with numbers.** Tightest (ring, window, reset,
  run-out), Use next (one per provider, with its headroom), and Banked resets
  (next expiry with a countdown, then the following two).
- **Widgets show every account.** Small is a 3×2 grid of rings (tightest
  percent per account, a blue dot on the use-next account) with the next banked
  expiry. Medium is a six-row table: 5h and week with bars, then the next
  reset or a red run-out. Large gives each account two lines (name, banked
  count, run-out and pace; then both windows with their reset times) and lists
  the next three banked expiries.
- **Colour means status only.** Bars are a calm green until 25% left (amber)
  and 10% (red). Banked resets use cyan with a reset glyph, never purple. Every
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
| All six accounts in the small and medium widgets (#733: one and four) | |
| The next three banked expiries in the overview and large widget (#733: one) | |
| Burn per hour, even-pace share and run-out on account detail | |

## Data

No new provider reads. Pace uses the per-account burn the app already
estimates (`AccountBurnRateEstimator`); `WidgetSnapshot` gains an optional
`accountBurnRates` so widgets get the same figures. Older payloads decode
unchanged and show "measuring" instead of a ratio. Even-pace marks need only
the window length and reset time, so they work without history.

## Screenshots

`before/` is #733's head `2109f20`; `after/` is this branch. Both come from
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
