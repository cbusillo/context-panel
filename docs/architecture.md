# Architecture

Context Panel is expected to split into a few native boundaries:

- `ContextPanelCore`: provider-neutral domain models, limit math, and refresh
  policy.
- Account store: multiple logins per provider, local credential references,
  display names, and enabled/disabled state.
- Provider adapters: small clients that retrieve or normalize usage state for
  each service without leaking provider quirks into the UI.
- Snapshot store: the latest normalized usage state plus refresh history for
  widgets and charts.
- macOS app: account setup, credentials, refresh scheduling, detailed charts,
  provider health, and settings.
- Widget extension: compact read-only display backed by the app's latest local
  snapshot.

The first committed code lives in `ContextPanelCore` so provider, account, and
UI work can share the same vocabulary from the start.

Widget interactions should keep the widget simple. Tapping the widget should
open the app to the relevant provider or account detail; mutation and setup stay
inside the app.
