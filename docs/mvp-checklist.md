# MVP Checklist

Use this checklist before treating the XMPP + OMEMO pivot as usable for real
private messages.

There are no live Matrix users to preserve. Do not build a Matrix bridge,
parallel Matrix service, or Matrix data migration path for this MVP.

## Legacy Product Parity Target

Validated from the XMPP MVP docs and current Apple/XMPP implementation, not by
copying old implementation details.

- [x] Login, logout, and session restore.
- [x] Room list with DMs and groups.
- [x] DM timeline, group timeline, and text composer.
- [x] Mandatory OMEMO DM creation and text send/receive.
- [x] Mandatory OMEMO group creation and text send/receive.
- [x] Attachment send/download with encrypted media and in-app image preview
      is implemented in the Apple XMPP service for DMs and group MUCs; group
      sends remain gated on a validated MUC member recipient set plus trusted
      active OMEMO devices for every recipient. On 2026-05-10 credentialed
      `dm-attachment` and `group-attachment` live-smoke modes passed upload,
      peer download, local decrypt, MIME/image flag, and byte equality checks
      without printing decrypted content, filenames, media keys, or URLs.
      iOS and macOS timeline rows render bounded inline previews for supported
      image attachments after local decrypt.
- [x] Static Telegram sticker import and encrypted sticker sends are implemented
      as a presentation layer over encrypted attachments. The app-facing wrapper
      resolves public `t.me/addstickers/<name>` packs server-side, returns only
      regular static stickers with short-lived file tokens, and skips animated
      or video stickers with a visible unsupported count. Apple stores imported
      packs per account in a local encrypted library, renders stickers in the
      picker/timeline, and keeps sticker sends behind the same OMEMO attachment
      availability and trust gates. Credentialed sticker-specific live smoke is
      not wired in this slice.
- [x] Local encrypted media cache retention is wired for downloaded attachments
      and sticker previews. Apple stores decrypted media bytes only after local
      OMEMO media decryption, encrypts cache blobs and the cache index with a
      Keychain-held local key, and exposes Settings controls for maximum cache
      size, age, per-chat media depth, forever retention, clear-all media,
      clear-current-chat media, clear-old media, clear-all stickers, and
      individual sticker-pack removal.
- [x] iOS product-parity pass: Chats/Settings tabs, dense inbox, visible invite
      actions, account state, chat bubbles, composer, and attachment download
      affordances are wired in SwiftUI. The iOS inbox prioritizes pending
      invites, shows unread/account/push state without token values, keeps
      OMEMO lock/trust visibility in chat headers and composer blockers, and
      exposes encrypted attachment download/preview affordances.
- [x] macOS product-parity pass: multi-column workspace, room inspector, member
      management, and attachment open/share/export flow. The macOS app uses a
      three-column `NavigationSplitView`, inspector-side people/common-chat/media
      panels, directory-backed group add/remove controls, and shared-media rows
      that download encrypted attachments into the same decrypted preview sheet
      used by the timeline. The preview exposes OS Open, Share, and Export
      controls after local decrypt; live server round-trip validation remains
      tracked by the attachment validation item above.
- [x] Live-validate E2EE group send/receive with at least three accounts.
      `group-e2ee` macOS live smoke passed on 2026-05-09 with `test`, `friend`,
      and `admin` accounts.
- [x] Timeline refresh after fresh service/session restore through MAM and local
      cache. The scrubbed macOS `timeline-restart` live-smoke mode is wired: it can
      optionally send one OMEMO DM, reload MAM/cache, create a fresh service
      instance, restore the session, and require overlapping item IDs after
      restart. On 2026-05-10 the credentialed run passed with
      `mam=ok`, `cache_loaded=1`, `overlap=1`, and no missing local recipient
      key for the newly sent sender-side stanza. A full signed-app process
      quit/relaunch smoke is still tracked separately.
- [x] Cold session restore shows cached room summaries before the live server
      room-list refresh completes. The room-summary payload is an encrypted
      Application Support file; Keychain stores only its cache key.
