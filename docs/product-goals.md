# Product Goals

Context Panel should make AI usage limits legible without requiring people to
open each provider dashboard.

## Initial Goals

- Show remaining usage for OpenAI, Anthropic, and Google.
- Prefer native macOS surfaces: WidgetKit first, with a menu bar surface later if
  it earns its place.
- Keep credentials local and avoid syncing usage data unless the user asks for
  that later.
- Display provider state in plain language: available, close to limit, limited,
  and reset time.

## Non-Goals For The First Slice

- Web dashboard.
- Docker deployment.
- Team billing or admin reporting.
- Provider account automation that violates provider terms.
