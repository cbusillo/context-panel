# Provider Usage Access Research

Last verified: 2026-07-28.

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
| Google Antigravity                            | AGY CLI documents a custom status-line command whose JSON can include `version`, `plan_tier`, and a `quota` dictionary. Context Panel consumes only this public extension point and never reads the Antigravity login.                                                                                                                                                                                                                                                                                                                                                                           | Each exported bucket can report remaining fraction and reset time. Observations arrive while AGY runs and remain event-driven rather than being privately polled; idle time alone is not stale.                         | One active AGY CLI login is observed at a time. Keep the normalized model account-aware without claiming concurrent Antigravity profiles.       | Use guided `/statusline` setup targeting the signed refresh agent. Persist only a bounded, validated, privacy-filtered App Group snapshot; do not edit AGY settings automatically, chain arbitrary commands, read Keychain, or call private Cloud Code Assist endpoints.                                                                                       | Medium-high for the documented extension point; quota fields remain optional and event-driven, so only missing, malformed, or unsupported data is unavailable.                                                    |
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

## OpenAI Reset Credits

The verified OpenAI Codex read contract exposes an account-level summary under
the exact `/backend-api/wham/usage` key `rate_limit_reset_credits`. Context
Panel treats `available_count` as the authoritative inventory count, ignores
unknown sibling fields, and clamps only that count at zero. Reset credits remain
an account entitlement summary; they are not converted into `UsageLimit`
capacity or pooled across accounts.

When `available_count` is greater than zero, Context Panel may make the separate
sibling GET request `/backend-api/wham/rate-limit-reset-credits` to look for
expiry evidence. The equivalent `/api/codex/usage` source uses the verified
`/api/codex/rate-limit-reset-credits` sibling. Only the required top-level
`available_count` and `credits` array are parsed. Each row must contain the
required `id`, `reset_type`, `status`, and valid `granted_at` fields; a row
contributes expiry evidence only when `reset_type` is `codex_rate_limits`,
`status` is `available`, and `expires_at` is a valid future date at observation
time. Missing, unknown, expired, malformed, capped, or otherwise ambiguous rows
reduce detail coverage without failing the normal usage refresh. A valid details
response supplies the newer count. If that read fails or violates the required
shape, the summary count from the usage response remains available as count-only
evidence and no detail timing is retained.

Local persistence is deliberately narrow: available count, observation time,
coverage (`countOnly`, `partial`, or `complete`), and earliest known expiry.
Provider credit IDs, status/reset-type strings, titles, descriptions, and raw
rows are discarded. Reset-credit summaries are not sent through companion or
CloudKit payloads.

After a full account refresh failure, storage may retain only the prior count
with its original observation time. Detail coverage is reduced to `countOnly`
and expiry is cleared until a fresh read succeeds, so stale timing cannot be
presented as current guidance. A fresh explicit zero replaces prior
availability.

Guidance is evaluated independently for each account and never feeds capacity,
forecast, account-selection, or notification math. The current conservative
rule treats a known weekly reset within one hour as imminent. With current,
complete timing evidence, Context Panel recommends holding when weekly capacity
is healthy, when only the five-hour window is pressured, or when the natural
weekly reset is imminent or no later than the earliest known credit expiry. It
may say `consider using now` for a weekly-limited account whose natural reset is
more than one hour away, or `consider before <date>` for a weekly-close account
when the earliest known expiry precedes its natural reset. Stale, failed,
inconsistent, count-only, elapsed-expiry, or unknown weekly-reset evidence uses
`refresh`, `stale`, or `unknown` language instead of timing advice.

The Mac app shows each account's positive observed count, earliest known expiry
or `expiry unknown`, observation freshness, and advisory reason. Medium and
large macOS widgets may show one currently actionable account note; hold and
unknown states remain app-only, and the small widget and companion surfaces do
not include reset-credit copy. Selecting the widget note opens the matching
Context Panel account detail. It does not open an OpenAI action surface.

Context Panel's reset-credit integration is permanently read-only. It performs
GET requests only and will not implement redemption, consumption, or any other
provider mutation route.

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

