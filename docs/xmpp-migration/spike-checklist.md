# XMPP+OMEMO Spike Checklist

These items are gates. Do not treat them as solved by assumption. Each gate
must end with a written result: accepted path, rejected path, or blocker.

## Apple XMPP Library Gate

Question: which Apple-compatible XMPP library can support the required MVP
without custom crypto?

- [ ] Identify candidate Swift or Objective-C XMPP libraries.
- [x] Confirm iOS support.
- [x] Confirm macOS support.
- [x] Confirm Swift Package Manager or acceptable build integration.
- [ ] Confirm TLS and modern authentication support.
- [ ] Confirm stream management support.
- [ ] Confirm message archive support.
- [x] Confirm file upload support or a compatible extension path.
- [ ] Confirm active maintenance status.
- [x] Confirm license compatibility.
- [x] Produce an SBOM or dependency license report for the selected stack.
- [x] Decide whether GPL/AGPL obligations are acceptable for the non-commercial
      friends app, or whether a different library/commercial path is required.

Exit criteria:

- One library is selected with evidence, or the client implementation is
  blocked.
- Unsupported protocol features are listed as product or implementation risks.

## Apple OMEMO Gate

Question: can the selected Apple stack provide OMEMO for DMs and groups through
reviewed library APIs?

- [ ] Confirm OMEMO implementation availability.
- [x] Confirm one-to-one encrypted send and receive.
- [x] Confirm private group encrypted send and receive.
- [ ] Confirm device bundle publication and retrieval.
- [ ] Confirm multi-device behavior for one user.
- [ ] Confirm trust or verification model exposed by the library.
- [x] Confirm local crypto store persistence and reset behavior for local
      registration id, identity key pair, prekeys, signed prekeys, sessions,
      identities, and sender keys.
- [x] Confirm the app can detect missing or unsupported OMEMO state before send.
- [x] Confirm no application code needs to manually manipulate key material.
- [ ] Decide whether the implementation targets current `urn:xmpp:omemo:2`,
      older ecosystem namespaces, or an explicitly documented compatibility
      bridge inside the selected library.

Exit criteria:

- Two-account encrypted DM prototype passes.
- Three-account encrypted group prototype passes. The `group-e2ee` macOS live
  smoke passed on 2026-05-09.
- The blocked-state UX requirements are documented.
- If group OMEMO is not viable, the XMPP pivot is blocked until an acceptable
  library or protocol path is chosen.

Current result:

- MartinOMEMO is wired with a Keychain-backed local store and CryptoKit AES-GCM.
- Remote devices are saved as undecided by default; the Apple client now exposes
  DM device fingerprints and requires explicit manual trust before text send.
- DM text send is wired through MartinOMEMO encode/write after peer trust, and
  the checklist records live two-account send/receive validation.
- Group OMEMO text send/receive passed the three-account `group-e2ee` macOS live
  smoke on 2026-05-09.

## XMPP Server Gate

Question: which private XMPP server should Trix run?

- [ ] Evaluate candidate servers for private deployment.
- [ ] Confirm federation can be disabled.
- [x] Confirm account provisioning can be operator-controlled.
- [ ] Confirm OMEMO publish/subscribe requirements.
- [ ] Confirm private group support.
- [ ] Confirm archive support.
- [ ] Confirm upload support.
- [x] Confirm backup and restore path.
- [ ] Confirm observability and log redaction controls.
- [ ] Confirm resource usage fits the tiny self-hosted target.

Exit criteria:

- One server is selected with a local private configuration.
- Federation-disabled behavior is verified.
- Backup creation and restore are scripted. The local
  `server/xmpp/scripts/restore-verify.sh` native-Mnesia restore drill passed on
  2026-05-09.

## Control-Plane Gate

Question: which operations belong in Trix control-plane APIs versus direct XMPP
server administration?

- [x] Define account create as a localhost ejabberd API/backend operation behind
  a Trix operator wrapper.
- [x] Define invite lifecycle.
- [x] Define group create and membership operations.
- [x] Define profile metadata ownership.
- [x] Define health as a localhost ejabberd API/backend operation behind a Trix
  operator wrapper.
- [x] Define audit/diagnostic output and redaction rules.
- [x] Confirm ejabberd exposes a usable localhost admin API/backend path for
  health and disposable account create/delete smoke.
