# macOS: Matrix UI Lacks Legacy Product Parity

## Summary

The current macOS Matrix UI is visually and ergonomically far below the existing
Trix macOS app. It should become a real desktop messenger surface, not a
scaffold wrapped around Matrix calls.

## User-visible symptom

- macOS layout, spacing, toolbar actions, message rows, attachment rows, and
  account/recovery surfaces feel unfinished.
- The app does not resemble the legacy Trix desktop product quality.
- Desktop-specific affordances are missing or cramped into the wrong surface.

## Expected behavior

- macOS should use a polished desktop layout aligned with legacy Trix product
  behavior.
- Room list, timeline, composer, details/settings entry points, attachment
  actions, and recovery/verification flows should be structured for repeated
  desktop use.
- The UI should remain quiet, utilitarian, and information-dense rather than
  looking like a sample app.

## Reference boundary

- Use legacy Trix as a UX/behavior reference by running it, reviewing
  screenshots/docs, and reading legacy code to understand existing behavior.
- Do not copy legacy implementation code into the Matrix client.
- Do not modify legacy `apps/macos/scripts/archive-testflight.sh`.
- Keep protocol behavior in Matrix SDK/service/view-model layers.

## Investigation notes

- Start in `MatrixRootView.swift`, `MatrixTimelineView.swift`, account/recovery
  views, and platform-specific macOS app entry points.
- Identify shared views that should remain shared and desktop-only layouts that
  should become macOS-specific.
- Compare the main chat workflow against the legacy product: sidebar, content
  density, message grouping, composer, attachment affordances, and account
  settings entry points.
- Capture before/after screenshots.

## Implementation requirements

- Prefer incremental UI slices with clear workflow coverage.
- Do not put settings, account recovery, and device verification permanently
  into the chat sidebar.
- Preserve Matrix SDK E2EE boundaries and visible verification limitations.
- Make text and controls fit at common macOS window sizes.

## Verification plan

- Run `just matrix-macos-run`.
- Inspect room list, DM, group room, invite, composer, attachment, error, and
  recovery surfaces.
- Resize the window through compact and wide desktop sizes.
- Compare against legacy UX reference without copying code.
- Run iOS checks if shared SwiftUI views changed.

## Acceptance criteria

- macOS Matrix UI no longer looks like a scaffold.
- Main chat workflows match the expected desktop Trix product quality.
- Improvements do not regress iOS shared surfaces or Matrix behavior.
