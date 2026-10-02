# Canonical native account-name verification

Installed source `afdfc2548685504c8d3d9dbec45f1b74b4f071ac`, version 1.0.69 build
202610020900, tested on 2026-10-02. ZIP SHA-256
`416e6ce11442a7fdaad0ef45cab2c533ef230e4619ed3cfa83d22d52df8b52a8`;
build fingerprint `eb0b380ffa18e19c5f81083337aeb6d315888d2592af8118b0e191601b3c9ff7`.

The signed Production app was installed at `/Applications/Context Panel.app`.
Fresh runtime baseline and companion cache preflight pass. App, widget,
URL handler and refresh agent resolve to that canonical app. Entitlements are
unchanged. No storage or widget-placement reset.

- [Before](settings-before.png): normal 720 by 732 point Settings Accounts pane.
- [After Return](settings-after.png): a temporary email name remains visible.

With the text field explicitly focused, typing `Rename test@example.invalid`
passes after Return, focus change and closing/reopening Settings. The original
name was restored. Settings Updates verifies background refresh ON every 5 min
after each pass. Only Context Panel was operated.

A first accessibility attempt clicked the field without explicitly focusing it
and failed its post-Return check. That result was retained; the next diagnostic
confirmed focus, captured the typed value and confirmed the same value after
Return. The complete explicitly focused lifecycle test then passed. This is not
a claim that the initial failed harness attempt passed.

This verifies the rename behavior in the installed build. It does not establish
matching physical companion acceptance or the later provider-identity change.
