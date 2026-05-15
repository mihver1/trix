# Task: iOS Screenshot And Screen Recording Indicators

You are the next coding agent working in the Trix repo. Add iOS-only indicators
for screenshots and screen recording without pretending to block capture.

## Current Context

Relevant files:

- `apple/Sources/iOS/TrixiOSApp.swift`
- `apple/Sources/iOS/TrixiOSAppDelegate.swift`
- `apple/Sources/Shared/App/TrixAppModel.swift`
- `apple/Sources/Shared/Models/TrixModels.swift`
- `apple/Sources/Shared/ViewModels/TimelineViewModel.swift`
- `apple/Sources/Shared/Views/TrixTimelineView.swift`
- `docs/security.md`

Apple's screenshot notification is posted after the screenshot is taken. Screen
capture/recording can be detected through screen-capture state, but iOS apps
cannot reliably prevent another device or OS-level capture.

## Goal

When the user takes a screenshot or starts/stops screen recording on iOS, Trix
shows a chat-level indicator. The first slice should be local-only unless the
product explicitly chooses to send an encrypted room event.

## Non-Goals

- Do not block screenshots or screen recordings.
- Do not delete messages because a screenshot was detected.
- Do not send screenshot images, screen contents, or decrypted message text.
- Do not implement macOS screen-capture detection in this iOS task.
- Do not make APNs payloads or local notifications include screenshot context.

## Implementation Plan

1. Add an iOS-only capture monitor:
   - observe `UIApplication.userDidTakeScreenshotNotification`;
   - observe `UIScreen.capturedDidChangeNotification` or the current recommended
     capture-state API for iOS 17+;
   - expose events through a shared protocol so non-iOS builds compile cleanly.
2. Add a small app-model/timeline event path:
   - local ephemeral banner in the current room;
   - optional local timeline system item if that better matches existing UI;
   - no server send in the first slice.
3. If product later wants peer-visible events:
   - send only an encrypted generic event such as screenshot detected;
   - do not include room title, body text, screenshots, or filenames in
     plaintext;
   - document event metadata visibility.
4. Add UI:
   - show a compact indicator in the active chat;
   - clear it automatically after a short interval;
   - for active screen recording, keep a persistent nonblocking banner.
5. Add tests/mocks:
   - simulate screenshot notification;
   - simulate screen capture state changes;
   - verify the timeline does not mutate server-backed messages for local-only
     indicators.
6. Update `docs/security.md`:
   - screenshot detection is post-factum;
   - screen recording indication is advisory;
   - compromised endpoints remain out of scope.

## Acceptance Criteria

- iOS builds show a local chat indicator after a screenshot.
- iOS builds show active/inactive indication for screen recording.
- macOS builds compile without UIKit screenshot APIs.
- No screenshot image, decrypted content, filename, APNs token, or private data is
  logged or sent.
- Documentation does not imply capture prevention.

## Verification Commands

```bash
(cd apple && xcodegen generate)
xcodebuild -project apple/TrixMatrix.xcodeproj -scheme TrixMatrixiOS -destination 'platform=iOS Simulator,name=iPhone 17' build CODE_SIGNING_ALLOWED=NO
xcodebuild -project apple/TrixMatrix.xcodeproj -scheme TrixMatrixMac -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
git diff --check
```

Manual simulator/device testing is required for the actual UIKit notifications.
