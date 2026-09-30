# Provider account quotas

The Mac Overview includes an **All Provider Accounts** card. Membership comes
from saved account configuration and provider reports, including failed,
unconnected, and disabled accounts. It does not depend on successful quotas.
Use local account names in Settings; never use credentials or email addresses
as labels. Mirrored reports for the same provider identity share one row.

## Reading the five-account setup

| Account slot | Supported source | Missing-source behavior |
| --- | --- | --- |
| OpenAI 1 | Existing authorized Codex auth file and live usage endpoint, or explicitly selected single-account session directory | Row remains visible with usage, burn, and reset unknown |
| OpenAI 2 | A separate account's selected session directory, or an existing authorized multi-account catalog | Same explicit unknown or failed state |
| OpenAI 3 | A separate account's selected session directory, or an existing authorized multi-account catalog | Same explicit unknown or failed state |
| Anthropic 1 | Existing Context Panel-owned OAuth credential in Keychain | Row remains visible; app-owned connection required |
| Anthropic 2 | Separate Context Panel account configuration and its own OAuth credential in Keychain | Row remains visible; app-owned connection required |

The app does not discover account identity from session content or scan harness
homes to create account membership. Add OpenAI Session Account or Add Claude
Account in Settings, then set a local label. Adding a row does not sign in,
switch an account, or modify harness files. A session source needs a
user-selected security-scoped folder bookmark in the sandbox. It reads only
bounded JSONL tails using the existing Codex telemetry reader's discovery and
file safety limits. Session bodies, credentials, and provider identity fields
are not copied into snapshots.

Select only a sessions directory dedicated to one account. A directory shared
by different logins cannot prove which account supplied its quota events.
Do not assign it to an account; use a separate source instead. The same selected
folder cannot be assigned twice through Settings.

## Usage, burn, resets, and expiry

Each row lists observed windows and dated resets. Burn is estimated separately
for each account using the existing reset-aware estimator; pooled provider burn
is not duplicated into account rows. Unknown burn means fresh observations or
calibration are needed. Burn is in percentage points per hour, not tokens/hour.

Session quota events preserve their original observation timestamp and become
stale under the app's polling freshness policy. Missing, malformed, future, or
unfinished events cannot manufacture fresh capacity. The reader supports the
`event_msg` / `token_count` `rate_limits.primary` and `secondary` window fields.
The source remains observational, not an official subscription API.

Live OpenAI usage can provide reset-credit count and details. The normalized
summary retains all trustworthy available-credit expiry dates, including
repeated dates for distinct credits, plus coverage and earliest expiry. Old
snapshots without the date list still load. Partial or count-only responses
remain explicit about unavailable dates. Session events can report a numeric
credit balance but do not establish reset-credit grants or credit expiry dates;
those dates remain unknown. No expiry date is inferred from a weekly reset.

Claude quotas continue to use only the app-owned OAuth source from
[the provider research](provider-usage-access.md). Claude Code credentials,
Keychain entries, status-line data, and transcripts are not alternate sources.

## Trial validation boundary

The #719 model comparison permits builds, tests, inspections, and a draft PR.
It prohibits installation, login changes, merge, and release. Automated tests
exercise five-account membership, unavailable rows, logical deduplication,
per-account burn, bounded session observations, and timestamp freshness.
Actual native presentation and the owner's private five-account setup need
later canonical-runtime validation; passing SwiftPM tests does not establish
that physical finish line.
