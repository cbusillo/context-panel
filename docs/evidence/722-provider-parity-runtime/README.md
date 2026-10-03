# Provider field parity in Horizon

Native Mac captures use the canonical installed Context Panel app.

- Before: 1.0.69 build 202610021747, source 605d1baae35d1440e6f514e7a3bcf0406b1de2a7.
- After: 1.0.69 build 202610021952, source aed4081320da8c8975cde2edfce8139de8979663.
- Normal comparison window: 1100 × 850 points. Values and countdowns are live and can change between captures.
- App, widget and refresh-agent signatures/entitlements were verified; entitlements match the previous Production install.
- Production runtime baseline and companion cache preflight passed after installation; background refresh was verified ON /5 min after the native pass.

[Google before](google-before.png) versus [collapsed after](google-collapsed.png),
[OpenAI before](openai-before.png) versus [collapsed after](openai-collapsed.png),
and [Claude before](claude-before.png) versus [collapsed after](claude-collapsed.png)
show the legacy provider quota blocks removed. Per-account data expands within
the Horizon table instead of occupying a second dashboard underneath.

[Google expanded](google-expanded.png) shows all four model/window cards plus
explicit unknown banked inventory. [OpenAI expanded](openai-expanded.png) shows
the plan, both model buckets, every banked expiry, observation time and advisor
text. The snapshot audit found three OpenAI, two Claude and one Google report
identities, with matching limit identities; no identifiers or credentials were
printed. The old five-account banked badge pooled providers; its global inventory
remains available through All Accounts/Deadlines rather than pretending to be
five OpenAI accounts.

## Field comparison

| Previous provider field/action | Horizon replacement |
| --- | --- |
| Provider/account name and current state | Provider/account rows and account detail |
| Provider totals, burn, pace and run-out | Existing shared Horizon provider facts and shapes |
| Recommendation and Use last | Existing shared recommendation/row labels; selection unchanged |
| Every weekly, 5-hour, model and additional limit | Per-account “Windows and banked resets” fold; uses all account limits |
| Model/period context | Window-card heading and account row |
| Plan | Plan text, including the existing quota-note fallback |
| Used amount, capacity, unit and remaining capacity | Window ring and Used/Limit facts; handles partial amounts |
| Window status | Explicit Status fact |
| Confidence and assumed reset | Explicit Reading fact and existing approximate-capacity markers |
| Observation time | Explicit Observed fact |
| Natural reset/unknown reset | Resets fact in local time to the minute |
| Banked balance, every known expiry, duplicate dates and undated balance | Banked card; expired dates removed; duplicate entries preserved by position |
| Banked observation/current versus last observed | Observation timestamp and explicit refresh warning |
| Hold/consider/refresh advice and explanation | Same read-only reset advisor, in the banked card |
| Pooled usage, account count, reset and confidence | Compact history controls, visible text and accessibility value |
| Access warning title/account/detail/reset | Existing access warnings retained |
| Store health | Existing store-health tag retained |
| History and forecast actions | Same pooled-window history routes, including returning via the highlighted provider |
| Embedded diagnostics | Existing account diagnostics route retained |

The new fields live only in the non-Codable display model. No identity,
connector, quota, shared snapshot/agent export, or entitlement contract changed.

## Checks and limits

- Full code gate: 1,201 Swift tests plus Python; parity cases preserve source
  quantities/status/confidence/time, both plan fallbacks and banked advisor data.
- Render checks cover folded cards without a duplicate Horizon and a large
  used-only unknown-unit amount. [Used-only render](used-only-unknown-unit.png)
  and [folded card render](provider-folded-windows.png) are synthetic host renders,
  not installed/physical runtime evidence.
- Native actions verified all three providers, inline folds, banked details,
  both Google history routes, history → same provider → account, and history AX
  values containing usage/reset/confidence.
- First automation attempts used the old help-text selector and an unavailable
  AXDescription attribute; selecting the current controls and checking AXValue
  corrected the harness. Failed attempts are not acceptance.
- [Minimum-width attempt](openai-minimum-width.png) preserves the fields and
  wraps long names; at the narrowest wide layout a long email can still split
  its last character. The normal 1100-point capture fits those names cleanly.
- Full VoiceOver traversal is not qualified by AXValue checks. It remains a
  hands-on acceptance item.
- Existing expiry-list versus reported balance inconsistencies remain diagnostic
  data, as in the old full banked list. CompanionLimit's inherited omission of
  quota notes can leave a note-only plan absent on companions; this pass does
  not change the shared export contract or qualify physical companions.
- Source/UI work does not qualify live shared-key/schema availability, Google
  stable-ID binding, multi-Mac identity/removal or matching companion runtimes.
