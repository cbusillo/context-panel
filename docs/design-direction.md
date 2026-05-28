# Design Direction

Last updated: 2026-05-27.

## Accepted Direction

Use **Quiet Instrument** as the default Context Panel visual direction.

The widget should feel like a calm Mac status instrument, not a billing
dashboard. It should answer the user's immediate question first: can I keep
working, and which account is most constrained?

Adopt **Concept A - Instrument** as the primary widget direction:

- Small widget: answer-first verdict, tightest account/model, capacity indicator,
  provider mini-status, and nearest reset.
- Medium widget: overall verdict/dial plus three or four most constrained rows.
- Large widget: provider groups, six to eight account/model rows, compact trend,
  refresh/stale state, and reset summary.

Use **Concept B - Ledger** as the dense-list treatment inside the app and as a
fallback large-widget direction if the Instrument layout cannot fit realistic
multi-account data.

## Visual System

- True neutral gray surfaces, tuned separately for light and dark appearances.
- One swappable accent color; default accent is a restrained slate blue.
- Subtle status tints. Avoid alarm-heavy red as the dominant state language.
- Provider identity should use short text badges plus labels, not abstract
  shapes or provider logos as the only hierarchy.
- Status must be communicated by color plus nearby text for color-vision safety.
- Widgets are read-only and deep-link into the app for setup and detail.
- Failure and stale states isolate to the affected account or provider; never
  blank the whole widget when neighboring data is still valid.

## Native App Shape

The first app window should use a native macOS split-view structure:

- Sidebar: provider/account groups, account status, and setup entry points.
- Detail: selected account/provider limits, reset timing, trend, forecast, and
  refresh history.
- Inspector: normalized raw limits, confidence, provider connection state, and
  troubleshooting.

The app is where mutation lives: adding logins, naming accounts, disabling or
removing accounts, refreshing, calibration, and credential/privacy messaging.

## Component Map

Translate the design artifact into native SwiftUI/WidgetKit components instead
of copying the React implementation:

- `CapacityDial`: ring/dial for overall or account capacity.
- `CapacityBar`: compact account/model capacity bar.
- `ProviderBadge`: provider short-name text badge.
- `StatusMark`: compact status marker paired with text.
- `AccountRow`: reusable account/model row for widgets and app detail.
- `ContextWidget`: WidgetKit configuration for small, medium, and large layouts.
- `WidgetTimelineProvider`: timeline backed by cached local snapshots and
  last-good stale state.
- `AppRoot`: SwiftUI app shell with `NavigationSplitView`.

Keep colors, spacing, radius, typography, material, and status semantics in a
native theme layer rather than scattering raw values through views.

## State Coverage

Required states for design and implementation:

- Healthy/default.
- Close to limit.
- Limited or exceeded.
- Stale data with last-good timestamp.
- Unknown limit without implying zero capacity.
- Provider or account refresh failure.
- Loading/refreshing with last-known values preserved.
- Empty/first run setup state.
- Dense multi-account data.

## Implementation Notes

- Use native `.system` typography and SF Mono for numeric/tabular data. Web fonts
  in the design artifact are preview stand-ins only.
- Tune dark-mode contrast in SwiftUI; do not blindly trust exported CSS values.
- Verify large-widget row density with realistic data before committing to six to
  eight visible rows.
- Prefer answer-first widget copy, with the tightest account as supporting
  text. For fast-mode forecasts, use instrument-style language such as
  `Fast mode limited`, `1.4%/h active`, `fast lasts ~2d`, and
  `reset Sat 4:12 PM (2d 21h)` instead of advisory sentences.
- Default provider ordering can be by constraint/tightness for the widget, while
  the app can support stable user/provider grouping.

## Design Artifact

The external design export was delivered as `/Users/cbusillo/Downloads/Context Panel.zip`.
It includes React/HTML files for review only. The local browser export did not
render under the current helper because the CDN-backed local HTML stayed blank,
so visual implementation should use the handoff notes and source structure, then
be validated again once native SwiftUI/WidgetKit views exist.
