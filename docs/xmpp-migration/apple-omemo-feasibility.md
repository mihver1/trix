# Apple OMEMO Feasibility

Apple-side XMPP + OMEMO is technically feasible for iOS and macOS, but it is not
yet a safe dependency swap. The current Apple app shape is favorable because
SwiftUI already talks through service/view-model boundaries. The hard part is the
production-acceptable OMEMO implementation, licensing, interop, and group-chat
behavior.

## Product Context

Trix is a non-commercial application for a private group of friends. That makes
GPL/AGPL obligations much more plausible than they would be for a closed
commercial product, but they still need an explicit decision. Non-commercial use
does not automatically remove source-distribution, attribution, copyleft, or app
distribution obligations.

Given that context, the first spike path should be Tigase Martin plus
MartinOMEMO unless license review finds an unacceptable obligation.

## Candidate Stacks

### Tigase Martin And MartinOMEMO

Tigase Martin is the first spike candidate. It is the most coherent Swift-native
XMPP stack found so far, and it advertises iOS and macOS support plus XMPP
features such as MUC, MAM, push, HTTP upload, and OMEMO through MartinOMEMO.

Decision: accepted for the current non-commercial private MVP/TestFlight
validation path. The pinned stack and license evidence are recorded in
`license-sbom.md`: Martin `3.2.4` and tigase-logging.swift `1.0.0` are treated
as AGPL-3.0 dependencies, while MartinOMEMO `2.2.3` and Tigase libsignal
`1.0.0` are treated as GPL-3.0 dependencies. Distribution outside the trusted
private group still needs source/license handling or a commercial/permissive
license path.

### XMPPFramework

XMPPFramework is an Apple-native Objective-C framework with Swift import support
and permissive BSD licensing for the framework itself. It has broad XMPP module
coverage and is the best permissive transport base.

Blocker: OMEMO is not green-lit by the framework alone. Its OMEMO module depends
on a Double Ratchet/X3DH implementation such as SignalProtocol-ObjC, which still
brings GPL obligations, and parts of the ecosystem use older OMEMO namespaces.

### Monal

Monal is the most useful Apple reference and interop target. It is a current
iOS/macOS XMPP client and claims encrypted private and group chats, MAM, HTTP
upload, push, and broad XEP coverage.

Gate: treat Monal as a reference, not a clean drop-in library. Its OMEMO path
also involves SignalProtocolObjC/GPL-family dependencies, so reuse still requires
license review.

## Technical Blockers

- OMEMO licensing obligations are accepted for the current private
  non-commercial validation path; broader distribution still requires
  source/license handling or legal review.
- XEP-0384 is still experimental, and current spec namespace behavior may differ
  from older deployed ecosystem behavior.
- Group OMEMO requires non-anonymous, preferably members-only MUC rooms and real
  JID membership tracking.
- OMEMO does not define the product trust UX; Trix must expose device trust and
  fingerprint state and must not silently trust all devices.
- The first MartinOMEMO integration now has persistent local OMEMO state,
  CryptoKit AES-GCM, DM device fingerprint display, manual trust, and encrypted
  DM text send after trust. The MVP checklist records live two-account
  send/receive validation.
- Group OMEMO text send/receive has passed a three-account live smoke. Broader
  group history, removal, and second-device behavior remain separate validation
  items.
- MAM can replay encrypted stanzas, but offline catch-up still depends on OMEMO
  prekey/session behavior.
- HTTP upload URLs are bearer-style; encrypted media requires client-side media
  wrapping and an explicit metadata exposure policy.
- APNs uses `trix-push-gateway` behind XMPP push semantics. Server modules do
  not send APNs directly. Signed macOS APNs delivery has passed with generic,
  plaintext-free visible text, and the live gateway now handles XMPP component
  publishes as silent sync wakes. Treat any iOS physical-device proof as a
  platform-specific follow-up, not as the current APNs MVP blocker.

## Required Smoke Tests

1. Compile iOS and macOS with the selected stack behind the protocol-neutral
   service adapter.
2. Connect two accounts over TLS, bind resources, restore sessions from Keychain,
   and resume streams.
3. Publish OMEMO device lists and bundles.
4. Send encrypted one-to-one messages across two devices per account, online and
   offline.
5. Fetch MAM history after reconnect or reinstall and decrypt without losing
   ratchet state.
6. Create a non-anonymous members-only MUC with three users.
7. Verify encrypted group send/receive, offline catch-up, invite/join, member
   removal, and no future decrypt for removed members.
8. Show device trust state, new-device warning, fingerprint compare, trust, and
   untrust actions.
9. Send image and file attachments via HTTP upload plus encrypted media wrapping;
   download and byte-compare.
10. Keep APNs routed through the Trix push service and confirm payloads contain
    no plaintext message bodies when new push paths are added.
11. Interop-test with Monal and at least one non-Apple OMEMO client before
    claiming XMPP ecosystem compatibility.
12. Keep the SBOM/license record current before distribution.

## Decision

Continue Apple XMPP implementation only in fail-closed slices: no plaintext
fallback, no silent device trust, and no custom crypto. For the current
non-commercial friends app, Tigase Martin plus MartinOMEMO is the accepted MVP
path with GPL/AGPL obligations documented in `license-sbom.md`. Launch readiness
still depends on encrypted-call signed-device proof, signed two-device trust
proof, the reviewed recovery/backfill blocker, and any broader multi-device or
interop validation called out in `docs/mvp-checklist.md`.
