# Context Panel Privacy Policy

Effective date: May 8, 2026

Context Panel is a native macOS utility for viewing local AI-provider usage
limits and reset timing.

Context Panel does not operate a developer-hosted backend service and does not
sell personal data. Account configuration, credentials, usage snapshots, widget
preferences, refresh history, and diagnostics are stored locally on the user's
Mac.

If the user enables outbound webhook alerts, Context Panel sends selected
normalized limit-warning data to the user-configured webhook URL. This can
include provider name, main-limit window, percent remaining, remaining and limit
values when known, reset time, event time, and app version. Webhook alerts do
not intentionally include provider tokens, webhook URLs, prompts, transcripts,
raw provider responses, account IDs, email addresses, organization identifiers,
project identifiers, or local auth paths. Webhook URLs are stored in the macOS
Keychain and are not written to JSON settings, diagnostics, or logs.

When a user connects local provider accounts, Context Panel may read local
provider credential files or call provider services to refresh usage-limit
status. Those requests are made for the user's configured accounts so the app
can display current capacity. Context Panel does not intentionally store raw
provider responses, prompts, transcript contents, API keys, emails,
organization identifiers, or access tokens in diagnostic reports.

For support or privacy questions, contact:

Shiny Computers Leasing LLC  
info@shinycomputers.com  
757-371-1123
