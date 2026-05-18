# XMPP Migration Package

This folder is the planning package for the Trix pivot to a private XMPP
deployment with mandatory OMEMO encryption.

The package is intentionally scoped to planning. It does not create Apple code,
bridge code, or migration scripts.

## Direction

The target product remains a small private messenger with native Apple clients
and a centralized Trix operator control plane.

- Protocol: XMPP.
- End-to-end encryption: OMEMO is mandatory for DMs and groups.
- Federation: disabled.
- Server: private XMPP service managed through Trix operations. ejabberd is the
  first product candidate because the MVP needs centralized administration;
  Prosody remains a lightweight fallback for shell-managed spikes.
- Clients: two native Apple clients, iOS and macOS.
- Product target: feature parity with the intended Trix messenger experience.
- Control plane: centralized Trix-owned account, roster, group, policy, and
  operational administration.

## Non-Goals

- No Matrix data migration.
- No Matrix bridge.
- No mixed Matrix/XMPP interoperability layer.
- No custom cryptography.
- No custom message encryption format.
- No plaintext DM or group fallback.
- No public federated XMPP service for the MVP.

The XMPP migration must not depend on moving Matrix rooms, Matrix event history,
Matrix device state, or Matrix recovery material into XMPP.

## Documents

- [Implementation Plan](implementation-plan.md): phased delivery plan,
  definitions of done, and verification expectations.
- [Parity Checklist](parity-checklist.md): product parity target for the XMPP
  clients and control plane.
- [Protocol Feature Map](protocol-feature-map.md): feature-by-feature mapping
  from intended Trix behavior to XMPP primitives, Trix control-plane ownership,
  and Apple verification surfaces.
- [Apple OMEMO Feasibility](apple-omemo-feasibility.md): current Apple library
  candidates, licensing risks, interop risks, and the smoke tests required before
  implementation.
- [Spike Checklist](spike-checklist.md): unanswered technical questions that
  must be proven before locking the implementation.
- [Risk Register](risk-register.md): known risks, mitigations, and owners.

## Working Boundaries

The `server/xmpp/` scaffold may contain more than one candidate while the spike
is open. Treat ejabberd as the product-fit default for centralized control-plane
work, and Prosody as the lightweight fallback until the server gate closes.

Future implementation work should keep protocol and encryption calls behind
service boundaries so SwiftUI views do not depend directly on a specific XMPP
library. The same rule applies to server operations: client code should call
Trix control-plane APIs for provisioning and policy, not mutate server internals
directly.
