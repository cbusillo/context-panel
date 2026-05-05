# Architecture

Context Panel is expected to split into a few native boundaries:

- `ContextPanelCore`: provider-neutral domain models, limit math, and refresh
  policy.
- Provider adapters: small clients that retrieve or normalize usage state for
  each service.
- macOS app: account setup, credentials, refresh scheduling, and settings.
- Widget extension: compact read-only display backed by the app's latest local
  snapshot.

The first committed code lives in `ContextPanelCore` so provider and UI work can
share the same vocabulary from the start.