- [x] Local unread badges and mark-read-on-open UI. Room lists cap large unread
      counts at `99+`, opening a room clears the local unread display, and
      room refreshes preserve/increment local unread state for inactive rooms
      when new incoming activity updates the preview. Outgoing previews use a
      `You:` prefix and do not increment local unread. Server-backed unread
      state and chat-marker/read-marker sync remain open.
- [x] Delivery decorations.
- [x] Typing indicators.
- [x] Message reactions. The Apple model/service/view-model boundary,
      quick-reaction menu, aggregate chips, self-highlight, mock-service
      toggling, and Martin-backed XEP-0444 send/receive/cache path are wired.
      Reaction stanzas remain XMPP metadata visible to the private server; text
      and attachment sends still fail closed on OMEMO trust/encryption gates.
      The `dm-reaction` live-smoke mode is wired for credentialed two-account
      validation, but has not been run in this slice.
- [x] Foreground room/invite/timeline refresh while the app scene is active.
- [ ] APNs-backed notifications without plaintext payloads. Apple token capture,
      XMPP push-component registration plumbing, and generic sync payload
      handling are wired. Inactive iOS/macOS push handling now syncs room state
      without marking the selected room read. Visible APNs use only `Trix` plus
      encrypted-message/unread-count wording, and older silent sync may create a
      generic local notification with the same plaintext-free wording. Per-room
      default/muted/mentions-only profiles are available in rooms, stored locally
      with encryption at rest, backed by a private XMPP PEP item, and used to
      suppress only local fallback notification presentation after sync.
      `trix-push-gateway` now includes the APNs sender plus XEP-0114
      component/store for Martin/XEP-0357 registration nodes. On 2026-05-10 the
      gateway was deployed on the VPS with deployment-local APNs token-auth
      material, bound its HTTP health endpoint to localhost only, and connected
      to ejabberd as `push.trix.selfhost.ru`. On 2026-05-18 live diagnostics
      found stored XEP-0357 registrations but no APNs delivery attempts from the
      gateway; the Apple client now forwards iOS/macOS scene active/inactive
      state to XMPP through XEP-0352 CSI so ejabberd can publish inactive-client
      pushes. Keep this open until signed-device APNs smoke confirms visible
      generic delivery with no plaintext fields.
- [x] Trix user directory search for new DM/group creation and add-member flows.
- [x] Basic XMPP vCard-backed profile view/edit surface for display name, bio,
      status, and website.
- [x] Device trust and broader device-management surfaces. Apple Settings now
      shows the current OMEMO device, published account devices discovered
      through MartinOMEMO, active/trust state, a short visual fingerprint
      challenge, hidden technical fingerprints, and a manual per-device trust
      action. It does not silently trust new devices.
- [x] Repeatable local archive/TestFlight script path for the new XMPP Apple
      app targets.

## Server

- [x] Choose final XMPP domain: `trix.selfhost.ru`.
- [x] Confirm no live Matrix users or rooms need preservation.
- [x] Add private XMPP server scaffold under `server/xmpp/`.
- [x] Start the local XMPP server.
- [x] Verify client-to-server login locally.
- [x] Verify server-to-server federation is disabled in config.
- [x] Verify port `5269` is not externally reachable in production.
- [x] Enable private MUC service for `conference.trix.selfhost.ru`.
- [x] Enforce or document members-only, non-anonymous, persistent group-room
      defaults.
- [x] Enable SQL-backed MAM for encrypted stanza replay.
- [x] Enable HTTP file sharing/upload for encrypted attachments.
- [x] Disable public registration.
- [x] Create disposable local test users.
- [x] Create the friend group accounts through an operator-controlled flow:
      `server/xmpp/scripts/operator-control.sh provision-user` reads passwords
      from local files, calls only the loopback `mod_http_api`, and prints no
      password material.
- [x] Back up server state.
- [x] Back up uploaded encrypted media or confirm media is intentionally
      disposable.
- [x] Restore backup into a fresh server instance through the
      ejabberd-native backup/restore verifier.

## Apple Login And Session

- [x] Rename service/model/view boundary from `Matrix*` to protocol-neutral
      `Trix*`. The generated Xcode project and schemes still keep
      `TrixMatrix*` compatibility names for this slice.
