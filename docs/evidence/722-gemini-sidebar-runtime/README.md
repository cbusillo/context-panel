# Gemini detail and grouped account navigation

Native macOS captures use the canonical installed Context Panel app at 1100 × 850 points.

- Before: 1.0.69 build 202610020900, source afdfc2548685504c8d3d9dbec45f1b74b4f071ac.
- After: 1.0.69 build 202610021502, source b66c4915d466347db34a10348d1231f47e632f9b.
- The after build preserves Production CloudKit and the installed app, widget and refresh-agent entitlements.
- The native runtime baseline and companion cache preflight passed before the capture/navigation pass.
- Background refresh was verified ON at five minutes after the native pass.

[Before](gemini-before.png) shows four quota cards compressed into one row.
[After](gemini-after.png) shows two cards per row, readable local reset times, plain third-party-model labels, and accounts grouped beneath clickable provider totals in percent left.
[Provider view](provider-after.png) retains per-window detail links and all account limits.

[Narrow shared render](narrow-shared-render.png) is a synthetic 500-point host render with real burn/forecast fields. It verifies the single-column fallback; it is not an installed-runtime or physical-companion receipt. The Mac window retains its existing minimum width.

The installed app's native accessibility checks verified that provider headers expose AXButton/AXPress, limit links open history, the provider stays highlighted, and activating that same header returns to its provider view. A first harness attempt used the unsupported recursive `entire contents` collection; reading the scroll area's direct UI elements corrected the collection and passed. A real header-trait failure in the preceding candidate was corrected by preserving the native button's accessibility element. Full VoiceOver navigation and Return on an already-selected sidebar row remain separate acceptance checks.

These captures qualify the Mac changes above. They do not qualify private shared-key/schema availability, Google stable identity, multi-Mac remove/re-add or physical companions. No widget 5-hour or overflow-count layout was changed.
