# Task: XEP-0333 Chat Markers And Server-Backed Read Sync

You are the next coding agent working in the Trix repo. Add server-backed read
markers without regressing the current local unread behavior.

## Current Context

Relevant files:

- `docs/security.md`
- `docs/xmpp-migration/protocol-feature-map.md`
- `apple/README.md`
- `apple/Sources/Shared/Models/TrixModels.swift`
- `apple/Sources/Shared/Services/TrixServiceProtocols.swift`
- `apple/Sources/Shared/Services/XMPPMartinService.swift`
- `apple/Sources/Shared/ViewModels/RoomListViewModel.swift`
- `apple/Sources/Shared/ViewModels/TimelineViewModel.swift`
- `apple/Sources/Shared/App/TrixAppModel.swift`
- `apple/Sources/Shared/App/XMPPLiveSmokeRunner.swift`

The current unread model is local: reload preserves unread for inactive rooms
and clears only on explicit room open. Service room summaries still often return
`unreadCount: 0`.

## Goal

Opening a room sends a displayed/read marker for the latest visible message.
Other devices for the same account converge on the read cursor, and peers can
observe read/displayed state where appropriate.

## Non-Goals

- Do not treat preview refresh, background sync, or APNs wake as read.
- Do not regress the current local unread preservation behavior.
- Do not expose message bodies in marker stanzas.
- Do not overclaim XEP-0333 as a complete same-account multi-device sync
  solution without validating how Martin/ejabberd archive and carbon marker
  stanzas for this deployment.

## Implementation Plan

1. Validate Martin support for chat markers. If there is no module, use raw
   stanza construction behind `XMPPMartinService`, not SwiftUI views.
2. Add stable latest-message tracking to timeline items if needed. Markers
   should target the latest visible message id/stanza id, not local preview
   state.
3. Add service APIs:
   - `markRoomDisplayed(roomID:messageID:session:)`;
   - optionally `readMarkerState(roomID:session:)`.
4. Send XEP-0333 displayed markers on explicit room open and when the user
   visibly reaches the bottom/newest message. Do not send from background
   refresh.
5. Parse incoming chat markers from:
   - peer DMs;
   - message carbons for the same account if present;
   - MAM reload if marker stanzas are archived.
6. Add a same-account convergence strategy:
   - first try archived/carboned XEP-0333 markers;
   - if that is not reliable, add a documented Trix-owned read cursor store
     behind the control plane or an XMPP private storage/PEP path.
7. Integrate with `RoomListViewModel.reload(...)` so server-backed read cursors
   can lower unread counts without allowing preview reload to mark read.
8. Add live smoke `read-markers`:
   - account A primary and account A secondary;
   - account B sends encrypted DM;
   - A primary opens room and sends marker;
   - A secondary reloads and sees read cursor converge;
   - B observes displayed marker if supported;
   - scrubbed output only.
9. Update `docs/security.md` to document that read/display markers reveal
   message ids and read timing metadata to the server and participants.

## Acceptance Criteria

- Explicit room open sends a marker; background refresh does not.
- Same-account device read state converges in a live smoke or the task documents
  the precise blocker and leaves follow-up work.
- Local unread preservation still works for inactive rooms.
- Marker parsing survives restart/MAM where supported.
- No decrypted message text appears in marker payloads or logs.

## Verification Commands

```bash
(cd apple && xcodegen generate)
xcodebuild -project apple/TrixMatrix.xcodeproj -scheme TrixMatrixiOS -destination 'platform=iOS Simulator,name=iPhone 17' build CODE_SIGNING_ALLOWED=NO
xcodebuild -project apple/TrixMatrix.xcodeproj -scheme TrixMatrixMac -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
git diff --check
```

Also run scrubbed live smoke for `read-markers`. If same-account convergence is
not possible with XEP-0333 alone, document the required Trix cursor mechanism.
