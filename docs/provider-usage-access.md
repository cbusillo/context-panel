# Provider Usage Access Research

Last verified: 2026-05-22.

## Summary

Context Panel should model two different worlds:

- API/provider-console usage, where official usage APIs, cost APIs, quota APIs,
  rate-limit headers, or Cloud Monitoring data can provide real measurements.
- Consumer chat subscription usage, where providers often expose limits and reset
  timing in product UI but do not expose a stable public API for the underlying
  percent or token pressure.

The OpenAI account use case needs special treatment. For ChatGPT-style weekly
subscription limits, current product surfaces have moved away from a visible
message counter. Context Panel should model OpenAI usage as percent or token
pressure over reset windows: multiple OpenAI accounts, reset windows, observed
usage pressure, burn-rate history, and a clear answer to "am I safe to turn on
fast mode?"

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

| Provider surface                              | Official data available                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                | Reset/limit signal                                                                                                                                                                                                     | Multi-login shape                                                                                                                               | V1 recommendation                                                                                                                                                                                                                                                                                                                                          | Confidence                                                                                                                                                                                                        |
| --------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| OpenAI API organizations                      | Usage API, Costs API, and rate-limit headers. Usage can be grouped by project, user, API key, model, batch, and service tier depending on endpoint.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    | API rate limits expose remaining requests/tokens and reset headers; monthly usage limits are organization/project concerns.                                                                                            | One connected API organization/project per credential. Multiple credentials/accounts should be supported.                                       | Support API org usage as an official adapter using admin or sufficiently privileged API keys.                                                                                                                                                                                                                                                              | High                                                                                                                                                                                                              |
| OpenAI ChatGPT accounts                       | No stable public API found for general personal ChatGPT subscription pressure outside Codex. Current product surfaces no longer present a simple message counter; the useful automated signal found so far is percent-used pressure for Codex/Fast Mode.                                                                                                                                                                                                                                                                                                                                                                               | Weekly and short rolling reset windows matter. Codex/Fast Mode exposes live percent-used windows through the Codex backend usage endpoint.                                                                             | Multiple ChatGPT accounts are core. Each account needs its own reset window, plan, mode, percent/token pressure, and local observation history. | For Codex/Fast Mode, use the live Codex usage endpoint. For non-Codex ChatGPT surfaces, keep manual/assisted observations and forecast confidence until a clean provider signal exists.                                                                                                                                                                    | High for Codex percent windows; medium for visible reset clues; low for non-Codex automation                                                                                                                      |
| Anthropic API organizations                   | Usage and Cost API can report message usage and costs by time bucket, model, workspace, API key, service tier, context window, geo, and beta fast-mode speed. API responses include rate-limit headers with remaining and reset values.                                                                                                                                                                                                                                                                                                                                                                                                | API rate limits use token bucket behavior; monthly spend limits exist by tier.                                                                                                                                         | Organization/workspace/API-key credentials. Multiple organizations and workspaces should be supported.                                          | Support official API usage/cost adapter. Capture fast-mode dimensions where available.                                                                                                                                                                                                                                                                     | High                                                                                                                                                                                                              |
| Claude subscriptions and Claude Code seats    | Context Panel-owned Claude OAuth credentials can call `/api/oauth/usage` and return subscription utilization windows such as five-hour, seven-day, Opus, Sonnet, and OAuth-app buckets. Claude Code status-line JSON, local stats, transcripts, `ccusage`, Claude Code Keychain items, and Claude Desktop/web session storage are not runtime data sources.                                                                                                                                                                                                                                                                        | OAuth usage windows report percent utilization and may include reset timestamps. Missing windows or reset fields remain explicit unknowns rather than being filled from Claude Code local caches.           | Multiple Claude accounts/seats are possible, but account connection should be conservative.                                                     | Use only Context Panel's Claude OAuth connector for automated Claude subscription refresh. Store Context Panel-owned OAuth tokens in Keychain, refresh them in the app/background agent, and persist normalized limit snapshots. Do not read Claude Code auth, Keychain, status-line caches, `ccusage`, raw transcripts, prompts, or conversation JSONL.                            | High for OAuth-reported usage windows; unknown fields stay unknown                                                                                                                                                  |
| Google Antigravity                            | Antigravity model availability can be queried through the Cloud Code Assist API family using Google OAuth credentials and the active Antigravity project. Context Panel owns its Google OAuth credentials and does not read Antigravity's Keychain item, Gemini CLI OAuth files, or local Gemini CLI metadata.                                                                                                                                                                                                                                                             | `fetchAvailableModels` can report per-model `quotaInfo.remainingFraction` and `quotaInfo.resetTime`. Treat this as reported model availability, not a public billing/quota contract.                                    | Google account is the account boundary. Multiple Google OAuth accounts should be supported through Context Panel's provider credential store.    | Use a Claude-style OAuth connector: refresh Context Panel-owned Google credentials, discover the project via `loadCodeAssist`, fetch model availability, group model quota into Gemini/Claude/GPT-OSS availability rows, and keep degraded states explicit. Do not reintroduce Gemini CLI OAuth, direct Antigravity Keychain reads, or installed-app proof modes. | Medium for reported Antigravity model availability; lower for exact generation success prediction because this is an internal provider surface rather than a public quota API.                                      |
| Google Gemini API / Google AI Studio projects | AI Studio and Cloud Billing show usage. Gemini API rate limits are project-scoped, not API-key-scoped. Service Usage API lists quota limits; Cloud Monitoring exposes quota usage metrics; Cloud Billing export to BigQuery provides detailed cost/usage data.                                                                                                                                                                                                                                                                                                                                                                         | Rate limits are RPM, input TPM, and RPD, with model/tier variation. RPD quotas reset at midnight Pacific time.                                                                                                         | Google project is the natural account boundary. Multiple Google accounts/projects should be supported.                                          | Support Google API projects after OAuth/service-account design. Use Service Usage for limits, Cloud Monitoring for quota usage, and optional Billing export for cost history.                                                                                                                                                                              | Medium-high, but setup is heavier                                                                                                                                                                                 |
| Google consumer Gemini app subscriptions      | No stable public API for personal Gemini app subscription allowance was found in this pass.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            | Provider UI likely remains source of truth, and current public help describes 5-hour refreshes until a weekly limit is reached.                                                                                        | Multiple Google accounts may matter, but automation risk is high.                                                                               | Defer direct Gemini Apps automation for v1 unless a supported API emerges, but keep the shared Google/Gemini display model able to show 5-hour, daily, weekly, or unknown windows.                                                                                                                                                                          | Low for automation; high for the documented need to avoid daily-only Gemini copy                                                                                                                                   |

