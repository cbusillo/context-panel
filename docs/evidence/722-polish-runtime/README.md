# Account presentation polish

Native captures use the canonical installed macOS app at 1100 × 850 points.

- Before: 1.0.69 build 202610021645, source e79ddca3317daaa240016ba081e30073749aedd7.
- After: 1.0.69 build 202610021747, source 605d1baae35d1440e6f514e7a3bcf0406b1de2a7.
- Before and after Production runtime baselines passed. The after companion cache preflight passed.
- App, widget and refresh-agent entitlements match the previous signed install; app and agent use Production CloudKit.
- Background refresh was verified ON /5 min after installation and again after native navigation/captures.
- Values and observation/reset countdowns can change between captures because these are live readings.

[Overview before](overview-before.png) and [after](overview-after.png) compare
the modest desktop spacing pass: card insets increased from 14 to 18 points and
major section spacing from 18 to 22. No account or window information was removed;
the account table continues to scroll at this window size.

[Google before](provider-before.png) and [after](provider-after.png), plus
[OpenAI](openai-provider-after.png) and [Claude](claude-provider-after.png), show
provider pages using the same scoped Horizon forecasts, recommendations, account
rows and totals as All Accounts. Window history links, per-model readings,
banked resets, access alerts and diagnostics remain below.
The provider's banked-expiry link continues to open the all-provider Deadlines page.

[Account detail](account-after.png) retains the four readable Gemini cards.
[Expanded diagnostics](account-diagnostics-after.png) retains focused technical
content without repeating a second Horizon panel inside the disclosure.

[Light widget](widget-shared-light.png) and [dark widget](widget-shared-dark.png)
are synthetic shared-view renders at the 344-point large-widget size with six
accounts and a deliberately long name. They demonstrate “5 more expiries” rather
than a bare +5, and the lapse time before the long account name. The same text
uses the singular for one additional expiry; accessibility includes the full
account name and the explicit banked-expiry count. These are layout evidence,
not OS-composited widget or physical-companion runtime qualification.

Native checks exercised provider AXButton/AXPress, window → history → same
highlighted provider, all three provider pages, Google account detail and its
diagnostics disclosure. Initial automation encountered stale activation after
relaunch, a disclosure-query syntax error and incorrectly indexed sidebar rows;
activation and direct AX role/rectangle checks corrected these. Sidebar separators
can report zero-height rectangles. Failed attempts are not product acceptance.
Full VoiceOver traversal and Return on an already-selected sidebar row remain
separate acceptance checks.

These images do not qualify live shared-key/schema availability, Google stable
identity, multi-Mac remove/re-add or physical companions. No 5-hour window
selection, quota reading, identity, connector, release or entitlement behavior changed.
