# Known Bugs

This folder tracks user-visible Matrix Apple MVP bugs that must be fixed before
the app is treated as production-ready.

Each bug has its own file with the expected behavior, investigation notes,
implementation boundaries, and verification plan. Future agents must keep
Matrix SDK calls behind the service/view-model boundary and must not add custom
crypto, custom protocol handling, trust-all shortcuts, local verified overrides,
or secret logging.

Legacy Trix may be used as a UX and behavior reference by running the app,
reviewing screenshots/docs, and reading legacy code to understand existing
behavior. Do not copy legacy implementation code into the new Matrix client, and
do not modify legacy TestFlight scripts while fixing these bugs unless the user
explicitly reopens that scope.

## iOS

- [iOS opens the first dialog automatically](ios-auto-opens-first-dialog.md)
- [iOS attachment rows skip the explicit download/open flow](ios-attachment-download-flow.md)
- [iOS Matrix UI lacks legacy product parity](ios-legacy-parity-ui.md)
- [iOS DM rooms are missing from the room list](ios-dm-rooms-missing.md)

## macOS

- [macOS attachment transfer needs manual picker/open release revalidation](macos-attachment-transfer-failed.md)
- [macOS Matrix UI lacks legacy product parity](macos-legacy-parity-ui.md)
- [macOS navigation and settings structure is wrong](macos-three-column-settings.md)
