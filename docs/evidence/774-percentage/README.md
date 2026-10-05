# Full account percentages

Native SwiftUI/AppKit captures for [#774](https://github.com/cbusillo/context-panel/issues/774).
All accounts have 100% remaining. The synthetic account names are longer than
the longest names in the report; no configured accounts or credentials were read.

| Family | Points | Light | Dark |
| --- | --- | --- | --- |
| Small | 164 × 164 | [Capture](widget-small-light.png) | [Capture](widget-small-dark.png) |
| Medium | 344 × 164 | [Capture](widget-medium-light.png) | [Capture](widget-medium-dark.png) |
| Large | 344 × 344 | [Capture](widget-large-light.png) | [Capture](widget-large-dark.png) |
| Extra large | 720 × 344 | [Capture](widget-extra-large-light.png) | [Capture](widget-extra-large-dark.png) |

The test `accountWidgetKeepsFullPercentageWithLongNames` renders the production
widget view through `NSHostingView` at two pixels per point, then recognizes the
visible text with Vision. Provider-average headers are excluded from the account
percentage count. Before the fix, every account percentage in both large
families rendered as `10…` in light and dark, failing four cases. With the
percentage's natural width preserved, all eight cases pass. Small and medium
already fit; their layouts are unchanged.

To regenerate into a scratch directory:

```sh
CONTEXT_PANEL_RENDER_OUTPUT_DIR=<output-directory> \
  swift test --filter accountWidgetKeepsFullPercentageWithLongNames
```

These are source-level native captures, including the companion extra-large
shared layout, rather than OS placement or signed-runtime receipts. The canonical
installed app uses Production CloudKit and has an older source fingerprint;
it was preserved. No Development app was installed, no competing app or widget
bundle was registered, and no release was performed. Merge waits for Chris's
visual approval on the issue.
