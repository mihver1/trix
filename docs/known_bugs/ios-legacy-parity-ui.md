# iOS: Matrix UI Lacks Legacy Product Parity

## Summary

The current iOS Matrix UI is visibly below the legacy Trix product quality. The
Matrix migration should keep the protocol change hidden behind a native product
experience that feels like Trix, not like a scaffold.

## User-visible symptom

- The iOS UI looks like an early scaffold.
- Layout, spacing, message rows, side surfaces, buttons, and navigation do not
  match the quality of the existing Trix iOS app.
- Core chat workflows feel unfinished even though Matrix protocol operations
  are wired.

## Expected behavior

- iOS should feel like the existing Trix app adapted to Matrix, not a new
  generic demo client.
- The room list, invite list, timeline, composer, attachment rows, account
  state, recovery/verification surfaces, empty states, and errors should have a
  coherent native style.
- Message rows should be readable, dense enough for chat, and stable during
  refresh.
- Common actions should use platform-native controls and icons where
  appropriate.

## Reference boundary

- Use legacy Trix as a UX/behavior reference by running the app, reviewing
  screenshots/docs/checklists, and reading legacy code to understand existing
  behavior.
- Do not copy legacy implementation code into the Matrix client.
- Do not route Matrix SDK calls into SwiftUI views to chase visual parity.
- Do not modify legacy TestFlight scripts.

## Investigation notes

- Start with `apple/Sources/Shared/Views/MatrixRootView.swift`,
  `MatrixTimelineView.swift`, and related account/settings views.
- Identify which current view surfaces are shared by iOS and macOS and which
  need platform-specific layout treatment.
- Compare workflow shape against the legacy product: inbox, DM/group room
  entry, timeline, composer, attachment affordances, account/recovery.
- Capture screenshots before changes and after changes for both iOS and macOS.

## Implementation requirements

- Keep service/view-model boundaries intact.
- Prefer incremental, reviewable UI slices. Do not attempt a full redesign and
  protocol changes in the same patch.
- Keep text within buttons/rows stable across iPhone sizes.
- Avoid marketing-style hero layouts. This is an operational messenger UI.
- Preserve visible device verification limitations and recovery state.

## Verification plan

- Run `just matrix-ios-run` on the default simulator and at least one larger
  iPhone simulator if available.
- Verify login, room list, invite list, DM room, group room, composer,
  attachment row, recovery UI, and error states.
- Take screenshots for comparison with the legacy UX reference.
- Build with the normal iOS and macOS Matrix checks after shared view changes.

## Acceptance criteria

- The iOS Matrix app no longer looks like a scaffold.
- Primary chat workflows are visually aligned with legacy Trix product
  expectations without copying legacy code.
- UI changes do not regress Matrix room sync, invite handling, attachments, or
  recovery/device verification visibility.

## Fix status

First iOS parity slice applied on May 6, 2026:

- iOS uses a phone-native Chats/Settings tab shell instead of the shared desktop
  split-view surface.
- The inbox shows account state, dense room rows, unread badges, room security
  markers, pending invite actions, pull-to-refresh, and a compose affordance.
- The timeline uses native chat bubbles, a compact room header, styled composer,
  and explicit attachment download/open/share/export flow.
- Device verification and recovery remain visible in Settings; Matrix SDK calls
  remain behind service/view-model boundaries.

Remaining polish should be tracked as narrower follow-up bugs rather than
reopening a scaffold-level UI rewrite.

Second iOS parity polish slice applied on May 6, 2026:

- Chat rows open timelines through programmatic phone navigation instead of a
  value-link row, so tapping the room list no longer depends on the visible
  navigation affordance.
- The account card was reduced to a fixed top inbox header.
- Room-list chevrons were removed from the iOS inbox rows.
- DM/group state is marked with person/person.2 symbols, and room E2EE state is
  marked with a green closed lock or yellow open lock instead of repeated text
  labels.
