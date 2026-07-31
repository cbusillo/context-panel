# Context Panel Privacy Policy

Effective date: July 31, 2026

Context Panel is a native macOS utility for viewing local AI-provider usage
limits and reset timing.

Context Panel does not operate a developer-hosted backend service and does not
sell personal data. Account configuration, credentials, usage snapshots, widget
preferences, refresh history, and diagnostics are stored locally on the user's
Mac.

When the user installs a companion app, Context Panel may sync a normalized
companion snapshot through the user's private iCloud/CloudKit account to that
user's Apple devices. The snapshot can include provider names, normalized usage
capacity, reset timing, freshness, and the user-facing account display label.
That display label may be an email address when the provider or user uses an
email as the account name. Companion snapshots do not include provider tokens,
raw account identifiers, prompts, transcripts, raw provider responses, or
diagnostic logs. OpenAI reset-credit companion data is limited to the normalized
available count, observation time, detail coverage, and earliest trustworthy
expiry described below; provider credit identifiers and raw rows are never
included.

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

For OpenAI Codex reset credits, Context Panel performs read-only GET requests
and stores only a normalized summary: available count, observation time, detail
coverage, and the earliest trustworthy expiry when known. That sanitized summary
may sync through the user's private iCloud/CloudKit account to the user's own
companion devices. It does not include provider credit IDs, status or reset-type
strings, titles, descriptions, or raw detail rows. Context Panel does not redeem,
consume, create, or otherwise mutate reset credits; that is a permanent product
boundary.

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