- [x] Keep SwiftUI views dependent on view models, not XMPP or OMEMO APIs.
- [x] Build the iOS Apple target with the first XMPP adapter slice.
- [x] Build the macOS Apple target with the first XMPP adapter slice.
- [x] Remove Matrix Rust SDK and Matrix live smoke code from the new Apple
      targets.
- [x] Add scrubbed XMPP live smoke hooks for login, roster, and plaintext-send
      blocking checks.
- [x] Persist local OMEMO registration id, identity key pair, prekeys, signed
      prekeys, session records, identities, and sender keys in Keychain.
- [x] Register MartinOMEMO with a CryptoKit AES-GCM engine.
- [x] Reuse the existing iOS app identifier, Apple team, and APNs entitlement
      environment settings.
- [x] Reuse the existing macOS app identifier, Apple team, sandbox/network/file
      access entitlements, and APNs entitlement environment settings.
- [x] Log in with a local XMPP JID and password.
- [x] Confirm auth material is not printed in app or live-smoke output paths.
- [x] Quit and relaunch the app through the Keychain-backed restore path.
- [x] Confirm the session restores without retyping the password.
- [x] Log out.
- [x] Confirm local session cleanup behavior is explicit and safe: logout removes
      the saved XMPP login from Keychain and keeps OMEMO device/trust state
      local until app Keychain data is reset.
- [x] Change own account password from Apple Settings through the invite/control
      wrapper. The app submits the current password only for Basic-auth
      validation, the wrapper checks it with ejabberd `check_password`, calls
      loopback `change_password`, rejects weak new passwords, and the client
      updates the saved Keychain session password only after success.

## Messaging

- [x] Show roster-backed DM room list after sync with cached/MAM-backed latest
      preview and activity sorting.
- [x] Open a DM through the service layer.
- [x] Create an encrypted DM through the SwiftUI Apple client flow.
- [x] Create a private encrypted MUC group through the SwiftUI Apple client flow.
- [x] Accept or decline pending MUC invites after reconnect through the Apple
      XMPP service's local invite cache and MAM resync; mediated declines are
      sent through Martin, while direct-invite decline remains local-only.
- [x] Open a group room through the service layer.
- [x] Wire DM text send through MartinOMEMO only after explicit peer-device
      trust.
- [x] Live-validate DM text send/receive between two accounts. The scrubbed
      `dm-e2ee` live-smoke mode is wired and checks peer decrypt without
      printing message body or credentials. On 2026-05-10 the credentialed
      `test` to `friend` run passed with peer decrypt confirmed.
- [x] Receive and decrypt an OMEMO DM message through the MartinOMEMO service
      path.
- [x] Receive and decrypt an OMEMO group message.
- [x] Block plaintext send in product DM/group flows.
- [x] Send a file or image attachment from the SwiftUI timeline composer in
      encrypted DMs and group MUCs. Group attachment send remains blocked unless
      the service validates the MUC member recipient set and every recipient has
      a trusted active OMEMO device.
- [x] Send a local sticker from the SwiftUI timeline composer through the same
      encrypted attachment pipeline. Sticker metadata is included inside the
      OMEMO-encrypted descriptor, while descriptor version remains `1` for older
      clients to render the item as a normal encrypted attachment.
- [x] Download encrypted DM timeline file/image attachments, decrypt locally,
      and preview supported images inline or in the full attachment preview.
- [x] Show visible encrypted-attachment download failure state and allow retry
      from the same attachment control without logging decrypted bytes or media
      keys.
- [x] Open, share, or export downloaded DM attachments through OS controls.
- [x] Show sender, timestamp, and body in the SwiftUI timeline model, with day
      separators, sender/time-window clustering, sender name on the first
      incoming group cluster, and normal encrypted/blocked/empty states.
- [x] Show sent/delivered decorations for local outgoing DM messages through
      XMPP delivery receipts.
- [x] Live-validate XMPP delivery receipt updates with both DM accounts online.
- [x] Send and receive live XMPP chat-state typing indicators for DMs.
- [x] Live-validate typing `composing` and `paused` transitions with both DM
      accounts online.
- [x] Auto-refresh the room list, invites, and selected timeline while the app
      scene is active.