## OpenAI Fast-Mode Forecasting

For the user's immediate OpenAI need, the best product path is a live Codex
percent-window connector backed by an honest local predictor:

1. Add each OpenAI account separately.
2. Record plan and relevant buckets, such as Codex/Fast Mode weekly and
   five-hour windows.
3. Fetch current percent-used pressure and reset times when the Codex endpoint
   is available.
4. Capture reset time from the UI when no endpoint signal exists, or let the
   user enter it.
5. Start a local usage ledger from the moment Context Panel is installed.
6. Estimate standard and fast-mode burn rates in percent or tokens per hour
   from local usage history.
7. Recommend when to enable fast mode only when the forecast has enough margin.

The widget should make confidence visible while staying glanceable. Prefer
short instrument-style labels and numbers over advisory sentences. Good copy
examples:

- `Fast mode limited`
- `1.4%/h active · fast lasts ~2d`
- `reset Sat 4:12 PM (2d 21h)`
- `pace unknown`

## Local Probe And Every Code Evidence

The first OpenAI Limit Probe run confirmed the uncomfortable but useful shape of
the problem:

- ChatGPT visible text exposed plan/model language such as model names, `Pro`,
  `Instant`, and `Thinking`, but did not expose a percent/token counter or a
  reset time before exhaustion.
- Sanitized network response-shape scanning found account entitlement and plan
  fields, including subscription-plan style field names, but no obvious
  `used_percent`, token pressure, `reset_at`, weekly allowance, or five-hour
  allowance fields outside the Codex usage surface.
- The probe should remain useful as a diagnostic harness because it can detect
  if OpenAI later starts exposing cleaner fields, and it can produce redacted
  evidence across multiple accounts.

Codex-family tooling exposes a stronger path for Codex/Fast Mode. Upstream
Codex CLI has an app-server method, `account/rateLimits/read`, backed by a
backend client call that fetches live snapshots from the ChatGPT Codex backend:
`GET /backend-api/wham/usage` for ChatGPT-backed auth, or `/api/codex/usage` for
Codex API-style deployments. The payload maps into rate-limit snapshots with
provider window buckets, reset times, plan type, credits, reached-limit
classification, and additional buckets keyed by `limit_id`.

Every Code is useful as a fallback and validation source. It does not derive
Codex rate-limit snapshots from local token counts. It sends authenticated
requests to the ChatGPT Codex backend, parses server-reported `x-codex-*`
response headers into percentage and reset-window snapshots, and persists the
latest server snapshot under local usage files. The local files are a cache of
server state plus local token history, which explains why displayed limit
pressure reflects cloud and other-machine usage for the same account.

