# Shared account identity

Owner decision: #722 comment 5951706263, 2026-10-02. Provider account IDs are
primary. Explicit linking is reserved for a provider that truly has no ID.

## Provider identifiers

| Provider | Material used | Qualification |
| --- | --- | --- |
| OpenAI | Authenticated `chatgpt_account_id`, falling back to the auth tokens' `account_id` | Require the canonical `chatgpt_user_id` from either ID or access token, rejecting conflicts, independent of plan. Missing user claims retain separate, publisher-scoped local sources without minting an account-only alternative namespace. |
| Anthropic | `account.uuid` from Context Panel's own authenticated `/api/oauth/profile` response, scoped by required `organization.uuid` | Profile uses the same access token as the successful usage request, including after refresh. Missing or malformed identity leaves quota usable and identity unavailable. |
| Google / Antigravity | Proposed Google OIDC issuer plus `sub` | The current status-line connector exposes email/LDAP, not a subject ID. No email hash is treated as a provider ID. A supported subject export or a bound Context Panel-owned Google login remains to be qualified. Owner question #7225951844161. |
| OpenAI session-only quota | Not yet qualified | A session quota event does not carry a provider account ID. A current login cannot by itself identify a historical event from a switched login. Retain an unverified local lane until account-specific attribution is established. |

## Private shared key

`ProviderAccountIdentityMaterial` is non-Codable and redacts its description.
HMAC-SHA256 uses length-delimited provider, identifier kind, account ID and scope.
Snapshots carry only `cp-account-v1:<provider>:<key UUID>:<digest>` and qualification
metadata. Different iCloud users have independently generated keys.

`ContextPanelAccountIdentityKey.v1` is a fixed private record of type
`ContextPanelAccountIdentityKey`. Its `keyMaterial` field is `ENCRYPTED_BYTES`,
without public grants or indexes. It is separate from companion usage records.
Conditional first creation and conflict readback select one server key. An
unavailable store never generates a local-only namespace. An established local
key can restore a missing record conditionally; another publisher's winner
still wins. The local Keychain cache is scoped to the verified iCloud user.
The encrypted payload also binds its key to that iCloud user scope; a foreign-scope payload is rejected. Every resolution rechecks the remote key and user scope. No rotation or deletion
UI is implemented.

The existing schema receipt binds both complete schema files, so the new encrypted
contract changes its digest. No entitlements or container are widened. Static
validation and fake-server tests do not prove Apple's live schema or encrypted
record access. Production promotion awaits Owner question #7225952078955.

## Functional integration

Normal app and refresh-agent connectors now receive the shared resolver. Provider
quota remains usable when identity/key/schema access is unavailable; no local-only
shared key is generated. The installed AF hand-test build predates this integration.

Local history uses a separate source and authenticated-material digest. Temporary
shared-key failure does not change that history membership. Claude profile material
is cached only in the app-owned Keychain and bound to the exact access credential;
a changed credential cannot reuse the old binding. A provider-accepted refresh of
the same OAuth grant carries that binding to the rotated access token. Raw UUIDs and credential digests
never enter usage snapshots. First migration starts a new identity-qualified history
epoch rather than attributing old, unqualified history to the new login; burn needs
new samples. Existing current reset-credit reads and failure preservation remain.

Shared transport replaces local memberships with the provider pseudonym and picks
one complete account observation, carrying its account burn rates. Strong scoped
aliases can preserve that pseudonym through a key failure for the same authenticated
local history epoch. Weak old memberships are retired, never reattributed or treated
as a global removal. Aliases only identify this connector's known memberships;
unknown old feeds from other hosts require fresh authenticated readings.

Remove targets the verified provider pseudonym across hosts. Failed readings preserve the identity provenance of their retained historical
limits so later removals can still identify them. Explicitly adding an
account records a restoration intent; after authentication it can supersede an older
removal. A locally authenticated restoration remains durable through a failed
CloudKit save; failed authentication does not create restoration intent. Partial
removal from a multi-login Codex setup keeps its other accounts monitored.
Raw connector evidence finalizes setup deletion before removed reports are
filtered. Removed native quota is pruned before a setup-level failure can preserve
old data. App, widget and agent projections apply local removal intents immediately,
even before CloudKit acknowledges them. Old/offline publishers do not automatically
restore removed accounts. A
newer removal wins. A pending re-add survives temporary first-read failures but
never restores global quota before a successful authenticated read. Unverified feeds cannot claim global provider identity.

Macs receive the existing private companion usage document into a bounded,
scope-validated cache. App, widget and credential-free agent projection consume the
same canonical account IDs and account observations. Remote readings never enter
local provider history or get republished as fresh local quota. Identity-enabled
remote writes require a confirmed current iCloud scope; unavailable scope keeps
local usage available and reports sync unavailable. An unavailable or
changed current iCloud scope withholds the cache; CKAccountChanged invalidates it.
The cache lease follows the configured refresh interval plus ten minutes of slack.
Future widget entries retain the document qualified when their timeline was built,
then present its age/reset state honestly. Account-change invalidation and expiry
withhold unconfirmed remote-only accounts.

## Remaining qualification and owner boundaries

- Google subject export/bound sign-in remains Owner question #7225951844161.
  Antigravity quota continues locally; email/LDAP is not promoted to identity.
- Session-only OpenAI events remain unverified; current credentials cannot prove
  attribution of historical events from a switched login.
- The additive encrypted Production schema promotion awaits #7225952078955.
  Source integration and fake-key/merge tests do not prove Apple's encrypted field
  support or live schema access. No live schema has been changed.
- Verify both Claude profiles and all configured OpenAI accounts from an exact
  canonical signed Production build, then duplicate-lane checks in all active
  storage roots and physical companions. Mixed old/new client fleets and manually
  copied unverified setups need qualification; no cross-host merging is inferred
  from a label or copied configuration ID.
- Chris's Horizon/rename hand test and marking #733 ready remain owner actions.
  Matching companion/runtime/release gates precede publication. No entitlements,
  Production schema or release gates are widened by this integration.
