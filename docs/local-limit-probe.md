# Local Limit Probe Design

Last updated: 2026-05-05.

## Goal

Context Panel needs to know whether subscription limits are exposed anywhere a
logged-in user can legitimately see them. The first target is OpenAI ChatGPT
subscription usage: weekly limits, short rolling windows, reset times, model
availability, and any percent or token pressure signals. If the approach works
for OpenAI, the same diagnostic shape can be reused for Claude and Gemini.

The probe is a local diagnostic tool, not a production data integration. It
should help answer:

- Does the provider expose subscription limits in visible UI text?
- Does the provider expose subscription limits in browser-accessible structured
  responses after a normal login?
- Which observations are safe and reliable enough to become Context Panel
  signals?
- Which observations should stay manual/calibrated because the provider hides or
  changes them?

## Safety Rules

- The user logs in directly with the provider. Context Panel never asks for or
  stores the provider password.
- The probe never prints, commits, uploads, or logs cookies, bearer tokens,
  session IDs, full response bodies, or account identifiers.
- Captured artifacts are local and gitignored by default.
- Raw network/body capture is opt-in and redacted before display.
- The default probe reports only route/method/status/content-type/body-size plus
  detected field names or text snippets that match usage-limit patterns.
- Automated message sending is out of scope. The probe observes login/account
  pages and model picker state; it does not burn subscription allowance.

## Recommended Implementation

Build a local macOS diagnostic surface called **Limit Probe** inside the
companion app or as a development-only target.

For the first implementation, prefer a native `WKWebView`-based probe because it
lets the user log in normally while keeping the session isolated from Safari or
Chrome. Later, a browser-extension or browser-control probe can be considered if
WKWebView cannot observe enough.

### Flow

1. User opens `Limit Probe`.
2. User selects provider: OpenAI first, then Anthropic, then Google.
3. App opens an isolated `WKWebView` at the provider's normal product URL.
4. User logs in normally.
5. Probe shows a checklist:
   - Login detected.
   - Model picker/account UI reachable.
   - Limit/reset text detected.
   - Candidate structured responses detected.
   - Manual observation needed.
6. User navigates to the relevant UI, such as ChatGPT model picker.
7. Probe scans visible text and sanitized network metadata for usage/reset
   signals.
8. User can press `Record Observation` to save a sanitized event.
9. User can press `Export Redacted Report` for a local Markdown/JSON report.

### OpenAI Targets

Initial OpenAI pages and states to inspect:

- ChatGPT app after login.
- Model picker when GPT-5/GPT-5.5/Thinking modes are available.
- Provider UI when a model is close to its limit.
- Provider UI when a model is unavailable or limit-reached.
- Account or plan surfaces that mention current plan and reset.

Detection patterns:

- `reset`, `resets`, `refresh`, `available`, `limit`, `usage`, `percent`,
  `tokens`, `weekly`, `every 3 hours`, `every 5 hours`, `Thinking`, `fast`,
  `temporary`.
- Dates and relative durations such as `tomorrow`, `in 42m`, `3h`, `5 hours`,
  `7 days`, `weekly`.
- JSON field names containing `limit`, `usage`, `used_percent`, `token`,
  `remaining`, `reset`, `cap`, `quota`, `model`, or `plan`.

## Capture Model

```swift
struct LimitProbeObservation: Codable, Sendable {
    var provider: Provider
    var accountLabel: String?
    var surface: String
    var observedAt: Date
    var source: ProbeSource
    var signal: ProbeSignal
    var confidence: UsageConfidence
    var sanitizedEvidence: String
}

enum ProbeSource: String, Codable, Sendable {
    case visibleText
    case networkMetadata
    case redactedResponseShape
    case manualUserEntry
}

enum ProbeSignal: Codable, Sendable {
    case resetTime(Date)
    case relativeReset(seconds: TimeInterval)
    case knownLimit(used: Int?, limit: Int, unit: String)
    case modelAvailable(model: String)
    case modelUnavailable(model: String, reason: String?)
    case plan(name: String)
    case unknownLimit
}
```

## Sanitized Network Probe

`WKWebView` does not expose every network body through public APIs. There are
three possible tiers:

1. **Visible text only**: safest and easiest. JavaScript reads `document.body`
   text after login and extracts matching snippets.
2. **JavaScript fetch instrumentation**: inject a user script that wraps
   `window.fetch` and `XMLHttpRequest` to record sanitized URL path, method,
   status, content type, body size, and matching field names from JSON responses.
   Do not store headers or raw bodies.
3. **External browser-control/devtools probe**: use a separate development-only
   probe with browser automation/DevTools if WKWebView cannot see enough. This
   remains local and diagnostic-only.

Start with tier 1 and tier 2. Escalate only if OpenAI hides the useful signal
from visible text and simple response-shape inspection.

## Report Shape

The exported report should be local and safe to share in a PR or issue after
review:

```json
{
  "schema_version": 1,
  "provider": "openai",
  "captured_at": "2026-05-05T00:00:00Z",
  "surfaces": [
    {
      "surface": "chatgpt-model-picker",
      "signals": [
        {
          "source": "visibleText",
          "signal": "relativeReset",
          "evidence": "resets in 3h",
          "confidence": "observed"
        }
      ]
    }
  ],
  "candidate_network_shapes": [
    {
      "method": "GET",
      "path_hint": "/.../models/...",
      "status": 200,
      "content_type": "application/json",
      "matched_fields": ["model", "limit", "reset"]
    }
  ],
  "redactions": [
    "cookies",
    "authorization headers",
    "account ids",
    "emails",
    "raw response bodies"
  ]
}
```

## Acceptance Criteria For A Prototype

- User can log in to OpenAI in an isolated local web view.
- Probe can scan visible UI text for limit/reset signals without storing
  secrets.
- Probe can record a manual observation when the UI exposes reset or limit state.
- Probe can show whether any structured candidate responses appear, without
  revealing raw response bodies or tokens.
- Probe writes only redacted local artifacts under a gitignored directory.
- Findings can update `docs/provider-usage-access.md` with evidence and
  confidence.

## Open Questions

- Does ChatGPT's login flow work reliably in `WKWebView`, or does it require the
  user's default browser?
- Does the model picker expose useful reset text before a limit is reached?
- Can visible text reveal enough to calibrate weekly Thinking limits without
  network inspection?
- Are subscription limit signals account-specific enough to distinguish multiple
  OpenAI accounts cleanly?
