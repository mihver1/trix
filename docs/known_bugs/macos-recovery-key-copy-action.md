# macOS: Recovery Key View Has No Copy Action

## Summary

The macOS recovery UI displays or asks for recovery keys but does not provide a
copy action for generated keys. Desktop users need a direct copy button that
uses the macOS pasteboard without logging or persisting the key.

## User-visible symptom

- User starts Matrix SDK recovery setup on macOS.
- A generated recovery key is shown.
- There is no copy button.

## Expected behavior

- The generated recovery key surface should include an explicit copy button.
- The button should use the macOS pasteboard and show immediate feedback.
- Recovery confirmation inputs should remain explicit and should not silently
  consume clipboard contents.

## Investigation notes

- Start in shared device verification/recovery views and
  `DeviceVerificationViewModel`.
- Decide whether the copy action can be shared with iOS through a small
  platform abstraction.
- Confirm where recovery key UI should live after the macOS settings window
  structure is fixed.

## Implementation requirements

- Do not log recovery keys.
- Do not save recovery keys in Keychain/UserDefaults just because the user
  copied them.
- Do not add reset identity, reset recovery, trust-all, or local verified
  shortcuts.
- Keep Matrix SDK recovery APIs as the only recovery mechanism.

## Verification plan

- Run `just matrix-macos-run`.
- Use a disposable recovery smoke account if recovery setup must be mutated.
- Generate a recovery key.
- Click copy and paste into a local scratch field to verify exact copy.
- Confirm logs and `TRIX_LIVE_SMOKE` output, if used, do not include the key.

## Acceptance criteria

- macOS recovery key UI has a copy button with feedback.
- The key is copied only to pasteboard at user request.
- No secret logging or unsupported recovery shortcuts are introduced.
