# Codex Credential Recovery

The [October 26 Q930 decision](https://github.com/cbusillo/context-panel/issues/1028#issuecomment-6428257456)
supersedes the proposed Context Panel app-server integration below. Context
Panel stays read-only: a sign-in-rejected usage read displays **Codex sign-in
expired** and keeps the last good reading launchable. It adds no renewal-status
feed or needs-sign-in exclusion. The Codex-owned daemon and launcher handle
renewal and terminal failures separately. The current app behavior is described
in [provider access](provider-usage-access.md#codex-and-codex-lab-setup); the
candidate comparison below is historical context.

This records the recommendation from
[#694](https://github.com/cbusillo/context-panel/issues/694): how the App Store
app should recover an OpenAI account whose Codex access token has expired,
without leaving the sandbox, hiding sibling accounts, or taking ownership of
another client's credentials. It is a decision record, not current behavior;
[Current Codex homes and OpenAI recovery](provider-usage-access.md#current-codex-homes-and-openai-recovery)
describes what ships today.

## Recommendation

The Codex client stays the only writer of its credentials. Context Panel keeps
its read-only grants and recovers by picking up what the client writes.

1. **Now: a clear user-initiated recovery handoff.** When a home's credentials
   are rejected and a refresh token is present, tell the user to use Codex once
   with that home (Codex refreshes tokens during use) or sign in again there if
   Codex asks. The next Context Panel refresh reads the renewed `auth.json`.
   This needs no new entitlement, grant, or service. The follow-up work is
   copy and state, not access.
2. **Later, optional: a client-owned refresh through stock Codex app-server.**
   Worth a signed-sandbox prototype only if the handoff proves too disruptive
   for unattended expiry. Context Panel would ask a user-run app-server for the
   home to refresh. Codex would still write the credentials, and Context Panel
   would work without it.
3. **Not pursued:** Context Panel renewing shared credentials itself, or
   holding its own OpenAI sign-in. Reasons are under each candidate below.

None of these steps proposes new access. The one concrete grant that a
rejected option would need is listed under [Unresolved grants](#unresolved-grants).

## What the current build can and cannot do

Signed evidence, read with `codesign -d --entitlements` from the installed
TestFlight build 1.0.73 (202610151714, team `MM5YXC7T6E`) on October 16, 2026.
The app and its `ContextPanelRefreshAgent` login item both hold App Sandbox,
outgoing network client, app-scoped bookmarks, user-selected **read-only**
files, the Context Panel App Group, and the provider-credentials Keychain group.
That matches [`ContextPanelAppStore.entitlements`](../Config/ContextPanelAppStore.entitlements).
The app holds no read-write file grant, no temporary exceptions, and no XPC
service.

The source shows how a renewed credential reaches the connector:

- Each refresh first re-imports every enabled home's bookmarked `auth.json`
  into Context Panel's Keychain (`importConfiguredAuthFiles` in
  [`SnapshotRefreshService.swift`](../Sources/ContextPanelCore/SnapshotRefreshService.swift)).
  The connector then reads that copy. A file that Codex has rewritten is
  therefore used on the next refresh. When the Keychain save fails, that
  refresh reads the file it just imported, and the import retries the save on
  the next refresh. A stale copy remains in use only when the bookmarked file
  cannot be read (the user rebinds the home).
- A usage-service 401/403 with a refresh token present is reported as
  `foregroundRefreshRequired`. Without one, it is `invalidAuth`
  ([`CodexRateLimits.swift`](../Sources/ContextPanelCore/CodexRateLimits.swift)).
  Since [#864](https://github.com/cbusillo/context-panel/issues/864) both
  messages name the entry's local nickname. With a refresh token, the message
  says whether the access token's own expiry had passed, had not passed, or
  could not be read; the connector still cannot tell a revoked refresh token
  from an unrelated 403.
- Context Panel never sends a refresh-token grant and never writes a
  client's files.

A command-line repair outside the sandbox (the September incident in #694) shows
that an expired token can be recovered. It does not show that the signed app
can do the same.

## Candidates

### A. Context Panel holds its own OpenAI sign-in

This is the model the Claude connector uses: a credential that Context Panel
owns in its own Keychain.

- OpenAI's [Codex authentication](https://learn.chatgpt.com/docs/auth) documents
  ChatGPT sign-in and API keys for Codex itself. It does not document client
  registration for third-party apps. Reusing Codex's own OAuth client would
  impersonate Codex rather than create an independent session.
- [Codex access tokens](https://learn.chatgpt.com/docs/enterprise/access-tokens)
  are limited to Business and Enterprise workspaces, expire after a fixed
  window with manual rotation, and are documented for Codex runs, not for
  usage reads. They do not cover personal Plus or Pro accounts.
- The usage endpoint that Context Panel reads is not a public API (see
  [Codex Limits Connector](provider-usage-access.md#codex-limits-connector)).

Verdict: not available through a supported route today. Asking OpenAI for a
registration would be an external message, and that is the Director's call.

### B. Context Panel renews the shared client credentials directly

- This needs `com.apple.security.files.user-selected.read-write`
  ([Apple](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.files.user-selected.read-write))
  plus a new read-write bookmark for each home. The current bookmarks are
  created read-only on purpose
  ([`SecureFileBookmark.swift`](../Sources/ContextPanelCore/SecureFileBookmark.swift)).
- A running Codex process keeps its own copy of the tokens and refreshes during
  use. Two writers rotating the same refresh token can leave one side holding a
  rejected token. Avoiding that needs a lock that Codex does not offer to other
  processes.
- A home whose credentials live in the OS credential store (`keyring`, or
  `auto` when the store is available;
  [Codex authentication](https://learn.chatgpt.com/docs/auth)) keeps no
  readable `auth.json`. Another app's Keychain items are out of reach either way.
- Launching the Codex binary from the app inherits the app's sandbox
  ([Apple](https://developer.apple.com/documentation/security/discovering-and-diagnosing-app-sandbox-violations)),
  so that is not a route around the read-only grant.

Verdict: rejected. It widens access and adds a concurrency risk that the client
is better placed to own.

### C. Client-owned refresh through stock Codex app-server (optional)

Stock Codex app-server (`openai/codex` at
[`b5115cd`](https://github.com/openai/codex/tree/b5115cdd669d37a8635a9742851e97ba4fb1d42c/codex-rs/app-server-protocol))
exposes `account/read` with `refreshToken: true`, which "requests a proactive
token refresh before returning" in managed auth mode, and
`account/rateLimits/read`. The app-server stays the credential writer for its
home. A stock home holds one login, so a per-home refresh targets that account
without switching anything. A retained Codex Lab catalog holds several members
in one file, so this route does not cover them (see
[Credential sources](#credential-sources)).

- **Reachability.** The app cannot spawn the server with useful access, since a
  child process inherits the sandbox. It could connect to a server the user
  runs, over local networking, which `network.client` permits
  ([Apple](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.network.client)).
  The README mentions WebSocket peers but does not document a stable local
  listener contract for third parties.
- **Authentication.** A local listener must prove which home it serves and
  refuse other local callers. That design does not exist yet.
- **Optionality.** Without a running server, Context Panel falls back to
  recommendation 1. Whether an optional integration like this satisfies App
  Review guidelines
  [2.4.5 and 4.2.3](https://developer.apple.com/app-store/review/guidelines/)
  is unverified, since renewal would still depend on a separately installed
  Codex. It stays an open App Review question, not an assurance.
- **Evidence still owed.** A matching signed, sandboxed prototype must reach
  the server, refresh an expired home, and read limits before anyone claims
  this works in Context Panel.

Verdict: the right later direction if unattended expiry stays common. It needs
no new entitlement for local networking, but it does need a prototype.

### D. Improved user-initiated recovery handoff (recommended now)

- The renewed file reaches the connector on the next refresh (see above). No
  rewrite of the credential path is needed.
- Recovery is per home. Siblings keep their reports, and the stale account
  keeps its last limits marked stale until a genuine successful read
  ([Current Codex homes](provider-usage-access.md#current-codex-homes-and-openai-recovery)).
- Delivered by [#864](https://github.com/cbusillo/context-panel/issues/864):
  the messages drop the Codex Lab wording, name the affected home's local
  nickname so the user knows which home to open, and read the access token's
  own expiry locally, without logging it, so that "expired" is said separately
  from "rejected". Recovery happens on the next scheduled refresh.
- This does not fix expiry that happens while the user never uses Codex with
  that home. Candidate C is the answer for that case.

## Credential sources

What Context Panel can read from each source is documented in
[Codex and Codex Lab setup](provider-usage-access.md#codex-and-codex-lab-setup)
and [Per-account Codex session quota](provider-usage-access.md#per-account-codex-session-quota).
This record decides only the recovery route for each one:

- **Stock file-backed home:** D now, C later.
- **Credentials only in the OS credential store:** nothing the app can recover.
  Settings should say why the home cannot be read.
- **Retained Codex Lab catalog with several members:** not covered. Neither D
  nor C renews one member without a Lab client, and a stock login into a new
  home is a migration, not a recovery. That migration must keep the existing
  catalog and its readable siblings monitored until the user moves each
  member. Its design is follow-up work, not part of this recommendation.
- **Session-quota folder:** reads no credentials, so there is nothing to recover.

## Unresolved grants

- `com.apple.security.files.user-selected.read-write` would be required only by
  candidate B. It is **not proposed**.
- A supported OpenAI client registration would be required by candidate A. It
  is **not requested**, because contacting OpenAI is an external message.

## Open questions

- Which stock Codex command refreshes a home's tokens without starting a
  session or using quota? If none does, the handoff copy should keep saying
  "use Codex once", not name a command.
- Will Codex app-server publish a supported local listener and caller
  authentication for third-party clients? Candidate C depends on it.
