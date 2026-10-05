# Settings widget preview

Native presentation evidence for [#765](https://github.com/cbusillo/context-panel/issues/765).
These captures use the shared Display sections and the shipping widget view.
The fixture has six accounts (three OpenAI, two Claude, one Google), a long
account name, Use last, observed burn and dated banked expiries.

The `native-*` images are window captures from the standalone SwiftPM native
host. Normal content is 720 × 700 points; minimum content is 720 × 600 points.
The host's title bar adds 28 points on the capture OS. The remaining images are
Retina NSHostingView renders at those content sizes. Both are shared native
presentation evidence, not screenshots of a newly installed Context Panel app,
signed actual-runtime receipts or WidgetKit placement qualification.

| Presentation     | Normal                                                                             | Minimum                                                                            |
| ---------------- | ---------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| Accounts, Small  | [Light](accounts-small-normal-light.png)                                           | [Light](accounts-small-minimum-light.png)                                          |
| Accounts, Medium | [Light](accounts-medium-normal-light.png), [Dark](accounts-medium-normal-dark.png) | [Light](accounts-medium-minimum-light.png)                                         |
| Accounts, Large  | [Light](accounts-large-normal-light.png)                                           | [Light](accounts-large-minimum-light.png), [Dark](accounts-large-minimum-dark.png) |
| Windows          | [Medium, light](windows-medium-normal-light.png)                                   | [Large, light](windows-large-minimum-light.png)                                    |

Native window captures: [normal, Large](native-normal-large-light.png),
[normal, Small](native-normal-small-light.png),
[minimum, Large](native-minimum-large-light.png), and
[minimum, scrolled to all Windows controls](native-minimum-scrolled-light.png).

## Interaction checks

The native host exercised the same local selector as Settings: accessibility
values changed from Small to Medium to Large without a persistence callback.
At minimum height, scrolling reached all eight Windows rows and their switches.
The preview exposes zero AXLink elements. A native AX reader confirmed the
full account labels, remaining quantities, reset times, recommendations,
forecasts and banked-expiry context are still present as attributed descriptions.
Full VoiceOver traversal remains a separate acceptance check.

An earlier attempt showed that merely discarding openURL and disabling hit
testing did not remove accessibility link actions. The shared navigation wrapper
now renders non-interactive content and omits widgetURL in the preview. Shipping
widgets retain navigation by default. Failed AppleScript attempts are not
counted as interaction proof.

## Reproduce

Build with `swift build`, then run the built ContextPanelSharedViewRenderer:

```sh
ContextPanelSharedViewRenderer --fixture healthy --family systemLarge \
  --appearance light --presentation settings-display-minimum \
  --scenario six-accounts --scale 2 --output <new-output.png>
```

Use `settings-display-normal` for normal height, `--layout windows` for Windows,
or `--interactive yes` to inspect the native window and local size selection.
The host reads synthetic fixtures only; it registers no app or widget bundle
and does not access account storage, credentials or providers. Existing formal
application capture routes remain unsupported by this tool.

## Runtime boundary

The canonical signed Production app was preserved. Its app, widget, refresh
agent and URL handler all resolve under `/Applications/Context Panel.app` and
companion cache preflight passes. The runtime baseline against this newer task
source retains the released-build fingerprint mismatch; it is not a passing
current-source receipt. No Development install, reset, release or deployment
was performed. [Chris approved these captures](https://github.com/cbusillo/context-panel/issues/765#issuecomment-5986488123).
Installed exact-build qualification remains separate before any installed-app
readiness claim.
