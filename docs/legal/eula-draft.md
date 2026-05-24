# Trix End User License Agreement (Draft)

Status: Draft with CEO and CTO review incorporated; not publish-ready.
Publication gate: outside-counsel review is required before publication, and the
current CEO decision is no publication until counsel supplies or approves the
final clauses.
Last updated: 2026-05-21
Applies to: Trix MVP private XMPP + OMEMO deployment and Apple clients.

This document is a product-fact draft, not outside-counsel advice.

## 1) Agreement Scope

This EULA governs use of the Trix client software and access to the Trix MVP
private messaging service currently built on a self-hosted XMPP stack.

Fact basis:
- `docs/architecture.md`
- `server/xmpp/README.md`

## 2) Eligibility and Private-Group Use

Trix is intended for a small private, invite-based group and is not a public
registration service. Open-source or source-availability publication for license
compliance does not turn the MVP into a public registration service.

Trix is adult-only for the MVP. Users must be 18 or older, invites must not be
issued to minors, and discovered minor accounts may be disabled pending deletion
and legal handling.

Fact basis:
- `docs/security.md` (public registration out of scope)
- `server/xmpp/README.md` (invite-only registration wrapper)
- CEO review on `TRI-24` (2026-05-20)
- Board comment on `TRI-39` (2026-05-20): private/company use, AGPL/source
  availability, no public registration.

## 3) Account Responsibilities

Users are responsible for account credentials and device security. The product
uses account-authenticated flows for password change and invite issuance.

Fact basis:
- `server/xmpp/README.md` (authenticated invite/password routes)
- `server/xmpp/scripts/invite-registration-server.py`
- `docs/security.md` (threat model includes password compromise/device loss)

## 4) Encryption and Messaging Rules

Product DM/group chats are designed to require OMEMO encryption; plaintext
sending in product flows is blocked when required encryption/trust state is not
available.

Trix does not provide custom cryptography and does not guarantee perfect
confidentiality, anonymity, or endpoint security.

Fact basis:
- `docs/architecture.md` (mandatory OMEMO; no custom crypto)
- `docs/security.md` (what E2EE covers and limits)
- `docs/mvp-checklist.md` (plaintext send blocked)

## 5) Metadata and Infrastructure Limits

Even with E2EE, server/operators may process metadata needed to run the service
(for example account/device activity, room membership, timing, and related
protocol metadata).

Fact basis:
- `docs/security.md` (Metadata Still Visible To The Server)

## 6) Service Availability and Feature Status

Trix is an MVP private service with no public uptime SLA in current docs.
Features may change, and some surfaces remain explicitly open/not launch-complete
(including encrypted call smoke completion).

Fact basis:
- `docs/mvp-checklist.md` (push and encrypted-call status)
- `server/xmpp/README.md` (deployment and spike-required notes)
- Board comment on `TRI-39` (2026-05-20): no SLA.

## 7) Acceptable Use

Users must not use Trix to:
- attempt unauthorized access to accounts, devices, or infrastructure;
- bypass encryption or trust safeguards;
- abuse invite/account flows or private operator tooling;
- violate applicable law through use of the service.

Fact basis:
- `docs/security.md` (device trust, registration/provisioning, logging rules)
- `docs/architecture.md` (private non-federated operator-managed model)

## 8) Suspension and Termination

Operators may disable or re-enable accounts through documented control-plane
flows. Disabling can block login and terminate active sessions without
automatically deleting retained server data.

Fact basis:
- `server/xmpp/README.md` (disable/enable behavior)
- `docs/mvp-checklist.md` (disable/enable flows)

## 9) Data Handling Reference

Privacy/data-handling terms for end users are defined in the companion
`privacy-policy-draft.md`. If publication is later approved, the privacy policy
and EULA should be published together.

Fact basis:
- This legal-workstream issue scope (`TRI-24`) requires paired EULA + privacy
  artifacts.

## 10) Open-Source and Third-Party Components

Trix relies on third-party/open-source components, including Apple XMPP/OMEMO
stack dependencies currently tracked in repository SBOM/license notes. Additional
license notices or source-availability obligations may apply.

The current GPL/AGPL stack is accepted only for private non-commercial and
TestFlight validation. Broader public or proprietary distribution remains blocked
until required notices, source-availability obligations, and legal review are
complete.

Fact basis:
- `docs/security.md` (Apple OMEMO License and SBOM Gate)
- `docs/xmpp-migration/license-sbom.md`

## 11) Warranty and Liability (Counsel Required)

Before publication, outside counsel must supply or approve enforceable wording
for:
- warranty disclaimer scope;
- limitation-of-liability scope and cap;
- governing law, venue, and dispute process.
- jurisdiction-specific privacy rights and cross-border transfer terms.

The current CEO decision is that counsel is required and publication is not
allowed until counsel supplies or approves the final clauses. The board's desired
risk posture is to disclaim warranties and limit liability as much as legally
permitted, but no counsel-approved text, board waiver, governing law, venue,
dispute process, jurisdiction-specific privacy rights language, cross-border
transfer language, or liability cap is available in the current legal thread.

Do not publish this draft as final terms.

Fact basis:
- No jurisdiction-specific legal position in repo docs.
- CEO review on `TRI-24` (2026-05-20)
- Board comment on `TRI-39` (2026-05-20): maximum lawful disclaimers/no SLA/no
  public registration direction.
- CEO decision on `TRI-38` (2026-05-21): counsel required; no publication; no
  counsel-approved text or template available.

## 12) Changes to Terms

Trix may update terms as product behavior and deployment practices evolve.
Material revisions should be versioned and dated.

Fact basis:
- MVP behavior is actively evolving in `docs/mvp-checklist.md` and
  `docs/security.md`.
