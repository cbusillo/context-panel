# Design Direction

Last updated: 2026-08-02.

## Accepted Direction

Context Panel should use **Quiet Instrument** as its default visual direction.
The product should feel like a calm Mac status instrument rather than a billing
dashboard. It should answer the user's immediate question first: can I keep
working, which saved limit is my stable reference, does a different limit need
attention now, and when will that pressure change?

The stable main answer is the first visible limit in the person's saved order.
The default order begins with OpenAI Weekly. Missing or stale data keeps that
answer in place and is described honestly instead of silently switching the
large number to another provider or time window. A separate `Closest to limit`
answer appears only for a different numeric limit that is close, limited, or at
least 20 percentage points lower than the main answer. Supporting limits retain
saved order. Visibility controls the saved list, not safety: a hidden current
limit may still appear as `Closest to limit` when it meets that rule.
If every saved limit is hidden, the interface says that no limit is selected
instead of restoring hidden rows or promoting a warning without a stable
reference. Auxiliary provider data can remain available in detail views, but
it does not replace a missing saved answer.

The widget is the glance surface. It should be dense, calm, and answer-first:
remaining capacity, the stable saved answer, meaningful limit pressure, reset
timing, refresh health, stale state, and compact prompt-cache telemetry where
available.

The app is the setup, detail, and troubleshooting surface. It can use denser
ledger treatments, diagnostics, history, account management, refresh controls,
forecast settings, webhook settings, and provider-specific setup flows without
trying to turn the widget into a dashboard.

## Widget Layout Direction

Use an instrument-first widget hierarchy:

- Small widget: use one visually dominant saved answer plus up to two quieter
  supporting limits. A useful `Closest to limit` answer takes the first
  supporting slot; any remaining slot follows saved order. The primary answer
  gets the larger remaining-capacity number and full-width bar; supporting
  limits use compact rows with explicit `left`, reset, unknown, and stale
  meaning. A single saved limit may use the larger one-limit treatment. Stale
  or setup problem copy takes priority when needed.
- Medium widget: overall/tightest status plus the most constrained provider or
  account rows, nearest reset, prompt-cache summary when enabled, and compact
  sync/refresh state.
- Large widget: provider groups, several constrained account/model rows, compact
  used-pressure bars, reset summary, prompt-cache comparison, and refresh/stale
  state.

The large widget may use a dense ledger-like treatment when realistic
multi-account data does not fit a dial-led composition. The design preference is
still instrument-first: clear pressure, reset timing, and state hierarchy before
raw completeness.

## Reset-Credit Surface Direction

Reset credits remain account-owned metadata, never pooled capacity. Full count,
expiry, freshness, and recommendation reasoning belong only in the OpenAI
account-detail rows. Higher-level surfaces acknowledge availability in existing
horizontal slots rather than adding cards or reducing visible limit rows.

- The Mac overview and OpenAI provider header use an interactive tag with a
  reset glyph and the number of credit-bearing accounts. The number always means
  accounts, never a sum of credits. The OpenAI sidebar may use the same neutral
  glyph after the provider name, with help and complete accessibility copy.
- App account detail retains positive stale or degraded observations for
  discovery and troubleshooting. Higher-level tags count current observations
  when any exist, and fall back to an all-stale `last seen` count only when no
  current observation remains. Selecting the tag opens OpenAI detail; no app
  surface performs a credit action.
- Medium and large widgets use the existing section-header baseline. Actionable
  guidance names one exact account and uses explicit `use now` or `by <date>`
  copy. Neutral availability says `Credits · N accounts` and never displays a
  global credit total.
- Medium and large widgets keep reset availability and prompt-cache telemetry
  visible together whenever both are available. Their single-line header uses a
  progressive fit ladder: cache drops its rolling average first, reset guidance
  then drops the account name and action text, and the cache label disappears
  only as a last resort. Authorization and stale-cache pills shorten to labels
  and then symbols under the same pressure. Full cache averages, account
  identity, credit counts, and guidance remain in accessibility and the app.
  Neither family gives up a saved limit row for reset-credit presentation.
- Widgets suppress reset-credit signals when the widget is stale, failed, needs
  setup, or when the credit observation is inconsistent or has elapsed. The app
  remains the place to explain and recover those states.