- [x] Refresh the roster-backed DM room list and selected DM timeline while the
      app scene is active.
- [x] Select DM and new-group invitees from Trix directory search results
      instead of raw JID-only entry.
- [x] Select existing-group add-member users from Trix directory search results.
- [x] Hide/forget a DM locally with confirmation and accurate wording that it is
      not a global delete.
- [ ] Server-backed group leave. The timeline action surface now has a
      confirmation flow, but the checked-in action is local-only and says so
      until the Martin MUC leave path is validated.
- [x] Keep newly decrypted or locally sent DM timeline items visible after app
      restart through the local encrypted timeline cache. The cache file lives
      outside Keychain and is encrypted with a small Keychain-held cache key.
- [x] Include the sender's current OMEMO device in new DM and group sends through
      the existing MartinOMEMO recipient-set API, so future MAM archives include
      a local recipient key for sender-side restart/self-history replay.
- [ ] Backfill older sender-side OMEMO self-history from MAM after restart.
      Encrypted server archives are ciphertext-only, and old messages that were
      not encrypted for the sender's current device cannot be reconstructed
      without a reviewed recovery/key-backup path.

## E2EE

- [x] Validate that MartinOMEMO/libsignal resolves and builds for iOS and
      macOS targets.
- [x] Wire persistent local OMEMO state and module registration into the XMPP
      connection.
- [x] Spike Tigase Martin plus MartinOMEMO first, with GPL/AGPL obligations
      explicitly accepted or rejected for the non-commercial friends app. The
      current MVP decision accepts the pinned Martin/MartinOMEMO/libsignal stack
      for private non-commercial validation with source/license obligations
      tracked in `docs/xmpp-migration/license-sbom.md`.
- [x] Create or join an encrypted DM.
- [x] Send and receive an encrypted DM message.
- [x] Create or join a private members-only, non-anonymous MUC with OMEMO-gated
      product sends.
- [x] Send and receive an encrypted group message.
- [x] Confirm server MAM stores encrypted stanza content, not plaintext.
- [x] Confirm the Apple XMPP attachment path encrypts media with MartinOMEMO
      before HTTP upload. Group MUC attachment send additionally requires a
      validated recipient set and trusted active OMEMO device for every
      recipient. Scrubbed `dm-attachment` and `group-attachment` modes validate
      live server upload, peer download, decrypt, MIME, image flag, and byte
      equality; the 2026-05-10 credentialed runs passed for both DM and group.
- [ ] Add a second device and confirm visual device verification state is visible
      in a live two-device run. The Apple Settings surface is wired to the
      existing MartinOMEMO account-device discovery path and shows visual
      fingerprint challenges with raw fingerprints hidden behind a disclosure,
      but signed/second-device validation has not been run in this worker slice.
- [x] Show peer OMEMO device visual challenges and manual trust controls for DMs.
- [x] Confirm untrusted or unknown device behavior is understandable.
- [x] Confirm the app does not silently trust all devices.
- [x] Confirm the composer blocks sending when required OMEMO state is missing.
- [x] Confirm recovery or reinstall limitations are visible and documented.
      Apple Settings now states that server-side OMEMO key recovery is not wired
      for this MartinOMEMO slice, reinstall/Keychain reset creates a new OMEMO
      device, and old ciphertext not encrypted for the replacement device can
      remain unavailable.

## Control Plane

- [x] Validate ejabberd admin API as the first control-plane candidate.
- [x] Decide whether any operations still require a small Trix control-plane
      service in front of ejabberd: yes, use ejabberd `mod_http_api` only as a
      localhost backend behind an authenticated/audited Trix operator wrapper.
- [x] Create user.
- [x] App-driven invite registration flow: `server/xmpp/scripts/
      invite-registration-server.py` creates bearer-protected single-use
      operator invites, lets signed-in Apple clients issue invites after
      ejabberd `check_password` validates the current XMPP account, stores only
      invite-code hashes, redeems through the loopback ejabberd API, and the
      Apple login screen can create an account from an invite before saving the
      normal XMPP session.
