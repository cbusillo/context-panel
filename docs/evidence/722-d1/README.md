# Design refinement for #722: provider identity, weekly first, provider totals, Deadlines

A second design pass on the chosen account design (#735, integrated in #733),
answering Chris's feedback on the installed `f8d024c` build
([#722 comment](https://github.com/cbusillo/context-panel/issues/722#issuecomment-5941284461)).
Every word, number, date, colour and mark still comes from
`Sources/ContextPanelCore/AccountPresentation.swift` and `AccountPace.swift`.

## What changed, and why

**Widget header: "Context Panel".** On the desktop a widget has no app label, so
the header is the only thing that says which app it belongs to; "Accounts" said
what every row already shows. In the app, the page keeps its page name
("Accounts", "Banked resets"), because the window already names the app.
`AccountTerms.widgetTitle` holds the choice, so changing it is one line.

**Week before 5h, everywhere.** The weekly window decides how much work is left;
the 5-hour window only paces it. `orderedWindows` now sorts longest first, and a
new `glanceWindows` gives every surface the same two columns in the same order
(Mac table, iPhone cards, all widget sizes, Watch, TV, agent snapshot).

**Which provider is which.** Each provider has a mark: its first letter on its
colour, a rounded square. Graphite for OpenAI, clay for Claude, violet for
Google. They are typographic marks, not logos, so nothing trademarked is
reproduced. The hues avoid the status colours (green, amber, red, saved brown,
banked cyan, next blue), so colour still means status on bars and numbers. The
mark letter meets 4.5:1 on its colour in light and dark (now part of
`AccountPresentationContrastTests`), and the provider colours meet 4.5:1 as text
on cards. On the Mac and iPhone, accounts are grouped by provider with a
provider-coloured edge; widgets put the mark in front of each name; the small
widget gives each provider its own row of rings.

**Combined usage, burn and run-out per provider** (`AccountOverview.providerTotals`).
You move work to whichever account has room, so a provider's room is the sum of
its accounts' room:

- *Combined % left*: the mean of each current account's weekly (and 5-hour) %
  left. Each account counts equally, because providers report percentages, not
  plan sizes.
- *Combined burn*: the accounts' observed burn added up, as a share of the
  combined room per hour, so `0.3%/h` reads against `59%`.
- *Combined pace*: combined burn against the burn that would land every account
  on zero at its own reset, the same meaning as an account's pace.
- *Run-out*: when the combined room runs out at the combined burn, shown only if
  that comes before the first weekly reset among those accounts (which refills
  the pool); otherwise "lasts to reset".
- Honesty rules: saved, paused and unconnected accounts are listed but not
  added ("2 of 3 current"); pace and run-out need every current account's
  observed burn, otherwise "measuring", because a partial sum would understate
  it. A provider with one account gets no combined row, since it would repeat
  that account.

Where it shows: a combined row opens each provider's group in the Mac table and
iPhone list (in the same columns as the accounts), a combined line opens each
group in the large widget, a "Combined" strip sits above the banked line in the
medium widget, the TV's Use next card carries each provider's combined line, and
the agent snapshot gains `providers[]` with the same strings. The small widget
and the Watch show less: provider grouping and marks, no combined numbers.

**A Deadlines page worth opening.** It was a plain list of names and dates. Now:

- four tiles: next expiry (date, minute, countdown, account), this week, next
  30 days, and dates unknown;
- a 30-day timeline with one lane per account: diamonds where banked resets
  expire, ticks where that account's weekly window resets on its own;
- rows grouped This week / Next 30 days / Later. Each row shows the expiry and
  countdown, the account with its provider mark, that account's weekly room
  now (number, bar, even-pace tick), and whether its weekly reset comes first.
  "Expires before week resets Tue 2:07 PM" is in the banked colour, because
  then the banked reset is the only refill before it lapses. These are facts,
  not advice; the page doesn't tell you when to spend one.
- saved offers keep "last seen"; undated offers are listed per account.

**Less plain, where it helps reading.** Provider colour carries identity
(group edges, tinted combined rows, marks), not decoration; status colours are
unchanged. In the medium widget and on the Watch, the status mark now appears
only when an account is not "Available", so the provider mark leads and names
stop truncating.

## Not changed

- No new data, provider reads, entitlements, signing or release state.
- Data-honesty guard: Owner question
  [5938597857](https://github.com/cbusillo/context-panel/issues/722#issuecomment-5938597857)
  (unverified multi-Mac feeds of one subscription) is still open. Combined
  totals add whatever accounts the overview shows. If the guard lands, it should
  stop unverified duplicates before they reach `AccountOverview`, and the totals
  follow with no view change.

## Evidence

`before/` is #733's head `a14111d`; `after/` is this branch. Both come from
`Tools/ContextPanelSharedViewRenderer` at 2× with the same synthetic six-account
fixture, at a fixed time (Thu Oct 1, 2026, 2:07 PM UTC). The fixture gained two later
banked resets for `work@example.invalid` (to fill the Deadlines groups) and an
observed weekly burn for `Personal`, and the overview, deadlines and iPhone
canvases are taller because those pages scroll. The `before/` set was rendered
from `a14111d` with the same fixture. These are shared SwiftUI views rendered
headlessly, not captures of the installed app or a placed widget.

```sh
swift run ContextPanelSharedViewRenderer --fixture healthy --family systemMedium \
  --appearance dark --presentation account-deadlines --scale 2 --output /absolute/out.png
```

Presentations: `account-overview`, `account-deadlines`, `account-detail`,
`phone-overview`, `phone-detail`, `watch-app`, `watch-rectangular`,
`watch-circular`, `tv-board`; widgets use `--presentation widget --scenario
six-accounts` with `--family systemSmall|systemMedium|systemLarge`.
