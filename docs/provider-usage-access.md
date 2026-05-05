# Provider Usage Access Research

Last verified: 2026-05-05.

## Summary

Context Panel should model two different worlds:

- API/provider-console usage, where official usage APIs, cost APIs, quota APIs,
  rate-limit headers, or Cloud Monitoring data can provide real measurements.
- Consumer chat subscription usage, where providers often expose limits and reset
  timing in product UI but do not expose a stable public API for remaining
  message allowance.

The OpenAI account use case needs special treatment. For ChatGPT-style weekly
message budgets, official OpenAI help currently documents weekly Thinking limits
and reset behavior, but not a reliable API for personal message usage counts.
Context Panel should therefore support local forecasting: multiple OpenAI
accounts, reset windows, manually or locally observed usage, burn-rate history,
and a clear answer to "am I safe to turn on fast mode?"

## Forecast Requirement

The app should answer these questions for each account and across all enabled
accounts:

- How much usable allowance remains before reset?
- At my current pace, will I run out before the weekly reset?
- If I turn on fast mode now, how long can I leave it on safely?
- Which account should I use next if one account is close to its limit?

Recommended model:

- `LimitWindow`: provider, account, bucket, unit, limit, used or remaining,
  reset time, reset policy, and confidence.
- `UsageObservation`: sampled value, source, timestamp, and confidence.
- `BurnProfile`: observed standard-mode and fast-mode usage rate over recent
  windows.
- `Forecast`: projected use through reset, estimated runway, recommended mode,
  and confidence.

Recommended safe-mode rule:

```text
safe_fast_mode = projected_fast_usage_until_reset + reserve <= remaining
```

Where `reserve` is a user-configurable safety buffer. The widget should say
"safe", "safe for about N hours", "save fast mode", or "needs calibration"
instead of pretending an estimate is exact.

## Provider Matrix

| Provider surface | Official data available | Reset/limit signal | Multi-login shape | V1 recommendation | Confidence |
| --- | --- | --- | --- | --- | --- |
| OpenAI API organizations | Usage API, Costs API, and rate-limit headers. Usage can be grouped by project, user, API key, model, batch, and service tier depending on endpoint. | API rate limits expose remaining requests/tokens and reset headers; monthly usage limits are organization/project concerns. | One connected API organization/project per credential. Multiple credentials/accounts should be supported. | Support API org usage as an official adapter using admin or sufficiently privileged API keys. | High |
| OpenAI ChatGPT accounts | No stable public API found for personal ChatGPT message allowance. Help docs say some model budgets expose reset date in the model picker and, for that documented budget, there is no way to check messages used. Current GPT-5.5 Thinking docs document weekly limits and pop-up behavior at exhaustion. | Weekly Thinking limits exist for Plus/Business. Older OpenAI help explicitly says weekly limits reset seven days after first use and the reset date is visible by hovering the model name. | Multiple ChatGPT accounts are core. Each account needs its own reset window, plan, mode, and local observation history. | Start with manual/assisted local tracking: account profile, plan/bucket defaults, user-entered or UI-observed reset time, local message counter, and forecast confidence. Avoid credential sharing and avoid automated extraction that could violate terms. | Medium for reset; low for used count without local tracking |
| Anthropic API organizations | Usage and Cost API can report message usage and costs by time bucket, model, workspace, API key, service tier, context window, geo, and beta fast-mode speed. API responses include rate-limit headers with remaining and reset values. | API rate limits use token bucket behavior; monthly spend limits exist by tier. | Organization/workspace/API-key credentials. Multiple organizations and workspaces should be supported. | Support official API usage/cost adapter. Capture fast-mode dimensions where available. | High |
| Claude subscriptions and Claude Code seats | Public docs describe usage limits across Claude.ai, Claude Code, and Claude Desktop, but no stable public API for personal subscription allowance was found. Claude Code can show session cost for API-key usage. | Pro/Max/Team usage has session-based reset behavior; Claude Code Enterprise seats show reset time when a limit is reached. | Multiple Claude accounts/seats are possible, but account connection should be conservative. | Defer automated subscription tracking unless a supported local/official signal is found. Support manual observation later; prioritize Anthropic API first. | Medium for displayed limits; low for automation |
| Google Gemini API / Google AI Studio projects | AI Studio and Cloud Billing show usage. Gemini API rate limits are project-scoped, not API-key-scoped. Service Usage API lists quota limits; Cloud Monitoring exposes quota usage metrics; Cloud Billing export to BigQuery provides detailed cost/usage data. | Rate limits are RPM, input TPM, and RPD, with model/tier variation. RPD quotas reset at midnight Pacific time. | Google project is the natural account boundary. Multiple Google accounts/projects should be supported. | Support Google API projects after OAuth/service-account design. Use Service Usage for limits, Cloud Monitoring for quota usage, and optional Billing export for cost history. | Medium-high, but setup is heavier |
| Google consumer Gemini app subscriptions | No stable public API for personal Gemini app subscription allowance was found in this pass. | Provider UI likely remains source of truth. | Multiple Google accounts may matter, but automation risk is high. | Defer for v1 unless a supported API emerges. | Low |

