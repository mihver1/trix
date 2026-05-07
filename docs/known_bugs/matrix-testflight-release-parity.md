# Matrix: TestFlight Release Parity

Status: Open.

## Summary

Legacy iOS and macOS clients have established TestFlight/archive scripts. The
new Matrix Apple app builds locally, but TestFlight packaging for `apple/` is
still listed as TODO.

## Legacy behavior to match

- iOS has `apps/ios/scripts/build-testflight.sh`.
- macOS has `apps/macos/scripts/archive-testflight.sh`.
- Existing release tooling should remain intact while Matrix release tooling is
  added.

Relevant legacy entry points:

- `apps/ios/scripts/build-testflight.sh`
- `apps/macos/scripts/archive-testflight.sh`
- `docs/superpowers/plans/2026-03-28-macos-testflight-archive.md`

## Current Matrix state

- `apple/project.yml` defines iOS and macOS Matrix targets.
- Local iOS/macOS builds are documented.
- `docs/mvp-checklist.md` and `apple/README.md` still list TestFlight packaging
  as TODO.

## Required implementation

- Add Matrix-specific iOS archive/export/upload path or extend existing scripts
  without breaking legacy scripts.
- Add Matrix-specific macOS archive/export/upload path or extend existing
  scripts without breaking legacy scripts.
- Preserve app identifiers, team settings, entitlements, and APNs environments
  already configured for Matrix targets.
- Capture raw `xcodebuild`/`xcrun altool`/Transporter stderr in failures.
- Document required environment variables and credentials without committing
  secrets.

## Boundaries

- Do not modify legacy TestFlight scripts unless explicitly needed and safe.
- Do not commit App Store Connect keys or provisioning profiles.
- Do not hide upload errors behind generic wrapper messages.

## Acceptance criteria

- There is a documented command for Matrix iOS TestFlight archive/upload.
- There is a documented command for Matrix macOS TestFlight archive/upload.
- Entitlements and signing are verified.
- Failure logs preserve actionable raw output without secrets.

## Verification plan

- Run `cd apple && xcodegen generate`.
- Run unsigned local builds first.
- Run archive/export with safe local signing credentials if available.
- If upload is attempted, report exact raw failure or success.
- `git diff --check`
