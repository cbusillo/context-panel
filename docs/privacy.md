# Context Panel Privacy Policy

Effective date: October 10, 2026

Context Panel is a native macOS utility for viewing local AI-provider usage
limits and reset timing.

Context Panel does not operate a developer-hosted backend service and does not
sell personal data. Account configuration, credentials, usage snapshots, widget
preferences, refresh history, and diagnostics are stored locally on the user's
Mac. A Mac signed in to the same iCloud account as another Mac running Context
Panel also keeps a local cache of the usage document that Mac shares, described
below.

When the user is signed in to iCloud, Context Panel may sync a normalized
companion usage document through the user's private iCloud/CloudKit database to
that user's own Apple devices: companion apps on iPhone, iPad, Apple Watch,
Apple TV and Vision Pro, and other Macs running Context Panel. The document can
include provider names, normalized usage capacity, reset timing, freshness,
usage pace, prompt-cache hit rates and token counts, the user-facing account
display label, the account's display settings (such as whether it is shown in
widgets or marked "use last"), and records of accounts the user removed or
restored. That display label may be an email address when the provider or user
uses an email as the account name. Companion documents do not include provider
tokens, raw account identifiers, prompts, transcripts, raw provider responses,
or diagnostic logs. Reset-credit data in the document is limited to the
normalized summary described below; provider credit identifiers and raw rows
are never included.

A receiving Mac validates the shared document, keeps it in a bounded local
cache, and shows those accounts alongside its own. It does not add them to its
local provider history or republish them as its own readings. The cache is
withheld when the current iCloud account is unavailable or changes, and it
expires shortly after the configured refresh interval.

To recognize the same provider account across the user's devices, Context Panel
derives a per-iCloud-user keyed pseudonym from the provider's stable account ID
(for OpenAI, the authenticated ChatGPT account and user IDs; for Anthropic, the
account and organization IDs from Context Panel's own signed-in profile
request). Usage documents can contain the pseudonym, its provider identifier
kind, and an identity qualification status; they never contain the raw provider
ID or the hashing secret. The random secret is kept in a separate encrypted
field in the user's private CloudKit database and in a local Keychain cache
bound to the iCloud user. Raw provider account IDs and provider OAuth
credentials stay on the Mac. See
[the implementation contract](shared-account-identity.md).

During an explicit expiring signed-validation session, Context Panel may sync
privacy-safe runtime receipts through the user's private CloudKit database.
These receipts contain app/extension build fingerprints, loaded executable
UUIDs, random session and process identifiers, process-local sequence, closed
surface/state categories, timestamps, and a digest of sanitized presentation
state. They do not contain account names or IDs, credentials, provider payloads,
raw errors, device identifiers, filesystem paths, or App Store Connect object
IDs. Each receipt becomes eligible for deletion no later than seven days after
observation. Local cleanup removes it after that deadline; its private CloudKit
copy is removed by the next successful macOS host cleanup after the deadline.
Receipts are uploaded only by existing entitled host apps and use no CloudKit
subscription.

Apple TV presentation privacy is device-local. Full Detail may show safe account
display labels; Hide Account Names and Percentages Only suppress them. The Top
Shelf document strips account names in every presentation mode.

If the user enables outbound webhook alerts, Context Panel sends selected
normalized limit-warning data to the user-configured webhook URL. This can
include provider name, main-limit window, percent remaining, remaining and limit
values when known, reset time, event time, and app version. Webhook alerts do
not intentionally include provider tokens, webhook URLs, prompts, transcripts,
raw provider responses, account IDs, email addresses, organization identifiers,
project identifiers, or local auth paths. Webhook URLs are stored in the macOS
Keychain and are not written to JSON settings, diagnostics, or logs. Context
Panel rejects explicit local, private, and link-local webhook destinations and
follows only same-origin HTTPS redirects that preserve the POST method and body.
Regular DNS hostnames remain subject to the operating system's DNS resolution.

When a user connects local provider accounts, Context Panel may read local
provider credential files or call provider services to refresh usage-limit
status. Those requests are made for the user's configured accounts so the app
can display current capacity. Context Panel does not intentionally store raw
provider responses, prompts, transcript contents, API keys, emails,
organization identifiers, or access tokens in diagnostic reports.

For provider reset credits (OpenAI Codex reset credits and Anthropic Claude
limit resets), Context Panel performs read-only GET requests and stores only a
normalized summary: available count, observation time, detail coverage, the
known expiry date of each available credit, and, for Claude, a count of credits
of an unrecognized kind. That sanitized summary may sync through the user's
private iCloud/CloudKit account to the user's own devices. It does not include
provider credit IDs, status or reset-type strings, titles, descriptions, or raw
detail rows. Context Panel does not redeem, consume, create, or otherwise mutate
reset credits; that is a permanent product boundary.

When the user authorizes a local Codex home or sessions directory, Context Panel
reads bounded usage-counter fields from recent session files to estimate usage
and prompt-cache hit rates. It stores only normalized counts, never session text,
prompts, or provider account IDs.

For local agent tools on the same Mac, Context Panel can print a
credential-free summary of the accounts it shows, and it can read count-only
launch records (provider, account, time) that a local launcher writes to Context
Panel's storage folder. Neither leaves the Mac.

Refresh and alert diagnostics are stored locally to help explain whether the app
or background agent refreshed successfully and whether configured local or
webhook alerts were attempted. These diagnostics are summary records only and do
not intentionally include provider tokens, raw provider responses, webhook URLs,
account IDs, emails, organization identifiers, project identifiers, or local
auth paths.

For support or privacy questions, contact:

Shiny Computers Leasing LLC  
info@shinycomputers.com  
757-371-1123