- The iPhone, iPad, and visionOS companion app reuses its existing large usage
  instrument rather than adding a card or section. Its in-app reset token is
  static; medium, large, and extra-large companion widgets use the same header
  treatment and open the synced overview. Companion surfaces use current
  observations only and never show the Mac app's `last seen` fallback.
- Small widgets, Watch surfaces, complications, tvOS, and Top Shelf remain
  unchanged. Their one-value, ten-foot, or highly constrained hierarchies do not
  have an honest secondary slot for account-owned reset-credit metadata.

Every Apple Watch complication family is a glance surface and shows remaining
capacity, matching the primary macOS widget answer. Circular and corner gauges
remain one-value surfaces. Inline may show the stable answer plus a useful
closest limit when both fit, otherwise it shows the next saved limit or falls
back to one clear value. Rectangular bars and inline copy use the remaining
ratio and explicit `left` language. Circular capacity gauges use a large
centered numeral. Percentage values omit the percent sign because the
surrounding ring already conveys relative capacity; absolute counts remain
unchanged, and accessibility retains the full spoken unit. Watch app rows remain
detail surfaces and
stay explicitly used-pressure while following saved main-limit visibility and
order; auxiliary provider buckets such as Spark remain in the larger app detail
views. In every case, the visible number, wording,
fill, color, and accessibility sentence describe the same quantity. Keep
unknown values indeterminate rather than substituting zero, preserve stale
last-good values with explicit freshness language, and retain saved order. Use
`Saved` in complication text for a last-good value; the Watch app and
accessibility description may use the more explicit stale explanation.
In the Watch app status row, show the freshness timestamp only for settled
available states so updating, stale, and failure labels keep their full width.
Allow those status labels to wrap rather than truncate at larger text sizes.
Keep settled-state freshness visually compact while preserving the full elapsed
duration for accessibility output.
When a Watch sync fails without saved usage, keep the plain-language failure
sentence primary and allow one quieter, bounded, sanitized diagnostic line for
troubleshooting. Let both lines wrap at large text sizes, provide explicit sync
error context to VoiceOver, and never surface that diagnostic in complications.
Keep Watch limit footers on one line when they fit. When they do not, allow the
account context to wrap and move the reset to a separate trailing line instead
of truncating either value.
Keep Watch limit headers on one line only when the complete provider, window,
and usage value fit. At larger text sizes, stack the full provider name above
the window and usage value rather than abbreviating the provider to an initial
and ellipsis.

## App Layout Direction

The native macOS app should stay a work-focused `NavigationSplitView`:

- Sidebar: provider/account groups, account status, and setup entry points.
- Detail: selected provider/account limits, capacity, reset timing, prompt-cache
  telemetry, fast-mode forecast, refresh status, and history.
- Settings and diagnostics: credential management, provider setup, account
  naming, widget lane preferences, refresh cadence, warning/webhook settings,
  and troubleshooting.

The read-only iPhone, iPad, and visionOS companion uses an adaptive composition:

- iPhone keeps the existing full-width single column with 16-point page padding
  in every orientation.
- Non-phone content widths below 824 points and accessibility text sizes use one
  centered column capped at 760 points with 24-point page padding. The order is
  usage instrument, sync status, display settings, refresh settings, then
  visionOS appearance.
- Regular-width iPad windows use an inline page header aligned with the content
  grid, with refresh beside the current sync state. Two bounded columns begin
  only after page padding leaves at least 824 points of usable content and stop
  expanding at 1240 points; the instrument column flexes from 440 to 820 points,
  the settings column remains 360 points, and the gap is 24 points.
- visionOS keeps its calmer native navigation title and bounded composition;
  iPad-specific title and width changes must not be imposed on it automatically.
  Its established 810-point breakpoint, 720/1080-point content caps, 400–720
  point instrument column, 340-point settings column, and 20-point gap remain
  unchanged.
- Resizing must preserve view identity, settings state, and accessibility
  reading order.
- The companion remains a focused read-only utility. Do not turn regular width
  into a collector dashboard, navigation sidebar, or denser telemetry surface.
- Companion status follows selected account observations. A Mac-local auth
  failure does not create a provider-wide warning when another Mac has usable
  data; saved account values remain visible with freshness language instead.

