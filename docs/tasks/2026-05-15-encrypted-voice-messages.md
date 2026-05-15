# Task: Encrypted Voice Messages

You are the next coding agent working in the Trix repo. Add voice messages as
encrypted attachments using the existing attachment pipeline.

## Current Context

Relevant files:

- `docs/security.md`
- `docs/xmpp-migration/protocol-feature-map.md`
- `apple/README.md`
- `apple/Sources/Shared/Models/TrixModels.swift`
- `apple/Sources/Shared/Services/TrixServiceProtocols.swift`
- `apple/Sources/Shared/Services/XMPPMartinService.swift`
- `apple/Sources/Shared/ViewModels/TimelineViewModel.swift`
- `apple/Sources/Shared/Views/TrixTimelineView.swift`
- `apple/Sources/Shared/Views/TrixInlineAttachmentPreview.swift`
- `apple/Sources/Shared/App/XMPPLiveSmokeRunner.swift`

Current attachments are encrypted with MartinOMEMO file encryption before HTTP
upload. The original filename, MIME type, size, image dimensions, and sticker
metadata are inside the OMEMO-encrypted descriptor, while the HTTP upload sees a
generic encrypted filename and `application/octet-stream`.

## Goal

Users can record, send, receive, and play short voice messages in DMs and MUCs.
Voice media is encrypted and uploaded through the existing attachment path.

## Non-Goals

- Do not create a server-side audio transcoding path.
- Do not upload plaintext waveform data or original audio filenames outside the
  OMEMO descriptor.
- Do not introduce a new media protocol.
- Do not attempt Opus first unless native encode/decode support is validated for
  both iOS and macOS. AAC/M4A is the safer Apple-first path.

## Implementation Plan

1. Add attachment kind support:
   - extend `TrixTimelineAttachmentKind` with `voice`;
   - add voice metadata such as duration milliseconds, codec, and optional local
     waveform samples;
   - keep decoding backward compatible.
2. Build an Apple audio recorder/player service behind a small protocol:
   - request microphone permission;
   - record AAC/M4A first (`audio/mp4` or `audio/aac`);
   - enforce max duration and max bytes;
   - write temp files in app-controlled storage and clean them up.
3. Add a local waveform generator from recorded/decrypted audio. Store waveform
   only locally or inside the OMEMO-encrypted descriptor.
4. Reuse `sendAttachment` with a `TrixAttachmentUpload` carrying voice metadata.
5. Render a compact voice bubble with play/pause, duration, progress, and
   waveform. It should work for local echo and received downloads.
6. Add download/playback failure states and retry.
7. Add live smoke `dm-voice-attachment` first:
   - generate a tiny deterministic audio fixture instead of using microphone;
   - send through encrypted attachment path;
   - peer downloads/decrypts and validates bytes/MIME/duration metadata;
   - print only IDs, byte counts, and booleans.
   Add `group-voice-attachment` after DM passes.
8. Update `docs/security.md` to mention voice messages are encrypted
   attachments and that waveform/audio metadata handling must stay plaintext-free
   server-side.

## Acceptance Criteria

- Voice messages send and receive in encrypted DMs.
- Group voice sends remain blocked unless the MUC recipient set and trusted
  active OMEMO devices are validated.
- Playback works on iOS and macOS.
- Server upload path still receives only encrypted bytes and generic upload
  metadata.
- Live smoke validates encrypted upload/download/decrypt without printing audio
  content, filenames, URLs, or media keys.

## Verification Commands

```bash
(cd apple && xcodegen generate)
xcodebuild -project apple/TrixMatrix.xcodeproj -scheme TrixMatrixiOS -destination 'platform=iOS Simulator,name=iPhone 17' build CODE_SIGNING_ALLOWED=NO
xcodebuild -project apple/TrixMatrix.xcodeproj -scheme TrixMatrixMac -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
git diff --check
```

Also run scrubbed live smoke for `dm-voice-attachment`, and group coverage if
implemented.