In signed app and widget builds, prompt-cache telemetry from Every Code usage
files requires a separate user-approved bookmark for the matching usage folder,
normally `~/.code/usage`. The main app mirrors those JSON files into the
canonical app-group `PromptCache` directory before building the shared snapshot,
so the widget reads only normalized app-owned data. The refresh agent may update
that mirror from the raw user-approved files when its sandbox can resolve the
bookmark; otherwise it preserves and reads the last-good mirror until the main
app refreshes it again. Do not assume that an app-scoped bookmark created by the
main app is transferable to the separately sandboxed login item. The Production
runtime receipt reports aggregate refresh-agent bookmark resolution without
paths or account IDs. This usage-folder permission is intentionally separate
from the `auth_accounts.json` permission used to seed the shared Keychain
credential for live Codex limit refresh.
When an enabled Codex/Every Code account is missing that usage-folder bookmark,
medium and large widgets may show a compact `Enable Cache` pill that opens the
app's settings flow; the settings row uses the more explicit `Enable Cache Stats`
label before presenting the folder picker.

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
  The private catalog can expose a standalone GPT major/minor family while the
  usage endpoint reports a Codex-specific variant such as
  `GPT-5.3-Codex-Spark`. Match that narrow Codex variant to the standalone
  family, but do not use arbitrary substring matching or treat major-only and
  full sibling model names as family aliases.
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

Retired Gemini CLI OAuth, Context Panel-owned Google OAuth, Antigravity Keychain
reads, and private Cloud Code Assist requests have been removed. Google's FAQ
does not permit third-party software to use an Antigravity login for access to
Antigravity, so Context Panel must not copy, refresh, or call provider APIs with
AGY credentials.

The supported integration is AGY CLI's documented custom status-line command:

1. The user copies a `/statusline ...` command from Context Panel and pastes it
   into AGY CLI.
2. AGY invokes the signed embedded `ContextPanelRefreshAgent` executable and
   sends status-line JSON on standard input.
3. The early `--ingest-antigravity-status-line` utility mode enforces a 64 KiB
   input cap and decodes only `version`, optional `plan_tier`, and the optional
   `quota` dictionary.
4. Context Panel validates bucket IDs, remaining fractions, disabled state, and
   reset values, then atomically writes only that sanitized schema plus the
   local observation time to its App Group.
5. The normal Google connector reads the sanitized snapshot. It performs no
   network request and has no access to Antigravity credentials.

Every Code compatibility is validated against the actual non-interactive agent
invocation, not inferred from the interactive UI. On 2026-07-12, AGY 1.1.1
running as `agy --add-dir <workspace> -p <prompt>` advanced the signed
TestFlight bridge snapshot during the command and published four current quota
buckets. A subsequent canonical refresh consumed those buckets as healthy
Google limits. Google's status-line documentation describes the callback in
terms of the TUI, so print-mode callback execution remains a version-specific
compatibility dependency rather than a separate documented background API. If
a future AGY release stops invoking it, Context Panel must show stale or
unavailable data instead of falling back to credentials or private endpoints.

Unknown input fields are deliberately discarded. Email, account identifiers,
conversation/session IDs, paths, transcript metadata, prompts, raw input,
tokens, and decoder details must never be persisted or logged. The bridge file
lives outside the normalized provider snapshot store in a `0700` directory as a
`0600` regular file, with bounded reads, anti-symlink checks, and atomic
replacement so malformed input cannot destroy the last good observation.
Before each new bridge write, best-effort cleanup considers only the writer's
exact canonical temporary-file names once they are at least 24 hours old. It
uses the already-open directory descriptor and removes only bounded `0600`
regular files owned by the effective user with one link; unsafe entries and all
cleanup failures are ignored so ingestion and the last good snapshot remain
independent of housekeeping.

Quota observations are event-driven while AGY CLI runs, not independently
pollable background data. This includes AGY agent runs launched by Every Code.
Missing bridge data is setup-required, and empty or unrecognized data is
unknown. Idle time alone does not make an observation stale because normal AGY
usage invokes the callback. When an explicit reset deadline passes without a
new observation, Context Panel preserves the last observed pressure internally
and presents the elapsed bucket as `≈100%` remaining and `≈0%` used. The
approximation marker means the scheduled reset is assumed rather than observed;
the next AGY run replaces it. This presentation inference must not be written
into observed history or used as high-confidence forecast evidence, and it must
not create stale or refresh-needed UI by itself.
Context Panel makes one immediate reset-expiry retry, then keeps unchanged AGY
observations on the configured low-frequency background refresh cadence. Saves
that only update prompt-cache telemetry, and refreshes that contact no provider
account, do not consume the provider retry attempts.
Every reported active bucket remains distinct. Context Panel may humanize the
bucket ID and recognize literal `weekly` or `5h` tokens already present in that
provider identifier, but it must not infer a window from reset timing or add
per-model buckets together as account capacity. Disabled buckets remain
sanitized source evidence but do not appear as active capacity.