- [x] App-facing Telegram sticker import wrapper:
      `server/xmpp/scripts/invite-registration-server.py` exposes
      `POST /v1/stickers/telegram/packs` and
      `POST /v1/stickers/telegram/file` for signed-in XMPP users, keeps the
      Telegram bot token server-side, signs short-lived sticker file tokens with
      deployment-local secret material, and has dry-run fake Telegram smoke
      coverage for pack resolve, file download, unsupported sticker reporting,
      auth failure, bad/expired token handling, and secret redaction.
- [x] Disable user through `operator-control.sh disable-user`, backed by
      ejabberd `ban_account` so sessions are kicked and new login is blocked
      without deleting account data.
- [x] Reset password through `operator-control.sh reset-password`, backed by
      ejabberd `change_password` with the new password read from a local file.
- [x] Re-enable a disabled user through `operator-control.sh enable-user`,
      backed by ejabberd `unban_account` without changing the account secret.
- [x] Search directory by handle/name through `operator-control.sh
      search-directory`, backed by `registered_users` plus vCard `FN` and
      `NICKNAME` lookups over the loopback API.
- [x] View and edit account profile metadata through the Apple XMPP client.
- [x] Create group through the Apple XMPP client MUC path.
- [x] Add group member through the Apple XMPP client MUC path.
- [x] Remove group member through the Apple XMPP client MUC path.
- [x] List group members through the Apple XMPP client MUC path. The Apple
      service merges live MUC occupants, affiliation results, and an encrypted
      local known-member file cache so previously seen group members remain
      visible after reconnect. Keychain stores only the cache key. New
      Apple-created private MUCs grant invited members MUC admin affiliation for
      the MVP member-management UI; older member-only rooms may still return
      forbidden for add/remove from non-admin accounts.
- [x] View server health.
- [x] View archive/upload/push health through `operator-control.sh
      archive-upload-push-health`, which reports loopback API status, backup
      archive presence, HTTP upload reachability, and push-gateway reachability
      without exposing credentials.
- [x] Keep admin credentials out of logs and repo files.

## Deferred MVP Items

- [x] Production device trust UX for the MVP: current-account device list,
      visual fingerprint challenge, active/trust labels, hidden technical
      fingerprint disclosure, and explicit per-device manual trust are wired
      through existing MartinOMEMO/store APIs. The visual challenge is a
      deterministic display transform over the MartinOMEMO identity fingerprint;
      the pinned libsignal source includes displayable/scannable fingerprint
      primitives, but no reviewed Swift SAS flow is wired. Reviewed interactive
      SAS verification and device revocation are not implemented, and the UI
      keeps those limitations visible instead of trusting devices automatically.
- [x] Account recovery/reinstall UX for the MVP: the app documents the current
      limitation in Settings and docs. Real server-side OMEMO key backup or
      recovery remains blocked until a reviewed MartinOMEMO recovery path is
      selected; no custom key recovery was added.
- [ ] Push notifications through APNs. The checked-in `trix-push-gateway`
      component is deployed behind ejabberd `mod_push`/XEP-0357 with
      deployment-local APNs signing material. The Apple app requests notification
      authorization and accepts only generic APNs alerts or plaintext-free sync
      hints. Keep this open until a signed iOS or macOS device confirms visible
      generic APNs delivery with no plaintext payload fields.
- [ ] Persistent tests around encrypted DM/group sync. `timeline-restart` now
      covers the DM restart/cache/MAM path in credentialed live smoke, but this
      still needs automated persistent coverage.
- [ ] Full signed-app quit/relaunch timeline smoke. Current `timeline-restart`
      proves a fresh `XMPPMartinService` restore in-process; it does not yet
      prove a complete OS app process quit/relaunch.
- [x] Persistent smoke coverage around directory/profile/control-plane flows:
      Apple live-smoke modes cover directory/profile, and
      `server/xmpp/scripts/operator-api-smoke.sh` now exercises provision,
      reset-password, directory search, health, disable, enable, and cleanup
      through the localhost control-plane backend.
- [x] Dry-run smoke coverage for invite creation, first redemption, and
      single-use replay rejection, including app-issued invites, through
      `server/xmpp/scripts/invite-registration-smoke.sh`. The same dry-run smoke
      now covers fake Telegram sticker import and signed file-token download.
