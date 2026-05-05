# Product Goals

Context Panel should make AI usage limits legible without requiring people to
open each provider dashboard or remember which account is close to a limit.

## Initial Goals

- Show remaining usage for OpenAI, Anthropic, and Google.
- Support multiple logins per provider from the first real architecture slice.
- Prefer native macOS surfaces: WidgetKit for glance state, a companion app for
  setup and detail, and a menu bar surface later only if it earns its place.
- Keep credentials local and avoid syncing usage data unless the user asks for
  that later.
- Display provider state in plain language: available, close to limit, limited,
  unknown, and reset time.
- Use compact visualizations that fit a macOS widget: progress rings, stacked
  bars, sparklines, reset countdowns, and account/model grouping.

## Non-Goals For The First Slice

- Web dashboard.
- Docker deployment.
- Team billing or admin reporting.
- Provider account automation that violates provider terms.
- A cloud backend for the first version.