Mutation belongs in the app, not the widget: adding logins, reconnecting,
naming accounts, disabling or removing accounts, saving bookmarks, choosing
visible widget lanes, refreshing, calibration, warning configuration, and
privacy/credential messaging.

## Apple TV Direction

Apple TV uses a native ten-foot **Couch Mode**, not a stretched widget or iPad
layout. Keep the accepted three-provider, focus-driven composition, provider
drill-down, privacy modes, and explicit stale/offline states.

Each provider card applies the shared answer rule within that provider: the
first visible saved time window stays as the large answer, a distinct
`Closest to limit` line appears only when useful, and provider details keep
saved order. Provider-only auxiliary capacity remains available in detail but
does not take over the large answer when a saved time window is missing. Full
Detail, Hide Account Names, and Percentages Only change the amount of personal
detail, not answer selection. Visible percentages use `left`. Mac-to-companion
updates, saved-data behavior, focus navigation, and deep links remain separate
platform concerns and must not be coupled to shared SwiftUI components.

Provider drill-down uses a vertical hierarchy rather than a grid of equal-sized
cards: one primary-runway hero, optional Full Detail account runway, and compact
secondary-limit rows. A temporarily missing saved primary remains visible but
quiet while an available lane becomes the detail hero. The accepted
three-provider overview must not change when detail is refined.

Hide Account Names preserves per-account runway rows but replaces identity with
provider-scoped `Account N` labels reused across windows and hides raw totals.
Model sublimits remain distinct when one account has more than one limit in the
same window. Read-only lane summaries and capacity rows receive quiet,
non-button focus treatment so the Siri Remote can move through and scroll detail
without suggesting that selecting a row performs an action.

## Visual System

- Use native macOS surfaces and system typography. Prefer quiet neutral grays,
  subtle materials, and tabular numeric data over decorative panels.
- Keep one restrained accent family for selected states and primary controls;
  avoid letting one hue dominate the entire app or widget.
- Use status tints sparingly. Red should communicate genuinely limited or failed
  states, not become the baseline visual mood.
- Status must be readable from text and structure, not color alone.
- Provider identity should use short text badges plus labels. Logos or abstract
  marks must not be the only provider hierarchy.
- Layouts should be stable under dynamic data: changing reset text, account
  names, loading states, hover states, or stale messages must not resize fixed
  widget structures unpredictably.
- The widget should preserve last-good values through refresh and loading states
  whenever possible.
- Stale widget data preserves its last-good numeric value when available, colors
  its quantitative instruments with a distinct warm-neutral treatment, and
  never shares the limited/failure red.
- Remaining-capacity heroes and used-pressure detail rows are complementary, but
  an individual quantitative cluster must never cross their number and fill
  directions or rely on an unlabeled inverse value.
- When inverse whole percentages are shown for the same limit, round remaining
  capacity once and derive used capacity as its complement so the visible pair
  reconciles to 100%.
- Percent-based multi-account ledgers use pooled points plus normalized aggregate
  percentages. Summed percentage points must never be labeled as percentages
  above 100%.
- Widget accessibility groups each glance instrument, limit row, and provider
  summary into a coherent value that names provider/window, quantity direction,
  pressure status, freshness, and reset timing.

## Component Vocabulary

The durable native vocabulary lives in SwiftUI and the shared semantic model,
not in a web export. Current implementation uses shared app/widget ideas
including:

- `MetricProgress`: explicit remaining-capacity, used-pressure, neutral-rate,
  and indeterminate state with normalized display and accessibility values.
- `MetricDial`: circular metric renderer whose `MetricProgress` value states its
  meaning; remaining-capacity and neutral-rate callers must stay explicit.
- `UsagePressureBar` / `CPWUsagePressureBar`: compact used-pressure bars that
  accept optional ratios and render missing values as indeterminate.
- `ProviderBadge` / `CPWProviderBadge`: short provider badge with nearby label
  context.
- `StatusMark` / `CPWStatusMark`: compact state marker paired with text.
- account and limit rows: reusable row treatments for constrained lanes,
  reconnect actions, additional limits, and provider summaries.
- `ContextPanelWidgetUI`: shared WidgetKit-sized presentation used by macOS and
  companion widget targets.
