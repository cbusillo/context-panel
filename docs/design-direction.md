# Design Direction

Last updated: 2026-07-10.

## Accepted Direction

Context Panel should use **Quiet Instrument** as its default visual direction.
The product should feel like a calm Mac status instrument rather than a billing
dashboard. It should answer the user's immediate question first: can I keep
working, which account or limit is most constrained, and when will that pressure
change?

The widget is the glance surface. It should be dense, calm, and answer-first:
remaining capacity, tightest provider/account/model lane, reset timing, refresh
health, stale state, and compact prompt-cache telemetry where available.

The app is the setup, detail, and troubleshooting surface. It can use denser
ledger treatments, diagnostics, history, account management, refresh controls,
forecast settings, webhook settings, and provider-specific setup flows without
trying to turn the widget into a dashboard.

## Widget Layout Direction

Use an instrument-first widget hierarchy:

- Small widget: answer-first remaining-capacity verdict, tightest main limit,
  provider/window label, reset confidence, and an explicitly labeled
  used-pressure bar. The `used` caption is required whenever that inverse bar
  renders. Stale or setup problem copy takes priority when needed.
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

Apple Watch uses a shape-based quantity matrix. Circular and corner
complications are remaining-capacity rings, and inline complications state the
remaining answer explicitly. Rectangular complications and watch app rows are
explicitly labeled used-pressure views. In every case, the visible number,
wording, fill, color, and accessibility sentence describe the same quantity.
Keep unknown values indeterminate rather than substituting zero, preserve stale
last-good values with explicit freshness language, and retain saved lane order.

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
- Non-phone windows below 810 points and accessibility text sizes use one
  centered column capped at 720 points with 24-point page padding. The order is
  usage instrument, sync status, display settings, refresh settings, then
  visionOS appearance.
- Regular-width iPad and visionOS windows use two bounded columns: the usage
  instrument and sync status lead, while settings remain secondary in the
  trailing column. The layout begins at 810 points and stops expanding at 1080
  points; the instrument column flexes from 400 to 720 points and the settings
  column remains 340 points.
- Resizing must preserve view identity, settings state, and accessibility
  reading order.
- The companion remains a focused read-only utility. Do not turn regular width
  into a collector dashboard, navigation sidebar, or denser telemetry surface.

Mutation belongs in the app, not the widget: adding logins, reconnecting,
naming accounts, disabling or removing accounts, saving bookmarks, choosing
visible widget lanes, refreshing, calibration, warning configuration, and
privacy/credential messaging.

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

Keep colors, spacing, radius, typography, material, and status semantics in
native theme helpers instead of scattering raw values through views.

The semantic defaults are:

- Rings and capacity dials communicate remaining capacity.
- Linear pressure bars communicate used capacity and pair with `used` copy.
- Rates such as prompt-cache hit rate remain neutral telemetry rather than being
  named or announced as capacity or pressure.
- Missing, non-finite, unavailable, and unknown ratios are indeterminate. They
  never become a determinate zero-length or zero-capacity instrument.

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
- Companion sync unavailable, stale, partial, and healthy states.

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

Widget ordering should default to constraint/tightness so the most important
lane appears first. The app can support stable user/provider grouping and richer
detail because users have room to compare and act.

When space is tight, prefer:

1. current limit pressure
2. reset timing and confidence
3. provider/account identity
4. stale, setup, or refresh problem
5. prompt-cache or forecast detail

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
