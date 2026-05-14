# Context Panel TODO

## Claude Auth Metadata Follow-Up

- Revisit Claude account metadata after the refreshed widget/app launch is stable.
- Keep automatic Claude refresh focused on the Context Panel-owned OAuth usage
  connector. Do not read Claude Code's Keychain item, Claude Desktop cookies,
  browser local storage, transcripts, or raw provider response bodies.
- Claude Web capture was removed. Do not reintroduce WebKit usage scraping as a
  refresh path; use OAuth setup plus statusline/ccusage fallback diagnostics.
- Decide whether the app needs a privacy-safe way to show Claude login or
  subscription metadata without using `claude auth status --json` or other App
  Store-sensitive access.

## Widget Signing And Registration Follow-Up

- Verify the release provisioning profiles carry the Context Panel app-group
  entitlement for the app, widget, and refresh agent.
- Keep the sandbox-local widget mirror as a local-development fallback, but do
  not treat it as a substitute for a correctly entitled release build.
- Make local widget validation less manual by scripting the install-time
  `pluginkit` cleanup for stale build-products widget registrations.

## Widget Forecast And Settings Polish

- Watch live widget behavior after the stricter burn-rate estimator has enough
  history. It should avoid optimistic fast-mode recommendations when samples are
  sparse or reset-ambiguous, without adding noisy confidence copy to the UI.
- Consider making the Settings lane preview more visual once the final widget
  layouts settle.
- Add a focused release QA pass for security-scoped bookmark reauthorization,
  stale bookmarks, and refresh-agent bookmark access.
