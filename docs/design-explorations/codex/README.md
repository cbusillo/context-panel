# Clear Skies

Codex (GPT-6.1 Sol) · DX-CODEX-D0 · October 1, 2026

## Concept in five lines

1. Lead with permission to keep working, then name the account to use next.
2. Give the recommendation a soft blue surface and a genuinely larger number.
3. Make OpenAI, Claude and Google unmistakable through words and restrained provider accents.
4. Reserve red and triangles for a forecast that runs out before its own reset.
5. Turn Deadlines into one chronological agenda: one expiry, one place, full account identity.

Battery inspires the single capacity answer; Weather inspires the quiet tonal depth;
Screen Time inspires grouped, readable supporting detail. This is a new exploration,
not a revision of the accepted product direction or an implementation proposal.

## Mockups

Each HTML file contains all of its CSS and the complete synthetic fixture inline.
Open it directly; no server, network, fonts, packages or app runtime is required.
PNGs are page-only Chrome headless captures at 2×, not screen captures.

| Surface | Logical size | Light | Dark |
| --- | --- | --- | --- |
| Mac overview | 1120 × 900 | [HTML](mac-overview-light.html) · [PNG](mac-overview-light.png) | [HTML](mac-overview-dark.html) · [PNG](mac-overview-dark.png) |
| Mac Deadlines | 1120 × 900 | [HTML](mac-deadlines-light.html) · [PNG](mac-deadlines-light.png) | [HTML](mac-deadlines-dark.html) · [PNG](mac-deadlines-dark.png) |
| Small widget | 172 × 172 | [HTML](widget-small-light.html) · [PNG](widget-small-light.png) | [HTML](widget-small-dark.html) · [PNG](widget-small-dark.png) |
| Medium widget | 360 × 172 | [HTML](widget-medium-light.html) · [PNG](widget-medium-light.png) | [HTML](widget-medium-dark.html) · [PNG](widget-medium-dark.png) |
| Large widget | 360 × 376 | [HTML](widget-large-light.html) · [PNG](widget-large-light.png) | [HTML](widget-large-dark.html) · [PNG](widget-large-dark.png) |

## What I dropped on purpose

- Six tiny rings in the small widget. It gives one OpenAI recommendation and a
  two-risk count. The medium offers one recommendation per provider; the large
  preserves all six identities. Small and medium defer risk identities to the app.
- Pace multipliers, burn units, even-pace ticks and dual-window charts on glance
  surfaces. The overview retains 5-hour balances as secondary context. Burn is
  used to derive weekly risk, not displayed as another competing number.
- Numeric provider burn summaries and pooled run-out estimates. The two provider
  averages are explicitly averages of weekly percentages, not interchangeable
  capacity across unequal plans. The actual recommendation gets visual priority.
- The Deadlines summary tiles and horizontal timeline. Every dated banked reset
  appears once in the agenda, including the two separate entries on October 13.
- Logos, status-colored provider marks, ellipses and red for a low balance alone.
- Setup, history, cache telemetry, interactions and alternate error states in this
  finite design study. Sidebar entries are visual context, not working controls.

## Fixture and design calls

