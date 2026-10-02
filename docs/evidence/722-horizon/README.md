# Horizon design for #722

Chris chose the Horizon exploration (#739) and two pieces from Clear Skies (#740)
([decision](https://github.com/cbusillo/context-panel/issues/722#issuecomment-5943020290),
[borrowed pieces](https://github.com/cbusillo/context-panel/issues/722#issuecomment-5943067567)).
This branch builds it on #733 with the #737 refinement merged in, through the shared presentation
files only: `Sources/ContextPanelCore/AccountPresentation.swift` (words, colours) and
`AccountPace.swift` (the horizon model, headline and formats).

## What every surface now shares

- **One sentence first:** `AccountOverview.headline(now:)` + `AccountTerms.headline` /
  `compactHeadline`. "2 accounts run out before they reset. The other 4 are fine." Only current readings
  with observed burn count as fine. When some are measuring or not current, the lead says how many are known
  to last ("4 of 6 accounts last to their reset.") instead of reassuring.
- **Horizon per account:** `Account.horizon(now:)` follows the long window that runs out first before its
  reset (a fast-burning model limit is never hidden), else the tightest long window. A window already at 0% counts
  as out now. When it is not the account-wide week, its name is said ("Opus · Week resets …"). It shows: share left now,
  observed burn, run-out if it comes before the reset, share to spare at the reset. `geometry(now:deadlines:)`
  gives every surface the same shape as fractions, so the Mac, widgets, iPhone, Watch, TV and Deadlines
  draw one picture at different sizes.
- **Red means one thing:** an account runs out before its reset. It is drawn as the hatched gap between
  the run-out and the reset, and written as "Runs out Fri ~11 PM" / "Empty 3½ days until it resets Tue 2:07 PM".
- **Provider identity:** name plus its own hue (teal OpenAI, ochre Claude, violet Google), no letter badges.
  Every provider hue meets 4.5:1 as text on `surface`, `card` and the new `nextSurface` (tested).
- **From Clear Skies:** the calm "use next" card surface (`nextSurface`) and the single "Runs out before
  reset" callout, which also says when a banked reset lapses before the account runs out.
- **Agent snapshot:** additive `headline` (lead, rest, counts, `runsOutBeforeResetAccountIDs`), per-account
  `display.outcome/outcomeDetail/outcomeShort/runsOutBeforeReset/runsOutAt/spareFraction`, and per-provider
  `summary/summaryOutlook`. A test checks they equal what the views show.

## Facts dropped on purpose (Horizon), and where they still are

| Fact in #737 | Now |
|---|---|
| Pace multiplier and pace word per account (3.6×, "under pace") | Account detail only; the overview shows it as the shape's slope and "to spare" / "Runs out". |
| Tightest card | The sentence and the callout; the account is still its row. |
| Even-pace tick on bars | Account detail ("Even pace" fact) only. |
| Amber "close to limit" and green status dots | Removed. State words stay for saved, paused, not updating. |
| NEXT / LAST pills, letter marks | "Use next" / "Use last" as words; provider name in its hue. |
| Combined 5-hour %, combined pace per provider | Agent snapshot `providers[]` keeps them; views show "% left on average · burn · N of M run out". |
| Deadlines tiles and 30-day timeline | One day-by-day agenda plus a week map; counts and next expiry in its summary line. |
| Medium widget: every account's row, banked line | Use-next card per provider; risk is the red provider outlook. |
| Large widget: 5h meters, 3-line deadline list | 5h as text; one banked callout with "+N". |
| Exact minutes on projections | "~11 PM"; real resets and banked expiries keep exact minutes. |

Kept on purpose against the Horizon README: combined burn per provider ("0.3%/h"), because Chris asked
for combined usage, run-out and burn per provider on the f8d024c build.

Not changed: the Use next rule (most room, every window has room, respects Use last). Horizon's README
also skips accounts that run out first; in this fixture the result is the same.

## Evidence

`after/` comes from `Tools/ContextPanelSharedViewRenderer` at 2× with the shared six-account fixture
(Thu Oct 1 2026, 2:07 PM). The before set is #737's head `373b619`, committed in `docs/evidence/722-d1/after/`.
These are headless shared-view renders, not the installed app or placed widgets. The Deadlines canvas is
now 900×1060.
