# Reviewed OMEMO Recovery Decision (2026-05-20)

## Scope

Decide whether Trix can safely ship OMEMO key backup/recovery on the current
Apple stack, using only reviewed upstream APIs.

## Pinned Dependencies (from `apple/TrixMatrix.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`)

- Martin `3.2.4` (`1d70e9e7eb51a7faa500832be6400a39f86083f7`)
- MartinOMEMO `2.2.3` (`3c162154d646aa258c9a86c0a07655a536e55a94`)
- libsignal `1.0.0` (`d23d5af0d729cf66b93cea607f3f84a34b9fddfd`)

## Upstream API Evidence

- MartinOMEMO's public OMEMO lifecycle API includes device publication and
  removal (`removeDevices(withIds:)`), which updates local identity status,
  deletes remote bundle nodes, and republishes the OMEMO device list:
  - https://github.com/tigase/MartinOMEMO/blob/3c162154d646aa258c9a86c0a07655a536e55a94/Sources/MartinOMEMO/OMEMOModule.swift#L721-L737
- MartinOMEMO package dependencies for this release are Martin + libsignal;
  there is no separate backup/recovery module in the package manifest:
  - https://github.com/tigase/MartinOMEMO/blob/3c162154d646aa258c9a86c0a07655a536e55a94/Package.swift#L18-L20
- MartinOMEMO storage protocols expose sessions/prekeys/signed-prekeys/
  identity/sender-key operations, but no reviewed backup/export/import/recovery
  interface:
  - https://github.com/tigase/MartinOMEMO/blob/3c162154d646aa258c9a86c0a07655a536e55a94/Sources/MartinOMEMO/SignalStorage.swift#L113-L187
- Local source scan on the pinned MartinOMEMO/libsignal checkouts for
  `backup|recover|recovery|export|import|restore|transfer` returned no recovery
  API surface intended for OMEMO account-state restore.

## Decision

Do **not** ship server-side OMEMO key backup/recovery in this slice.

Reason: on the pinned reviewed stack there is no upstream-reviewed API for
securely exporting/importing full OMEMO private state (identity key pair,
prekeys, sessions, sender keys, trust state) across device reinstall/replace
without introducing custom crypto or manual key movement.

## Product/Implementation Result

- Keep recovery setup/confirm unavailable in the Martin-backed service.
- Keep Settings and docs explicit: reinstall/Keychain reset creates a new OMEMO
  device, and old ciphertext not encrypted for the replacement device may remain
  unavailable.
- No custom backup crypto, no manual server key movement, no secret logging.

## Revisit Conditions

Re-open this decision only when a reviewed upstream API for OMEMO state
backup/recovery exists for the pinned stack (or after a deliberate dependency
change), followed by a live restore proof that validates the exact promised
behavior.