- [x] Repeatable archive/TestFlight script path for the new XMPP `apple/` app.
- [x] Fail-closed Apple APNs registration plumbing exists for the new XMPP
      targets: platform token capture, service-bound XMPP push registration, and
      generic remote push handling with inactive generic local notifications for
      silent sync fallback.
- [x] Trix APNs gateway/push component exists as `trix-push-gateway`: it accepts
      Martin/Tigase registration, stores XEP-0357 node mappings, and calls the
      APNs sender with generic sync notification payloads.
- [x] Trix APNs gateway/push component is deployed with deployment-local
      credentials outside the repo. On 2026-05-10 `trix-push-gateway` built on
      the VPS, started healthy, exposed `127.0.0.1:8090` only, and connected to
      ejabberd as the private XEP-0114 component `push.trix.selfhost.ru`.

## Current First-Slice Status

- [x] XMPP-only product direction is documented.
- [x] Matrix data migration is explicitly out of scope because there are no live
      Matrix users.
- [x] XMPP server scaffold exists.
- [x] Production ejabberd is deployed at `trix.selfhost.ru`.
- [x] SQL-backed MAM is enabled.
- [x] Daily root-only XMPP backup timer is installed.
- [x] Apple OMEMO dependency candidate builds: Martin `3.2.4`, MartinOMEMO
      `2.2.3`, libsignal `1.0.0`.
- [x] OMEMO DM live smoke has a scrubbed `dm-e2ee` two-account runner. On
      2026-05-10 the credentialed `test` to `friend` run passed with peer
      decrypt confirmed.
- [x] OMEMO group live smoke is validated.
- [x] Protocol-neutral Apple service boundary exists.
- [x] First XMPP adapter is wired for login, restore, and roster-backed room
      list.
- [x] Persistent local OMEMO store is wired.
- [x] Product composer blocks plaintext sending while OMEMO state or peer trust
      is missing.
- [x] Manual peer-device trust UI is wired for DMs with a visual fingerprint
      challenge instead of raw fingerprint comparison as the primary action.
- [x] DM text send uses MartinOMEMO encode/write after peer trust.
- [x] Apple XMPP group create/join/invite/member operations are wired through
      Martin MUC primitives. Group text send now uses MartinOMEMO multi-recipient
      encode for known members, and live three-account send/receive/decrypt
      validation passed on 2026-05-09. Group member lists persist known members
      in an encrypted local file cache and the smoke checks owner, peer, and
      third-account visibility.
- [x] Matrix Rust SDK adapter and live smoke runner are removed from the new
      Apple target.
- [x] Apple APNs tokens are never logged by the new XMPP app path and remote
      pushes are handled as generic sync notifications only.
- [ ] APNs delivery is blocked only on signed-device smoke. ejabberd `mod_push`
      is wired to a private XEP-0114 component path, and `trix-push-gateway`
      owns APNs sender plus Martin/XEP-0357 registration mapping. On 2026-05-10
      the gateway deployed with APNs credentials and connected to ejabberd; the
      remaining proof is a signed device receiving a visible generic APNs payload
      with no plaintext message, filename, media-key, or decrypted-content fields.
- [x] Trix control-plane model is selected: for MVP closeout, checked-in
      operator scripts use loopback-only ejabberd `mod_http_api`; any non-local
      or multi-operator access still requires a small authenticated/audited Trix
      wrapper before exposure.
- [x] No custom crypto is added.

## Notes

- Apple source files, service protocols, models, and views now use
  protocol-neutral `Trix*` names. The generated project and schemes remain
  `TrixMatrix.xcodeproj`, `TrixMatrixiOS`, and `TrixMatrixMac` for command
  compatibility during this slice. Temporary `matrix-*` just aliases remain only
  for callers that have not switched command names yet.
- The XMPP Apple app has `apple/scripts/archive-testflight.sh` for iOS/macOS
  archive, export, and upload paths, with unsigned archive mode for machines
  without signing material.
- Live smoke must print only scrubbed status lines. It must not print passwords,
  auth tokens, OMEMO secrets, APNs tokens, decrypted message bodies, or decrypted
  attachment contents.
