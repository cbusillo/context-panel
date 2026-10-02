# Retained detail contrast check

Captured only Context Panel windows from the canonical signed app, at normal main-window size (1080 × 752 points). These are native captures, not HTML mockups. The shared-view galleries use sample data; the provider view shows the running app’s configured accounts. No credentials are included.

The before capture is app source `030d0db`; after is `696b1294ca83a366f56c5c5f2698959dbf91b904`, version 1.0.69 build 202610020045. The displayed observations changed between captures; this is a readability comparison, not a provider-value comparison.

| Before | After |
| --- | --- |
| ![Banked reset label before](banked-before.png) | ![Banked reset label after](banked-after.png) |

The captured display has a SAMSUNG ICC profile. Full ink/background pixels were converted from that embedded profile to sRGB before applying WCAG relative luminance. Before: `(40,88,171)` on `(40,45,57)`, **2.016:1**. After: `(92,205,236)` on `(42,48,53)`, **7.248:1**. Antialiased edge pixels were not used as the text color. Source light-card contrast is **4.69:1** at rest and **4.57:1** at the hover tint; hover values are calculated, not a captured hover interaction.

The retained forecast preview also uses the shared text accent instead of the dark button fill. Visible reset labels and their app spoken labels now share banked-reset terminology; a follow-up is needed for the remaining legacy widget/provider vocabulary noted in the review.

| Shared native view: light | Dark |
| --- | --- |
| ![Native gallery light](shared-light.png) | ![Native gallery dark](shared-dark.png) |

These gallery captures establish the current light/dark presentation, not Horizon implementation or physical companion acceptance. The newer owner decision selects Horizon (#739), borrowing two Clear Skies elements; that integration follows this functional contrast check. Existing detail and Settings remain available.

Production baseline and companion cache preflight passed after install, with the canonical app, widget and refresh agent registered. Settings → Updates verified background refresh **ON**, every **5 min**. No data reset, entitlement change, widget placement reset or global appearance change.

Anthropic `claude-opus-5-5` reviewed the focused source diff read-only. It confirmed the contrast repair and unchanged counts/expiry calculations. Its first wording findings were addressed in the retained account card and no-guidance spoken token. Further legacy visible/spoken terms, a provider-count qualifier, and a potential dark tinted-link issue remain recorded for the Horizon integration; these captures do not claim those are resolved.
