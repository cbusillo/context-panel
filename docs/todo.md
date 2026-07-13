# Context Panel TODO

## Claude Auth Metadata Follow-Up

- Revisit Claude account metadata after the refreshed widget/app launch is stable.
- Keep automatic Claude refresh focused on the Context Panel-owned OAuth usage
  connector. Do not read Claude Code's Keychain item, Claude Desktop cookies,
  browser local storage, transcripts, or raw provider response bodies.
- Claude Web capture was removed. Do not reintroduce WebKit usage scraping as a
  refresh path; use OAuth setup and the OAuth usage endpoint.
- Decide whether the app needs a privacy-safe way to show Claude login or
  subscription metadata without using `claude auth status --json` or other App
  Store-sensitive access.

## Google Antigravity Bridge Follow-Up

- Keep Antigravity quota access on AGY's documented custom status-line export.
  Do not restore Keychain reads, Antigravity OAuth identity reuse, private Cloud
  Code Assist requests, Gemini CLI files, or terminal scraping.
- Monitor the optional status-line quota schema and keep unknown or missing
  fields explicit. Never infer reset windows from timestamps; only recognize
  literal window tokens already present in provider bucket identifiers.
- Revalidate that Every Code's non-interactive `agy --add-dir ... -p ...` path
  still invokes the configured status-line callback when AGY is upgraded. Treat
  a detected stopped callback as unavailable data, never as a reason to restore
  credential reads or private Cloud Code Assist requests. Idle time by itself
  is not evidence that the callback stopped.
- AGY currently supports one custom status-line command. Keep setup guided and
  non-destructive until Google documents a safe stacking mechanism.
- Keep AI credits unavailable until AGY documents a supported exported balance,
  and describe the bridge as one active AGY CLI login rather than concurrent
  multi-account support.

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