## OpenAI Fast-Mode Forecasting

For the user's immediate OpenAI need, the best product path is not a hidden
provider API. It is an honest local predictor:

1. Add each OpenAI account separately.
2. Record plan and relevant buckets, such as GPT-5.5 Thinking weekly allowance.
3. Capture reset time from the UI when available, or let the user enter it.
4. Start a local usage ledger from the moment Context Panel is installed.
5. Allow manual correction when the provider UI reveals a reset or limit state.
6. Estimate standard and fast-mode burn rates from local usage history.
7. Recommend when to enable fast mode only when the forecast has enough margin.

The widget should make confidence visible. Good copy examples:

- `Fast mode looks safe through reset.`
- `Fast mode safe for about 2h, then switch back.`
- `Save fast mode: projected to run out 18h before reset.`
- `Needs calibration: open ChatGPT and set reset time.`

## Local Probe And Every Code Evidence

The first OpenAI Limit Probe run confirmed the uncomfortable but useful shape of
the problem:

- ChatGPT visible text exposed plan/model language such as model names, `Pro`,
  `Instant`, and `Thinking`, but did not expose a remaining-message counter or a
  reset time before exhaustion.
- Sanitized network response-shape scanning found account entitlement and plan
  fields, including subscription-plan style field names, but no obvious
  `remaining_messages`, `used`, `reset_at`, weekly allowance, or five-hour
  allowance fields.
- The probe should remain useful as a diagnostic harness because it can detect
  if OpenAI later starts exposing cleaner fields, and it can produce redacted
  evidence across multiple accounts.

The nearby Every Code source is also instructive. It does not derive Codex
rate-limit snapshots from local token counts. It sends authenticated requests to
the ChatGPT Codex backend and parses server-reported `x-codex-*` response
headers into percentage and reset-window snapshots. The local usage files are a
cache of the latest server snapshot plus local token history, which explains why
the displayed limit pressure reflects cloud and other-machine usage for the same
account.

Every Code also has a deliberate refresh path: it sends a tiny `"ok"` prompt via
the selected account, waits for a `RateLimits` event from response headers, then
persists the snapshot and updates the `/limits` UI. Separately, when the backend
returns `usage_limit_reached`, it records `plan_type`, `resets_in_seconds`, and
the reached-limit type as a hint.

That is stronger evidence than visible ChatGPT UI scraping for Codex-style
limits, but it is still product-surface-specific. Context Panel should separate
`OpenAI ChatGPT subscription UI counters` from `OpenAI Codex backend limit
headers`. The latter looks viable as an automated adapter if Context Panel can
reuse the same authenticated account flow safely.

Implication: v1 should not promise exact general ChatGPT subscription remaining
counts unless the probe finds a provider-exposed counter. For Codex/Fast Mode,
though, we should build a first-class OpenAI Codex adapter around the server
headers Every Code already uses, then fall back to user-entered/reset-observed
windows, local-event counting, conservative defaults, burn-rate calibration, and
explicit confidence labels when those headers are unavailable.

## Product Decisions

- Treat `unknown`, `manual`, `observed`, and `official` as distinct confidence
  levels in the data model and UI.
- Do not block the whole widget when one provider cannot expose usage. Show stale
  or estimated state for that account and keep official data for other accounts.
- Prioritize OpenAI ChatGPT forecasting in the UX even if the first automated
  data source is manual/local, because it directly answers the fast-mode problem.
- Keep provider terms and account safety ahead of automation convenience.

## Sources

- [OpenAI Usage API reference](https://developers.openai.com/api/reference/resources/admin/subresources/organization/subresources/usage)
- [OpenAI API rate limits](https://developers.openai.com/api/docs/guides/rate-limits#usage-tiers)
- [GPT-5.3 and GPT-5.5 in ChatGPT](https://help.openai.com/en/articles/11909943-gpt-5-in-chatgpt)
- [OpenAI o3 and o4-mini usage limits](https://help.openai.com/en/articles/9824962-openai-o1and-o1-mini-usage-limits-on-chatgpt-and-the-api)
- [Anthropic Usage and Cost API](https://platform.claude.com/docs/en/build-with-claude/usage-cost-api)
- [Anthropic API rate limits](https://docs.anthropic.com/en/api/rate-limits)
- [Claude usage and length limits](https://support.claude.com/en/articles/11647753-how-do-usage-and-length-limits-work)
- [Models, usage, and limits in Claude Code](https://support.claude.com/en/articles/14552983-models-usage-and-limits-in-claude-code)
- [Gemini API billing](https://ai.google.dev/gemini-api/docs/billing/)
- [Gemini API rate limits](https://ai.google.dev/gemini-api/docs/rate-limits)
- [Google Service Usage consumer quota metrics](https://cloud.google.com/service-usage/docs/reference/rest/v1beta1/services.consumerQuotaMetrics/list)
- [Google Cloud quota usage metrics](https://docs.cloud.google.com/monitoring/alerts/using-quota-metrics)
- [Cloud Billing export to BigQuery](https://cloud.google.com/billing/docs/how-to/export-data-bigquery)
