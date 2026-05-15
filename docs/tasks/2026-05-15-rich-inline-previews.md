# Task: Rich Inline Previews

You are the next coding agent working in the Trix repo. Extend inline previews
for encrypted attachments and add consent-gated link previews.

## Current Context

Relevant files:

- `docs/security.md`
- `docs/mvp-checklist.md`
- `apple/README.md`
- `apple/Sources/Shared/Models/TrixModels.swift`
- `apple/Sources/Shared/Views/TrixInlineAttachmentPreview.swift`
- `apple/Sources/Shared/ViewModels/TimelineViewModel.swift`
- `apple/Sources/Shared/Views/TrixTimelineView.swift`
- `apple/Sources/Shared/Services/XMPPMartinService.swift`

Inline media previews currently use the same local decrypt path as manual
attachment preview and are limited to bounded image attachments. Attachment
descriptors are OMEMO-encrypted, while HTTP upload/download handles encrypted
blobs only.

## Goal

Add richer previews without creating plaintext server access:

- video thumbnail previews for encrypted video attachments;
- document thumbnails or compact document cards for encrypted document
  attachments;
- link cards using Open Graph only after the user explicitly asks to load a
  preview for that URL/domain.

## Non-Goals

- Do not add server-side link unfurling.
- Do not auto-fetch Open Graph metadata when a message arrives or when the
  timeline appears.
- Do not run JavaScript, send cookies, use authenticated browser state, or follow
  unbounded redirect/download chains for link previews.
- Do not include link preview data in APNs payloads or local notification text.
- Do not log URLs, page titles/descriptions, attachment filenames, local temp
  paths, decrypted bytes, or media keys.

## Implementation Plan

1. Split preview support from the current image-only helper into an explicit model
   such as `TrixInlinePreviewKind`:
   - image;
   - video thumbnail;
   - document thumbnail/card;
   - consent-gated link card.
2. Keep encrypted attachment previews on the existing `service.downloadAttachment`
   path. Preview generation must happen after local decrypt, inside the client.
3. Video:
   - detect common video MIME types/extensions;
   - generate a bounded thumbnail with Apple media APIs from a local temporary
     decrypted file or in-memory asset path;
   - delete temporary files promptly;
   - keep a size cap and a failure state with retry.
4. Documents:
   - detect PDF and common document MIME types/extensions;
   - use platform thumbnail APIs where available, or fall back to a compact file
     card with type/size;
   - avoid storing plaintext document copies beyond temporary generation.
5. Links:
   - detect URLs locally from decrypted message body;
   - render an inert URL row first;
   - show a "Load preview" action that explains the URL will be fetched from the
     site and may reveal the user's network metadata;
   - fetch with an ephemeral `URLSession` configuration, no cookies, bounded
     timeout, bounded response size, and a small redirect limit;
   - parse only static HTML metadata such as `og:title`, `og:description`, and
     `og:image`;
   - require explicit consent before fetching remote images, or render metadata
     without the image in the first slice.
6. Cache generated preview metadata only locally. If persisted, encrypt it at rest
   and key it by account/room/message/URL or attachment id. A memory-only cache is
   acceptable for the first slice.
7. Add tests:
   - preview kind detection;
   - no URLSession request before consent;
   - Open Graph parser against local fixture HTML;
   - attachment preview failures are non-fatal.
8. Update `docs/security.md` with the metadata risks:
   - attachment previews do not expose plaintext to the server;
   - link previews disclose the URL fetch to the remote site after consent.
9. Update `apple/README.md` with supported preview types and limits.

## Acceptance Criteria

- Supported encrypted video attachments show a local thumbnail or a stable
  fallback card after decrypt.
- Supported document attachments show a thumbnail or a compact document card
  without uploading plaintext anywhere.
- A link preview network request is impossible before an explicit user action.
- Open Graph fetching uses an ephemeral, bounded client and test fixtures cover
  success/failure.
- No URLs, filenames, decrypted bytes, media keys, or local paths appear in logs.

## Verification Commands

```bash
(cd apple && xcodegen generate)
xcodebuild -project apple/TrixMatrix.xcodeproj -scheme TrixMatrixiOS -destination 'platform=iOS Simulator,name=iPhone 17' build CODE_SIGNING_ALLOWED=NO
xcodebuild -project apple/TrixMatrix.xcodeproj -scheme TrixMatrixMac -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
git diff --check
```

Also run focused tests for MIME detection, Open Graph parsing, and "no request
before consent". Use local fixture URLs in tests, not external network targets.

