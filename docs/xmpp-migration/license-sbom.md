# XMPP Apple Dependency License Record

This record covers the SwiftPM dependencies currently pinned by
`apple/project.yml` and `apple/TrixMatrix.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
It is an engineering compliance note, not legal advice.

## Pinned Dependencies

| Dependency | Version | Revision | Local license evidence | Effective license for this record |
| --- | --- | --- | --- | --- |
| Tigase Martin | 3.2.4 | `1d70e9e7eb51a7faa500832be6400a39f86083f7` | `SourcePackages/checkouts/Martin/COPYING` | AGPL-3.0 |
| MartinOMEMO | 2.2.3 | `3c162154d646aa258c9a86c0a07655a536e55a94` | `SourcePackages/checkouts/MartinOMEMO/LICENSE` | GPL-3.0 |
| Tigase libsignal | 1.0.0 | `d23d5af0d729cf66b93cea607f3f84a34b9fddfd` | `SourcePackages/checkouts/libsignal/LICENSE` | GPL-3.0 |
| tigase-logging.swift | 1.0.0 | `382e2e85e64f8b1e3fcb71a996a030bf1b62ecb3` | `SourcePackages/checkouts/tigase-logging.swift/COPYING` | AGPL-3.0 |

## MVP Decision

For the current non-commercial private friends app, the Tigase Martin plus
MartinOMEMO path is accepted for the XMPP + OMEMO MVP and TestFlight validation
because it is the only checked-in Apple path that currently provides the
required XMPP and OMEMO building blocks without custom cryptography.

This acceptance is conditional:

- keep the dependency pins and license evidence visible in the repo;
- include GPL/AGPL notices and source-availability handling before distributing
  builds outside the trusted private test group;
- do not copy Tigase or Monal source into Trix as an untracked fork;
- do not ship a proprietary or commercial distribution on this stack without
  separate legal review or a commercial/permissive license path.

## Ship/No-Ship Recommendation

- Ship recommendation: proceed for private friend-group MVP and TestFlight
  validation only, with this license record tracked in-repo.
- No-ship recommendation: block broader/public/proprietary distribution on this
  dependency stack until GPL/AGPL notice and source-availability obligations are
  implemented and reviewed.

## Remaining Compliance Blocker

- Blocker: distribution beyond the trusted private test group is not approved on
  the current stack yet.
- Owner: CTO with product owner/legal reviewer input.
- Unblock action: complete and review a release compliance pack (third-party
  notices, source-availability plan, and distribution-channel decision), then
  re-evaluate ship scope.

## Operational Impact

The license decision does not change the security rules: product chats must
still fail closed when OMEMO state is unavailable, the app must not silently
trust devices, and Trix must not implement custom cryptography.
