# Security Policy

## Supported Versions

Only the latest release is supported. Fixes ship in a new release built
from `main`.

## Reporting a Vulnerability

Report suspected vulnerabilities privately through GitHub's
[Report a vulnerability](https://github.com/cbusillo/context-panel/security/advisories/new)
form. Do not open a public issue for a vulnerability.

Include the app version, the device and OS version, the impact, and the
smallest steps that reproduce it.

Do not send API keys, session cookies, OAuth tokens, account email
addresses, usage exports, or other personal data. Use redacted or made-up
values.

This is a single-maintainer project. Reports are handled on a best-effort
basis, and I aim to reply within seven days.

## Scope

Relevant reports include:

- account credentials or session data stored or sent outside the device in
  a way the app does not describe;
- companion sync exposing usage data to another Apple account or device;
- credentials or account details showing up in logs, widgets, or crash
  reports; and
- dependency, release signing, or GitHub Actions supply-chain problems.

Problems in OpenAI, Anthropic, or Google accounts or services should go to
that provider.