- [x] Confirm checked-in local operator commands for provision, reset-password,
  disable, directory search, archive/upload/push health, and cleanup.

Exit criteria:

- A control-plane contract exists before Apple clients depend on provisioning
  behavior.
- Normal MVP operations do not require manual database edits.

## History And Launch Gate

Question: what happens to existing Matrix and prototype data?

- [x] Confirm no Matrix data migration.
- [x] Confirm no Matrix bridge.
- [x] Confirm no Matrix room history import.
- [x] Confirm no Matrix device or recovery material import.
- [ ] Define the user-facing launch/reset message.
- [ ] Define whether prior local history is ignored or handled by an explicit
  export/reset message for the XMPP launch.

Exit criteria:

- Launch behavior is explicit and documented.
- No engineering task depends on Matrix-to-XMPP conversion.

## Notifications Gate

Question: how do notifications work without leaking plaintext?

- [ ] Confirm server-side push extension support.
- [x] Confirm APNs integration path for iOS registration plumbing.
- [x] Confirm macOS notification registration plumbing.
- [x] Confirm the Apple app handles remote pushes as generic sync notifications
      and does not display decrypted body notifications.
- [x] Confirm inactive iOS/macOS handling can show generic APNs notifications or
      local silent-sync fallback notifications without decrypted text, filenames,
      or attachment names.
- [x] Confirm a Trix APNs gateway/push component exists behind XEP-0357.
- [ ] Confirm signed-device APNs delivery reaches iOS and macOS.
- [ ] Confirm push payloads do not include decrypted message bodies in live APNs
      delivery or gateway logs.
- [ ] Confirm badge/unread state source.
- [ ] Confirm behavior while app is logged out or local keys are unavailable.

Exit criteria:

- Notification architecture is accepted or explicitly deferred before launch
  readiness.

Current result:

- Apple registration plumbing is present: platform APNs token capture,
  `TrixPushRegistrationService`, Martin `TigasePushNotificationsModule`
  register/enable, generic remote push handling, and generic local
  notifications for silent-sync fallback.
- `trix-push-gateway` now provides the private APNs sender and XEP-0114
  component for Martin/Tigase registration nodes. ejabberd `mod_push` remains
  necessary but does not send APNs directly.
- On 2026-05-10 the component was deployed on the VPS with deployment-local APNs
  credentials and connected to ejabberd as `push.trix.selfhost.ru`.
- MVP blocker: signed-device APNs delivery smoke still has not passed.

## Attachment Gate

Question: how are encrypted conversations linked to uploaded files?

- [ ] Confirm upload service.
- [ ] Confirm authentication and authorization model.
- [ ] Confirm size limits.
- [ ] Confirm retention and deletion behavior.
- [ ] Confirm how attachment references are sent inside encrypted messages.
- [ ] Confirm local preview/open/share behavior on iOS.
- [ ] Confirm local preview/open/share behavior on macOS.

Exit criteria:

- Attachment round-trip is proven for one image and one generic file.
- Server-side metadata exposure is documented.

## Release Gate

Question: how will the two Apple clients ship?

- [ ] Define XMPP iOS target name.
- [ ] Define XMPP macOS target name.
- [ ] Confirm bundle identifiers and entitlements.
- [ ] Confirm Keychain access groups.
- [ ] Confirm APNs entitlements if notifications are in scope.
- [ ] Confirm TestFlight/archive commands.
- [ ] Confirm upgrade behavior from earlier Matrix or prototype builds.

Exit criteria:

- Release commands are real and can be run by the repo owner.
- Upgrade/reset behavior is visible to users.

## Interop Gate

Question: can the Trix clients interoperate with the XMPP ecosystem without
weakening the private-product requirements?

- [ ] Interop encrypted DM with Monal.
- [ ] Interop encrypted group or document why group interop is intentionally
      Trix-only for the MVP.
- [ ] Interop encrypted DM with at least one non-Apple OMEMO client.
- [ ] Document OMEMO namespace/version expectations.
- [ ] Document where Trix intentionally uses control-plane behavior outside
      generic XMPP clients.

Exit criteria:

- Ecosystem-compatible behavior is proven where claimed.
- Any Trix-only behavior is explicit in product docs and does not weaken E2EE.