Every Code also has a deliberate refresh path: it sends a tiny `"ok"` prompt via
the selected account, waits for a `RateLimits` event from response headers, then
persists the snapshot and updates the `/limits` UI. Separately, when the backend
returns `usage_limit_reached`, it records `plan_type`, `resets_in_seconds`, and
the reached-limit type as a hint.

That is stronger evidence than visible ChatGPT UI scraping for Codex-style
limits, but it is still product-surface-specific. Context Panel should separate
`OpenAI ChatGPT product UI hints` from `OpenAI Codex backend percent windows`.
The latter looks viable as an automated adapter if Context Panel can reuse the
same authenticated account flow safely.

Implication: v1 should not promise exact general ChatGPT subscription counters.
For Codex/Fast Mode, though, the preferred path is a live OpenAI Codex limits
connector using the same shape as Codex CLI's
`account/rateLimits/read`/`get_rate_limits_many()` flow. If that cannot be made
stable or safely testable, fall back to Every Code's local `usage/*.json` cache
or Codex CLI's app-server request.

### Codex Limits Connector

Preferred v1 connector scope:

- Fetch live Codex limits directly from the Codex backend usage endpoint shape:
  `GET https://chatgpt.com/backend-api/wham/usage` for ChatGPT-backed auth.
- Support provider window buckets, reset times, plan type, credits,
  reached-limit classification, and additional `limit_id` buckets.
- For ChatGPT-backed auth, filter model-specific additional buckets against
  `GET https://chatgpt.com/backend-api/models` so retired or unavailable models
  do not appear as usable limits. Treat that availability lookup as a display
  filter only: if it fails or returns no usable model identifiers, keep the
  usage endpoint's additional buckets rather than hiding possible active limits.
- Keep auth handling isolated and redacted; never log tokens, cookies,
  authorization headers, account IDs, emails, or raw response bodies.
- Expose a diagnostic probe that reports only sanitized structure, percentages,
  reset timing, bucket labels, and staleness.
- Mark this as an OpenAI Codex/Fast Mode percent-window source, not a general
  ChatGPT subscription counter.
- Do not require the Codex CLI binary or app server at runtime. The local
  `CodexRateLimitProbe` executable exists to prove the direct call path against
  an existing Codex `auth.json` while printing only redacted summaries.

### Google Antigravity Connector

Retired Gemini CLI OAuth and legacy Code Assist quota support has been removed.
Context Panel no longer reads Gemini CLI OAuth files, discovers Gemini CLI OAuth
metadata, reads Antigravity's Keychain item, ships a Gemini quota probe, or
offers an installed-app Antigravity proof mode. Google support now follows the
Claude OAuth shape: Context Panel stores its own Google OAuth credentials in the
provider credential store, refreshes those credentials, discovers the active
Antigravity project with `v1internal:loadCodeAssist`, and reads reported model
availability from `v1internal:fetchAvailableModels`.

Diagnostic proof on 2026-06-06 showed that a direct Antigravity Keychain read
could trigger repeated macOS access prompts. Do not reintroduce direct AGY
Keychain reads, retired Gemini CLI OAuth files, local Gemini metadata discovery,
or installed-app proof modes as fallback behavior. Because the current Google
adapter uses an internal Cloud Code Assist model-availability surface, UI copy
and notes should describe the result as reported availability rather than a
provider-guaranteed billing or exact quota contract.

The Antigravity availability response reports reset timestamps but not an
explicit quota-window duration. Context Panel infers the user-facing Gemini
window label from that observed reset horizon: resets at or below 8 hours are
shown as 5-hour/5h, longer observed resets are grouped with the weekly/1w lane,
and missing reset/observation data remains generic model capacity.

Current public Google docs have a split contract. Gemini Apps help announced
usage-limit changes starting 2026-05-17 and describes compute-based limits that
refresh every 5 hours until a weekly limit is reached. Gemini for Google Cloud
quota docs, last updated 2026-05-20, describe Gemini Code Assist and Gemini CLI
quotas as daily request limits aggregated across model versions/families for CLI
and agent mode. Gemini API docs, last updated 2026-05-18, describe API rate
limits as project-scoped RPM, input TPM, and RPD, with RPD resetting at midnight
Pacific time. Context Panel therefore treats Google/Gemini windows as observed
quota data rather than provider-wide daily copy.

### Claude Subscription Connector

Claude subscription pressure should use a Context Panel-owned Claude OAuth
credential when the user explicitly connects Claude in Settings. The refresh
agent calls `GET https://api.anthropic.com/api/oauth/usage` and stores only
normalized percent windows such as `five_hour`, `seven_day`,
`seven_day_opus`, `seven_day_sonnet`, `seven_day_oauth_apps`, `utilization`,
and reset timestamps. Tokens are stored in Context Panel's own Keychain item;
Context Panel must not read Claude Code's Keychain item or Claude Desktop
cookies/storage.

