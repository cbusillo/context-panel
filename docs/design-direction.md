# Design Direction

Last updated: 2026-07-09.

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

- Small widget: answer-first verdict, tightest main limit, provider/window label,
  compact capacity bar, reset confidence, and stale or setup problem copy when
  that is the most important state.
- Medium widget: overall/tightest status plus the most constrained provider or
  account rows, nearest reset, prompt-cache summary when enabled, and compact
  sync/refresh state.
- Large widget: provider groups, several constrained account/model rows, compact
  capacity bars, reset summary, prompt-cache comparison, and refresh/stale state.

The large widget may use a dense ledger-like treatment when realistic
multi-account data does not fit a dial-led composition. The design preference is
still instrument-first: clear pressure, reset timing, and state hierarchy before
raw completeness.

Apple Watch app rows and complications should use count-up usage percentages.
The visible percentage must come from the same usage ratio that fills the watch
gauge or pressure bar; do not pair a usage-pressure gauge with an unlabeled
remaining-capacity value. Keep unknown usage explicit rather than substituting
zero.

## App Layout Direction

The native macOS app should stay a work-focused `NavigationSplitView`:

- Sidebar: provider/account groups, account status, and setup entry points.
- Detail: selected provider/account limits, capacity, reset timing, prompt-cache
  telemetry, fast-mode forecast, refresh status, and history.
- Settings and diagnostics: credential management, provider setup, account
  naming, widget lane preferences, refresh cadence, warning/webhook settings,
  and troubleshooting.

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

## Component Vocabulary

The durable native vocabulary lives in SwiftUI, not in a web export. Current
implementation uses shared app/widget ideas including:

- `CapacityDial`: circular pressure indicator for app detail and summary views.
- `CapacityBar` / `CPWCapacityBar`: compact pressure bar for rows and widgets.
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
