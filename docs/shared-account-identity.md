# Shared account identity

Owner decision: #722 comment 5951706263, 2026-10-02. Provider account IDs are
primary. Explicit linking is reserved for a provider that truly has no ID.

## Provider identifiers

| Provider | Material used | Qualification |
| --- | --- | --- |
| OpenAI | Authenticated `chatgpt_account_id`, falling back to the auth tokens' `account_id` | Personal free/plus/pro plans use the account ID. Workspace or unknown plans also require `chatgpt_user_id` or token `sub` to distinguish seats. Plan may come from the token or authenticated usage response. |
| Anthropic | `account.uuid` from Context Panel's own authenticated `/api/oauth/profile` response, scoped by `organization.uuid` where returned | Profile uses the same access token as the successful usage request, including after refresh. Missing or malformed identity leaves quota usable and identity unavailable. |
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
Every resolution rechecks the remote key and user scope. No rotation or deletion
UI is implemented.

The existing schema receipt binds both complete schema files, so the new encrypted
contract changes its digest. No entitlements or container are widened. Static
validation and fake-server tests do not prove Apple's live schema or encrypted
record access. Production promotion awaits Owner question #7225952078955.

## Integration state and activation gates

The connector resolver is optional. Shared identity construction and transport
are implemented and behaviorally tested, but the normal refresh service does
**not** pass the resolver yet. This prevents an unqualified identity migration
from replacing the installed product's account lanes.

Before enabling it:

1. Retire a connector's own legacy local and companion memberships when its
   authenticated ID is established, without guessing identities for other Macs'
   unverified feeds or interpreting migration as global account removal.
2. Bind global removal to the provider identity and qualify copied setups,
   distinct accounts, multiple hosts, stale/offline publishers, and explicit
   re-add behavior. Keep selected observations and their burn rates coherent.
3. Add the Mac receiving/presentation path using the existing private companion
   records. Remote usage must not become credentials or get republished as a
   fresh local reading. Invalidate foreign-user caches on iCloud account changes.
4. Qualify Google binding and session-only OpenAI attribution.
5. Validate/promote the additive schema with owner approval and a fresh exact-source
   receipt; verify both Claude profiles and all configured OpenAI accounts from
   the canonical signed Production app, without printing raw IDs or credentials.
6. Run duplicate-lane checks across active storage roots and companions, plus
   independent review and the required acceptance gates before release.

A synthetic merge test proves that two configured memberships carrying the same
verified provider pseudonym converge on one latest usage lane, and different
provider accounts remain separate. It does not prove migration, Mac receiving,
physical devices, live account identity, or release readiness.