AGY supports one custom status-line command. The first release uses guided
setup, warns before the user could replace another customization, does not edit
`~/.gemini/antigravity-cli/settings.json`, and does not execute or chain an
arbitrary previous command. Teardown uses `/statusline delete`; Context Panel's
separate Forget action deletes only its sanitized snapshot.

### Claude Subscription Connector

Claude subscription pressure should use a Context Panel-owned Claude OAuth
credential when the user explicitly connects Claude in Settings. The refresh
agent calls `GET https://api.anthropic.com/api/oauth/usage` and stores only
normalized percent windows such as `five_hour`, `seven_day`,
`seven_day_opus`, `seven_day_sonnet`, and `seven_day_oauth_apps`. Current
structured `limits[]` entries are preferred by canonical ID, while legacy
top-level utilization/reset windows fill only missing IDs. Tokens are stored in
Context Panel's own Keychain item;
Context Panel must not read Claude Code's Keychain item or Claude Desktop
cookies/storage.

Quota pressure and effective execution access are separate. A 100% plan window
remains limited even when paid usage credits allow the next request. Context
Panel derives one account-level access state from account-wide five-hour and
weekly windows plus `spend.enabled`, falling back to
`extra_usage.is_enabled` only when the structured spend signal is unavailable.
The normalized state can be available, under pressure, blocked until reset,
using paid fallback, unknown, or degraded. Only that enum and an optional reset
time are persisted and synced; spend amounts, balances, organization data,
disabled reasons, and raw response fields are discarded.

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
- Treat this credential as separate from Claude Code or Claude Desktop login.
  If its refresh token is rejected, show `Reconnect required` even while the
  Keychain item remains present; credential presence alone must not render a
  green connected state.
- Only an authorization rejection or an explicit invalid, expired, or revoked
  refresh-token response should trigger that state. Keep malformed requests and
  transient token-endpoint failures as redacted diagnostics instead of telling
  the user to reconnect.
- Refresh `/api/oauth/usage` in the app and background agent. Treat
  `current_value` or legacy `utilization` as percent used and persist only
  normalized limit windows plus the privacy-safe account access state.
- A saturated account-wide window with paid fallback enabled remains a limited
  quota but reports paid fallback active. With fallback explicitly disabled it
  reports blocked until the latest known blocking reset. Missing or malformed
  fallback evidence is degraded rather than assumed available or blocked.
- Model-scoped saturation does not by itself claim an account-wide block.
- Send Anthropic's current OAuth beta header on refresh-token grants. The
  official Anthropic SDK requires `anthropic-beta: oauth-2025-04-20`; omitting
  it can reject an otherwise valid Context Panel refresh token.
- Do not read Claude Code status-line caches, stats caches, `ccusage` output,
  raw transcript JSONL files, prompts, account UUIDs, emails, organization IDs,
  token blobs, or Claude Code Keychain items as provider usage sources.
- If the OAuth usage endpoint omits a limit or reset value, preserve that
  unknown state instead of filling it from a local Claude Code cache.

## Product Decisions

- Treat `unknown`, `manual`, `observed`, and `official` as distinct confidence
  levels in the data model and UI.
- Never overload quota pressure to answer whether the next provider request can
  run. Present effective provider access independently on the app, widgets,
  Watch, and tvOS surfaces, and do not let saved lane ordering hide a hard block.
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
- [Antigravity custom status-line commands](https://antigravity.google/docs/cli/commands/statusline)
- [Antigravity plans and quota windows](https://antigravity.google/docs/plans)
- [Antigravity FAQ](https://antigravity.google/docs/faq)
- [Gemini CLI authentication](https://google-gemini.github.io/gemini-cli/docs/get-started/authentication.html)
- [Gemini CLI quotas and pricing](https://google-gemini.github.io/gemini-cli/docs/quota-and-pricing.html)
- [Gemini API billing](https://ai.google.dev/gemini-api/docs/billing/)
- [Gemini API rate limits](https://ai.google.dev/gemini-api/docs/rate-limits)
- [Google Service Usage consumer quota metrics](https://cloud.google.com/service-usage/docs/reference/rest/v1beta1/services.consumerQuotaMetrics/list)
- [Google Cloud quota usage metrics](https://docs.cloud.google.com/monitoring/alerts/using-quota-metrics)
- [Cloud Billing export to BigQuery](https://cloud.google.com/billing/docs/how-to/export-data-bigquery)