Read [owner feedback](https://github.com/cbusillo/context-panel/issues/722#issuecomment-5941284461),
latest owner-attributed comments, and [draft #737](https://github.com/cbusillo/context-panel/pull/737),
including its requested screenshots and renderer fixture. No competing trial was read.

[fixture.json](fixture.json) transcribes #737 at
`373b61902862072dc16a11a0df5327ff8d709275`,
`Tools/ContextPanelSharedViewRenderer/main.swift`, `accountFixture(now:)`.
All six account names, 12 balances, reset offsets, observed burn values and six
banked expiries are preserved. Presentation time is **2026-10-01 14:07 UTC**;
UTC is explicit to keep comparison faithful to #737 rather than shifting dates.

| Account | Week left | 5-hour left | Recommendation |
| --- | --- | --- | --- |
| A deliberately long OpenAI account name | 15% | 60% | Weekly risk |
| work@example.invalid | 72% | 88% | OpenAI next |
| Personal | 89% | 100% | Use last, as in the fixture |
| Claude primary | 37% | 22% | Weekly risk |
| Claude backup | 57% | 95% | Claude next |
| Antigravity | 91% | 100% | Google next |

A weekly risk means `(100 − used) / observed burn < hours until reset`.
The two projected weekly run-outs are Friday 11:27 PM and Monday 11:49 PM;
these are estimates at unchanged observed use, not promised clock deadlines.
The exact minute is retained for fixture comparison, but a production glance
should round forecast times. Claude primary's 5-hour balance lasts about 88
minutes at its observed burn; its reset is in 73 minutes. Therefore **22% is
not red**. Unknown short-window burn remains unknown in the embedded fixture.

The first banked expiry is Friday October 2, 2:27 PM UTC, in 24h 20m. The next
is Monday October 5, 2:27 PM. Both precede their accounts' weekly resets. Later
expiries are October 13 (two), October 27 and November 14. No future recurring
reset is invented. Reset credit execution is outside this exploration.

The blue hero names an eligible next account, rather than retaining a stable
saved main-limit answer. That is a deliberate trial design choice requiring
selection and behavioral review before any app implementation. OpenAI leads
small and medium because it is first in the supplied fixture; “Personal” remains
last. A medium widget's three recommendations are alternatives by provider,
not a claim that their capacity can be shared.

## My three-second glance check

Design-author heuristic, in both appearances at intended point size; **not a
measured participant study or owner acceptance**. “Pass” means I can identify the
answer from the first visual hierarchy without decoding a chart.

| Surface | First answer | Self-check result |
| --- | --- | --- |
| Mac overview | Room to keep going; use work@example.invalid, Claude backup or Antigravity. Two red weekly accounts are the exceptions. | Pass for next account and risk identities; exact run-out/reset times need a second scan of the bottom strip. |
| Mac Deadlines | The long OpenAI account loses its next banked reset Friday October 2 at 2:27 PM, before the weekly reset. | Pass for earliest expiry; later expiries require reading down the agenda. Capacity watch retains the safe alternatives. |
| Small | OpenAI → work@example.invalid, 72% week left; two accounts need attention elsewhere. | Pass for the main decision. Deliberately fails full six-account coverage and risk identification. |
| Medium | OpenAI → work@example.invalid; Claude → Claude backup; Google → Antigravity; two weekly risks. | Pass for each provider's next account. Risk identities and reset times are deferred. |
| Large | Follow the three arrows; red triangles identify the long OpenAI account and Claude primary; next banked expiry tomorrow at 2:27 PM. | Pass for next accounts and exceptions. Exact weekly run-out times are deferred to the app. |

## Render verification

Inspected all ten rendered PNGs across two visual-review passes. Initial Mac
bottom clipping and widget footer collisions were corrected. Final browser
checks report matching viewport/document sizes and no off-canvas inspected
content; [render-checks.json](render-checks.json) records each surface. Visual
inspection also checks footer separation and full names, which an overflow
check alone cannot establish.

Palette contrast calculated with WCAG relative luminance on declared blue
surface bases (light `#e8f2fc`, dark `#263f59`):

| Text role | Light | Dark |
| --- | --- | --- |
| Primary | 12.66:1 | 9.81:1 |
| Secondary | 5.33:1 | 5.68:1 |
| Recommendation | 6.18:1 | 6.97:1 |
| Run-out risk | 6.07:1 | 5.40:1 |
| Claude identity | 5.60:1 | 6.22:1 |
| Google identity | 5.84:1 | 5.91:1 |

These are base-token calculations, not pixel-by-pixel contrast measurements of
the gradients. Primary widget labels are 12–14px; the large account names are
12px. Secondary widget annotations still reach 9–11px: a remaining readability
tradeoff, although the decision no longer depends on those annotations.

To reproduce with existing Node and Chrome (no installs):

```sh
node docs/design-explorations/codex/capture.mjs
```

`CHROME_BIN` may point to an already installed Chromium binary. The capture
script uses a private temporary browser profile outside the worktree, closes
its own browser and removes that profile. It records 2× PNGs and layout checks.
All HTML is static; no app build, runtime, WidgetKit placement, interactions,
IDE app-code inspection or physical device behavior is claimed. This draft is
for comparing the three independent design directions. Nothing is merged.