Claude Code's supported status-line JSON was useful research evidence but is no
longer a fallback or runtime diagnostic source for Context Panel. Claude Code's
status-line input can contain `rate_limits.five_hour.used_percentage`,
`rate_limits.five_hour.resets_at`, `rate_limits.seven_day.used_percentage`, and
`rate_limits.seven_day.resets_at` for Claude.ai Pro and Max subscribers after a
Claude Code session receives an API response, but Context Panel must not read or
cache those files.

That status-line surface is interactive-session scoped. On
2026-05-06, a local non-interactive probe using `claude -p "Reply with exactly
OK." --output-format json --verbose` emitted a `rate_limit_event` with
`rate_limit_info.status`, `rateLimitType`, and `resetsAt`, but did not emit
`used_percentage` and did not refresh the configured status-line cache. A local
`claude -p "/usage" --output-format json --verbose` probe returned only that the
Claude Code subscription was in use, not the five-hour or weekly usage
percentages. This means Every Code's current external `claude -p` agent path
does not by itself provide official subscription percent pressure.

Local binary/bundle inspection found runtime strings for
`anthropic-ratelimit-unified-*`, `utilization`, `five_hour`, and `seven_day` in
Claude Code/Desktop surfaces. It also found the Claude web/desktop usage hook:
the installed Claude app calls
`GET /api/organizations/{active_organization_uuid}/usage` and refreshes it on a
five-minute interval from the settings usage page. The usage page component is
what renders "Claude subscription usage", current-session/five-hour usage, and
weekly limit rows.

That endpoint was the strongest direct subscription API candidate found, but it
is authenticated through the Claude web/app session. A local automated browser
probe against `https://claude.ai/settings/usage` on 2026-05-06 was blocked by
Cloudflare before login/session reuse, so Context Panel must not treat embedded
WebKit scraping or Claude Desktop session replay as a background refresh source.
The old manual Claude web capture flow has been removed in favor of explicit
OAuth setup.

On 2026-05-14, `claude setup-token` was verified as insufficient for usage
refresh because its token is inference-only and `/api/oauth/usage` rejects it
for missing `user:profile`. A full-scope Claude Code OAuth credential with
`user:profile` and `user:inference` returned HTTP 200 from
`/api/oauth/usage`, including five-hour and weekly utilization/reset windows.
This was proof only; shipping code should use Context Panel's own
user-consented OAuth credential rather than reading Claude Code credentials.

No safe persisted local Claude Desktop file/cache containing official
subscription percentages was found.

The official Claude Code authentication docs say macOS credentials are stored in
the encrypted macOS Keychain. Context Panel must not read Claude Code Keychain
secrets or try to extract existing subscription OAuth tokens.

Preferred v1 connector scope:

- Let the user connect Claude from Settings using the visible Claude OAuth code
  flow. Store only the resulting Context Panel-owned OAuth tokens in Keychain.
- Refresh `/api/oauth/usage` in the app and background agent. Treat
  `utilization` as percent used and persist only normalized limit windows.
- Do not read Claude Code status-line caches, stats caches, `ccusage` output,
  raw transcript JSONL files, prompts, account UUIDs, emails, organization IDs,
  token blobs, or Claude Code Keychain items as provider usage sources.
- If the OAuth usage endpoint omits a limit or reset value, preserve that
  unknown state instead of filling it from a local Claude Code cache.

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
- [Claude Code authentication](https://code.claude.com/docs/en/authentication)
- [Claude usage and length limits](https://support.claude.com/en/articles/11647753-how-do-usage-and-length-limits-work)
- [Models, usage, and limits in Claude Code](https://support.claude.com/en/articles/14552983-models-usage-and-limits-in-claude-code)
- [Gemini CLI authentication](https://google-gemini.github.io/gemini-cli/docs/get-started/authentication.html)
- [Gemini CLI quotas and pricing](https://google-gemini.github.io/gemini-cli/docs/quota-and-pricing.html)
- [Gemini API billing](https://ai.google.dev/gemini-api/docs/billing/)
- [Gemini API rate limits](https://ai.google.dev/gemini-api/docs/rate-limits)
- [Google Service Usage consumer quota metrics](https://cloud.google.com/service-usage/docs/reference/rest/v1beta1/services.consumerQuotaMetrics/list)
- [Google Cloud quota usage metrics](https://docs.cloud.google.com/monitoring/alerts/using-quota-metrics)
- [Cloud Billing export to BigQuery](https://cloud.google.com/billing/docs/how-to/export-data-bigquery)