- `ContextPanelWidget`: WidgetKit timeline, family mapping, widget URL wiring,
  app-group reads, and sandbox-local fallback behavior.
- `MainLimitAnswerSelection`: shared stable-answer, optional closest-limit, and
  saved-order selection consumed by Mac, Watch, widget, and tvOS presentation.

Keep colors, spacing, radius, typography, material, and status semantics in
native theme helpers instead of scattering raw values through views.

The semantic defaults are:

- Rings and capacity dials communicate remaining capacity.
- Linear pressure bars communicate used capacity and pair with `used` copy.
  Remaining-capacity bars are reserved for glance surfaces such as Watch
  complications and the small widget, and pair with explicit `left` copy.
- Rates such as prompt-cache hit rate remain neutral telemetry rather than being
  named or announced as capacity or pressure.
- Missing, non-finite, unavailable, and unknown ratios are indeterminate. They
  never become a determinate zero-length or zero-capacity instrument.

## Validation Gallery Direction

Validation galleries are calm diagnostic instruments, not developer preview
grids. A fixed `Sample data` boundary remains visible outside scrolling and on
every render tile. The selected state, family, and appearance are secondary to
the rendered production surface; controls should stay compact and native.

Gallery fixtures use synthetic account labels and a fixed presentation time.
They must never resemble live account data, mutate production state, or imply
that a shared SwiftUI render proves WidgetKit, complication, Top Shelf, or
visionOS host composition. Actual placement review remains an explicit,
change-triggered step when the operating-system host can affect the result.

## State Coverage

Design and implementation must handle these states deliberately:

- Healthy/default.
- Close to limit.
- Limited or exceeded.
- Unknown limit without implying zero capacity.
- Stale data with last-good timestamp.
- Provider/account refresh failure.
- Reconnect or setup-needed state.
- Loading/refreshing with last-known values preserved.
- Empty first-run state.
- Dense multi-account/provider data.
- Prompt-cache unavailable, enabled, healthy, and sharply degraded states.
- Companion updates unavailable, stale, partial, and healthy states.
- Apple TV offline with saved data, restored live updates, and no prior saved
  usage.

Failure and stale states should isolate to the affected account, provider, or
transport when neighboring data is still valid. Do not blank the whole widget or
app detail surface because one provider cannot refresh.

## Copy And Forecast Language

Prefer plain status language:

- `available`
- `close to limit`
- `limited`
- `unknown`
- `stale`
- `refreshing`
- `setup needed`
- `reconnect`

Widget copy should stay short and answer-first. For fast-mode forecasts, use
instrument-style copy such as `Fast mode limited`, `1.4%/h active`,
`fast lasts ~2d`, and `reset Sat 4:12 PM (2d 21h)` instead of advisory
sentences.

Prompt-cache telemetry should stay lightweight in the widget: pair the most
recent cache percentage with the token-weighted rolling average, using status
color only for the current-vs-average comparison rather than adding another
capacity bar.

## Ordering And Density

The first visible saved limit is the stable primary answer. Constraint ranking
does not replace that answer; it supplies the optional `Closest to limit`
message when the result is materially different or concerning. Supporting
limits retain saved order, except that constrained glance surfaces may give the
useful closest-limit warning their first secondary slot. Detail screens may
still sort diagnostic rows by pressure when that ordering is explicitly
labeled and does not change the stable glance answer.

When space is tight, prefer:

1. stable saved answer
2. materially different or concerning closest limit
3. reset timing and confidence
4. provider/account identity
5. stale, setup, offline, or refresh problem
6. prompt-cache or forecast detail

Large-widget density should be tested with realistic multi-account snapshots
before committing to a visible row count. Six to eight rows is a target, not a
promise when names, reset text, or provider states are long.

## Source Of Truth

This file is the durable design direction for repo work. External mockups,
React/HTML exports, screenshots, and design-tool artifacts are review aids only
unless their decisions are copied into tracked docs, GitHub planning issues, or
native SwiftUI code.

Do not reference local download paths, private machine paths, or temporary
handoff files from tracked design docs. Active design discussion belongs in the
canonical GitHub planning issue or PR; stable product and implementation policy
belongs here.
