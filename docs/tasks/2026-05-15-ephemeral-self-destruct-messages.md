# Task: Disappearing Messages With Local Expiration And Retraction

You are the next coding agent working in the Trix repo. Add disappearing-message
support with honest security wording: local expiration plus best-effort XEP-0424
retraction, not guaranteed destruction.

## Current Context

Relevant files:

- `docs/security.md`
- `docs/tasks/2026-05-15-xep-0308-0424-edit-retract.md`
- `docs/xmpp-migration/protocol-feature-map.md`
- `apple/Sources/Shared/Models/TrixModels.swift`
- `apple/Sources/Shared/Services/TrixServiceProtocols.swift`
- `apple/Sources/Shared/Services/XMPPMartinService.swift`
- `apple/Sources/Shared/Services/MockTrixService.swift`
- `apple/Sources/Shared/ViewModels/TimelineViewModel.swift`
- `apple/Sources/Shared/Views/TrixTimelineView.swift`
- `apple/Sources/Shared/App/XMPPLiveSmokeRunner.swift`

The edit/retract task should land before this one if possible. The timeline
already has local encrypted cache behavior and OMEMO send gates.

## Goal

Users can send a message with an expiration timer. The timer is conveyed inside
encrypted message content where possible, local clients remove or tombstone the
message after expiration, and the sender sends a best-effort XEP-0424 retraction.

## Non-Goals

- Do not claim screenshots, copied text, server backups, MAM history, or offline
  clients can be reliably erased.
- Do not create plaintext timer metadata unless the product explicitly accepts
  that leakage and `docs/security.md` documents it.
- Do not apply to attachments or voice messages in the first slice unless their
  encrypted descriptors and local file cleanup are handled end to end.
- Do not depend on clock precision for security guarantees.

## Implementation Plan

1. Decide the first supported scope:
   - own outgoing text messages only is the safest first slice;
   - DM before MUC unless group id stability and retraction behavior are proven.
2. Extend `TrixTimelineItem` with backward-compatible expiration metadata:
   - `expiresAt`;
   - `expirationStartedAt`;
   - `isExpired`;
   - optional `expiredLocallyAt`;
   - optional `retractionSentAt`.
3. Encode expiration metadata inside the OMEMO-encrypted message descriptor or
   encrypted body wrapper. Avoid outer stanza plaintext timer fields unless
   explicitly documented.
4. Add composer controls:
   - timer picker with small fixed set of durations;
   - visible timer state on the compose surface;
   - no hidden default timer.
5. Add timeline rendering:
   - countdown/expiry affordance for outgoing and received items;
   - expired tombstone state;
   - local cache update without layout jumps.
6. Add expiration scheduler in the view model/service boundary:
   - schedule local expiration for visible/cache items;
   - clean local decrypted text from cache when expired;
   - send XEP-0424 retraction for own outgoing messages when online;
   - queue/retry retraction best-effort if offline.
7. Add MAM/restart behavior:
   - expired items stay expired after restart;
   - reloaded MAM items with expired timers do not reappear as readable text;
   - future decrypted old messages with past `expiresAt` expire immediately.
8. Add live smoke:
   - `dm-disappearing-message` sends a short-lived encrypted DM;
   - peer decrypts before expiration;
   - both sides expire/tombstone;
   - sender retraction is observed if online.
9. Update `docs/security.md` with explicit caveats.

## Acceptance Criteria

- Users can send an expiring DM text message.
- Expiration metadata is not visible as plaintext unless documented as accepted
  metadata.
- Expired messages do not reveal body text after restart/MAM reload.
- Retraction is best effort and does not overpromise remote deletion.
- Existing normal text, reaction, attachment, and edit/retract behavior still
  works.

## Verification Commands

```bash
(cd apple && xcodegen generate)
xcodebuild -project apple/TrixMatrix.xcodeproj -scheme TrixMatrixiOS -destination 'platform=iOS Simulator,name=iPhone 17' build CODE_SIGNING_ALLOWED=NO
xcodebuild -project apple/TrixMatrix.xcodeproj -scheme TrixMatrixMac -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
git diff --check
```

Also run scrubbed `dm-disappearing-message` live smoke. Add group coverage only
after XEP-0424 group retraction behavior is already proven.
