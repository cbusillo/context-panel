# Native Settings Accounts comparison

Actual window-only captures from `/Applications/Context Panel.app`, taken under
Chris's desktop/install and screenshot-posting authorization on issue #719.
Screenshots are unedited. No other app, credential content or expanded source
path is included. Account labels in After are the previously saved email names
loaded by the fresh app; the layout check did not rename any account.

| Capture | App source | Window size |
| --- | --- | --- |
| [Before](before.png) | `f8d024cc3391b54fd6b2b8699ce952c8a2c035f1` | 720 × 732 pt |
| [After](after.png) | `030d0dbc33cc916d30d0695e036eb9a76e28f4fa` | 720 × 732 pt |
| [Minimum](minimum.png) | `030d0dbc33cc916d30d0695e036eb9a76e28f4fa` | 720 × 632 pt |
| [Bottom](bottom.png) | `030d0dbc33cc916d30d0695e036eb9a76e28f4fa` | 720 × 732 pt |

The source minimum is 720 × 600 pt of content. Window measurements include
32 pt of title-bar/chrome. PNGs also include the native window shadow.

Name fields measure 406 × 24 pt after the change, versus 220 × 24 pt before.
OpenAI rows now occupy about 167 pt, versus 270 pt before. Three full accounts
fit at the default size, versus two before; the account list scrolls vertically.
Reorder arrows, Remove account, name fields, the two checkbox preferences and
connection controls remain inside the pane. The bottom capture shows Claude,
Google, the retired source and Add account; text wraps within the card.

Removal confirmation opened and Escape cancelled it, retaining all six active
accounts. Background refresh is restored on, every five minutes. Production
runtime baseline and companion-cache preflight pass; signatures verify and all
three entitlement sets match the preceding installed build. App, refresh agent,
widget and URL handler resolve to the canonical installed app, with a real new
widget timeline. Full commit gate passes with 1,116 Swift tests. Anthropic
Claude Opus 5.5 found no actionable regression in the Settings delta; its fit
assessment was source-only and is supplemented here by native captures.

The existing Advanced disclosure remains; its accessibility element did not
respond to the attempted automation actions, so expanded-state native validation
is not claimed. Source inspection confirms its controls are retained. Matching
companion/placed-widget acceptance and broader #722 refinement remain separate.
