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
- [x] Chat list pin/mute/mark-read-unread actions. Pinned rooms sort above the
      rest with recent-activity ordering inside each section; iOS rows expose
      swipe actions and macOS rows a context menu for pin/unpin, mute/unmute
      (switching the existing per-room notification profile), and mark
      read/unread. Mark-as-read also sends the existing displayed marker,
      opening a room clears a manual unread mark, and marked-unread state
      survives room-list reloads. Pins and marked-unread sets persist per
      account in the encrypted `TrixRoomListPreferenceStore` with its key in
      Keychain. Unit-tested on 2026-06-10 (store roundtrip without plaintext
      at rest, pinned-first sorting, marked-unread reload survival, persisted
      pin toggles); no live smoke. Follow-up: pinned/marked-unread state is
      local-only in this slice and still needs PEP sync across devices.
- [x] Persistent per-room composer drafts. Draft text plus reply/thread
      context is saved per account and room into the encrypted
      `TrixDraftStore` (AES-GCM with the account id bound as AAD,
      Keychain-held key), debounced while typing, restored when reopening the
      room (reply/thread context only while the target message still
      resolves), cleared after a successful send, and shown in the chat list
      as an accented `Draft:` preview replacing the last-message preview for
      unselected rooms. Cancelling a reply/thread context keeps the typed
      text and only drops the context; cancelling an edit restores the
      pre-edit draft. Draft text is never logged. Unit-tested on 2026-06-10
      (roundtrip with context targets, no plaintext at rest, empty-draft
      cleanup, per-room clear); no live smoke.
- [x] "New Messages" unread divider with unread-anchored initial scroll. On
      room entry the first unread incoming message is computed from
      read-marker state with an unread-count fallback and frozen for the
      visit; the timeline renders a labeled divider above it and the initial
      scroll anchors to the divider instead of the bottom when unread items
      exist. Auto-scroll to the bottom still happens only for newly appended
      messages, not on initial load. Unit-tested on 2026-06-10 (eight
      marker/fallback anchor scenarios); no live smoke. Follow-up: a visible
      read-receipts UI on top of existing delivery decorations remains open.
- [x] macOS quick switcher, composer hotkeys, and in-app Dock badge. Cmd+K
      opens a keyboard-driven fuzzy switcher over rooms with a directory
      people fallback for new DMs (Enter opens, Esc closes), and Cmd+Shift+U
      jumps to the next unread room. In the composer, Up arrow on an empty
      draft starts editing the last own message and Esc cancels the active
      edit/reply/thread context. The Dock badge now tracks in-app unread
      state (server unread plus manually marked-unread rooms), reconciles
      with push-provided badge values, and resets on sign-out. Unit-tested on
      2026-06-10 (fuzzy matcher tiers/diacritics/multi-token rules,
      badge-count composition); no live smoke. Follow-up: runtime smoke of
      the macOS `onKeyPress` composer shortcuts on a live build.
- [x] Offline send outbox for text messages. Retryable connection-level send
      failures (connection failed, stream timeout/not-found, URL/POSIX
      network errors) enqueue the message into the encrypted per-account
      `TrixOutboxStore` (AES-GCM with the account id bound as AAD,
      Keychain-held key) and show a local `.pending` echo; fatal failures
      (validation, OMEMO trust, `undefined_condition`) keep the existing
      fail-closed inline error and are never queued. The queue drains
      sequentially oldest-first after login, session restore, and reconnect,
      reloading the queue per iteration so mid-drain deletes/retries are
      honored, stopping on connection errors so a stuck older message is
      never overtaken, replacing echoes with the real sent items, and marking
      messages `.failed` with visible Retry/Delete row actions after the
      attempt budget is exhausted. Retries reuse the queued message id as the
      stanza/origin id so XEP-0359-aware recipients can dedupe an ambiguous
      first attempt. Queued unsent messages are cleared on explicit sign-out.
      OMEMO encryption still happens only at actual send time in the existing
      service path; queued bodies are stored encrypted at rest and never
      logged. Unit-tested on 2026-06-10 (store roundtrip, retryable-error
      classification, fail-then-succeed drain, attempt-budget exhaustion,
      fatal-error non-queueing, retry/delete flows, stable id across retries,
      encrypted-at-rest raw-file check, oldest-first ordering across a
      partial failure); no live smoke.
- [x] Full-screen media gallery for room images. Tapping a previewable image
      or sticker in the timeline, or a shared-media row in the macOS
      inspector, opens a gallery over the room's media (timestamp-ordered,
      retracted items excluded) with paging plus pinch/double-tap zoom on
      iOS, chevron and arrow-key navigation on macOS, and share/save
      controls, all backed by the existing encrypted attachment
      download/cache path (`TrixRoomMediaCollector`,
      `TrixMediaGalleryView`). Unit-tested on 2026-06-10 (media filtering,
      ordering, gallery membership/index); no live smoke. Follow-up:
      animated GIFs currently render their first frame in the gallery;
      animated playback remains open.
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
- [x] APNs-backed notifications without plaintext payloads. Apple token capture,
      XMPP push-component registration plumbing, and generic sync payload
      handling are wired. Inactive iOS/macOS push handling now syncs room state
      without marking the selected room read. Visible APNs use only `Trix` plus
      encrypted-message/unread-count wording, and older silent sync may create a
      generic local notification with the same plaintext-free wording. Foreground
      APNs/local presentation is suppressed for the open room but may show the
      same generic local alert for newly unread unselected rooms. Per-room
      default/muted/mentions-only profiles are available in rooms, stored locally
      with encryption at rest, backed by a private XMPP PEP item, and used to
      suppress only local fallback notification presentation after sync.
      `trix-push-gateway` now includes the APNs sender plus XEP-0114
      component/store for Martin/XEP-0357 registration nodes. On 2026-05-10 the
      gateway was deployed on the VPS with deployment-local APNs token-auth
      material, bound its HTTP health endpoint to localhost only, and connected
      to ejabberd as `push.trix.selfhost.ru`. On 2026-05-18 live diagnostics
      found stored XEP-0357 registrations but no APNs delivery attempts from the
      gateway; the Apple client now keeps XMPP CSI push-eligible instead of
      advertising foreground activity as a global push suppressor, and
      `mod_client_state` queueing is disabled so live chat state/presence is not
      delayed by that push signal. On 2026-05-20 signed macOS APNs smoke passed:
      `trix-push-gateway`
      returned `delivered=true` and HTTP 200 for a generic sync wake, and QA
      confirmed the visible macOS notification showed title `Trix`, body
      `New encrypted message`, timestamp-only extra text, and no plaintext
      message, filename, attachment metadata, media key, token, credential, or
      decrypted-content fields. On 2026-06-01 the live VPS enabled
      `mod_push_keepalive` plus explicit stream-management ACK/resume timeouts
      so disconnected push-enabled sessions are kept eligible for XEP-0357
      wakeups. For the testing phase, `mod_push_keepalive.resume_timeout` is
      `720 hours` (30 days) so a signed device can remain push-resumable across
      multi-day feature gaps; post-restart component publish smoke updated the
      gateway store with APNs delivery success and no failures. After real
      message sends still
      produced no gateway publish attempts, live ejabberd was switched to
      `mod_push.notify_on: all` so encrypted or metadata-only XMPP stanzas can
      wake registered clients. The gateway now sends those XMPP component
      publishes as silent APNs background wakes, while visible notification text
      stays local and generic after sync. The gateway also rate-limits XMPP sync
      wakes per registration node so repeated generic publishes do not churn
      Apple devices.
- [ ] Encrypted calls. The first checked-in slice adds the LiveKit/coturn media
      deployment profile, `trix-call-control`, Apple call descriptors,
      `TrixCallControlService`, `TrixMediaCallService`, LiveKit Swift dependency,
      iOS CallKit/PushKit entrypoint, and an OMEMO descriptor service for invite,
      answer, end, voice-room state, and key rotation events. Descriptor sends
      fail closed on the same DM trust and MUC recipient-set gates as encrypted
      chat sends. PushKit token registration is separate from regular APNs sync
      registration through the `apns-voip-sandbox`/`apns-voip-production`
      providers, and the push gateway exposes an internal call-push endpoint
      that sends only an opaque `call_id` plus optional account routing through
      the distinct VoIP APNs topic. The shared Apple UI now exposes a DM video
      button, incoming accept/decline/end controls, and a group voice-room bar
      with join/leave plus active participants; group rooms do not ring members.
      On 2026-05-19 the live VPS nginx route was wired for the app-facing
      call-control endpoints while keeping raw `8092` externally closed. A
      follow-up client pass on 2026-05-19 maps call-control `401` responses to
      credential errors instead of the generic unavailable banner, passes TURN
      REST credentials into LiveKit ICE servers, keeps macOS camera/microphone
      privacy strings in the generated app metadata, refreshes incoming call
      descriptors for unselected rooms during foreground/push refresh, and
      shares group voice media keys only inside OMEMO-encrypted voice-room-state
      descriptors. The same follow-up removes the old generic
      `Encrypted calls are not available yet` client error from app sources so
      the next failed smoke reports auth, network, HTTP status, descriptor, or
      response-shape blockers directly. A live group voice retry then exposed a
      call-control `502`: on 2026-05-19 the VPS ejabberd config was updated to
      enable `mod_muc_admin`, and `trix-call-control` was updated for the
      ejabberd 26.4 `get_room_affiliations` API shape (`room` plus `service`,
      not the older `name` key). The rebuilt VPS call-control service reports
      health `200`; externally, valid unauthenticated call payloads return
      `401` JSON responses on all five app-facing routes, and raw `8092`,
      `8091`, `5280`, and `5269` remain closed or filtered. A later 2026-05-19
      macOS retry reached the LiveKit layer and initially failed as
      `Encrypted media connection failed`; sanitized LiveKit logs showed the
      participant session start and then close before RTC connection. The
      follow-up fix added the macOS incoming-network sandbox entitlement needed
      by WebRTC media sockets. A signed Debug macOS group voice smoke then
      connected to the LiveKit room, selected UDP ICE, and published the local
      microphone track with LiveKit `GCM` encryption. The Apple media adapter
      now preflights microphone/camera access before `Room.connect` and reports
      permission or local device-start failures separately from LiveKit
      connection failures. A same-account iOS plus macOS group voice retry later
      connected only one audible participant: sanitized LiveKit logs showed both
      clients using the same participant identity and the earlier iOS session
      closing with `DUPLICATE_IDENTITY`. On 2026-05-19 Apple started sending the
      non-secret XMPP session device id in call-control create/join payloads, and
      `trix-call-control` started minting LiveKit tokens with a device-scoped
      participant identity while keeping auth and membership checks on the bare
      JID. The updated call-control service was deployed on the VPS; external
      valid unauthenticated payloads still return `401` and raw `8092` still
      times out from outside the host. The item remains open until
      signed-device smoke proves DM video on two signed devices with incoming
      CallKit/PushKit, answer, bidirectional
      audio/video, and reconnect; group voice with three accounts first and then
      ten authenticated participants; a forced TURN relay-only media path; and a
      log audit showing no LiveKit tokens, TURN credentials, media keys, XMPP
      passwords, APNs tokens, OMEMO secrets, or decrypted content in app,
      call-control, push-gateway, LiveKit/coturn, proxy, or push logs. Track the
      exact smoke plan in
      `docs/tasks/2026-05-19-encrypted-call-smoke-tests.md`.
- [x] Trix user directory search for new DM/group creation and add-member flows.
- [x] Basic XMPP vCard-backed profile view/edit surface for display name, bio,
      status, website, and cropped avatar PHOTO updates.
- [x] Direct chat and participant profile surfaces show current online presence
      when available, otherwise a compact XMPP last-activity value such as
      `Last seen: 1h ago`.
- [x] Device trust and broader device-management surfaces. Apple Settings now
      shows the current OMEMO device, published account devices discovered
      through MartinOMEMO, active/trust state, a short visual fingerprint
      challenge, hidden technical fingerprints, and a manual per-device trust
      action. It does not silently trust new devices.
- [x] Device Passport deploy slice. `apps/trix-device-passport` adds
      SQLite-backed current-device state, approval requests, trust generations,
      directory claims, notice dismissals, operator reset, and scrubbed audit
      records. Apple syncs the current device, creates approval requests, shows
      pending approvals and dismissable normal/reset notices, keeps pending
      devices read-only, and blocks product composer sends until passport sync
      reports an approved/reset-root state. Approved devices emit
      OMEMO-encrypted Device Passport approval descriptors, and directory
      claims still require that OMEMO-backed provenance before auto-trust;
      server-only claims become visible pending notices.
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
- [x] Server-backed group leave. The Apple timeline now calls the Trix
      control-plane `POST /v1/groups/leave` path before local `mucModule.leave`;
      the wrapper validates the signed-in account, checks MUC affiliation, and
      removes non-owner members by setting server affiliation to `none`. Local
      hiding happens only after that server-backed path succeeds, and selected
      room state is cleared after leave. Dry-run wrapper smoke plus focused
      Apple tests/builds passed on 2026-05-20. A hosted three-account
      `group-leave` smoke passed again on 2026-05-21 after the wrapper route
      and member refresh fixes: the peer left and no longer saw the room, owner
      and third retained room visibility, owner and third each retained two live
      members, send-after-leave was blocked, and the final smoke status was
      `group-leave ok leaver_removed=true remaining_members=2`.
- [x] Keep newly decrypted or locally sent DM timeline items visible after app
      restart through the local encrypted timeline cache. The cache file lives
      outside Keychain and is encrypted with a small Keychain-held cache key.
- [x] DM MAM reload scans past OMEMO transport-only/session-healing stanzas and
      read-marker noise until it reaches useful OMEMO payload events or the
      configured archive scan limit, so multi-device timelines do not depend on
      whichever device still has local cache.
- [x] Include the current account bare JID alongside peer/group recipients for
      new DM and group sends, so MartinOMEMO fanout covers the sender's own
      published devices as well as addressed recipients. Plaintext fallback
      remains blocked.
- [x] Backfill older DM and group self-history on demand when MAM returns
      ciphertext that lacks a local recipient key: the new client sends an
      OMEMO-encrypted timeline-backfill request for candidate stanza/message ids,
      and an updated client that can decrypt the original item replies with an
      OMEMO-encrypted timeline-backfill response descriptor. Response payloads
      reconstruct the original timeline item instead of displaying service JSON
      in chat.
- [x] Send group backfill request/response descriptors only after the joined MUC
      path can derive a validated member recipient set with trusted active OMEMO
      devices; plaintext group repair remains blocked.
- [ ] Run `apple/scripts/run-persistent-sync-gate.sh` with disposable live
      credentials after updating clients; the wrapper now includes the
      credentialed `dm-backfill-repair` smoke. That mode must create a fresh
      same-account OMEMO device after an older encrypted DM exists, observe a
      MAM sender stanza missing the fresh local recipient key, and then receive
      the same item through encrypted timeline-backfill repair without printing
      message bodies.

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
      fingerprint challenges with raw fingerprints hidden behind a disclosure.
      The scrubbed `second-device-fingerprint` smoke mode now proves distinct
      OMEMO local device IDs, fingerprint presence, and no silent trust in an
      isolated local-profile run, but credentialed signed-device validation is
      still pending in this worker slice.
- [x] Add own-device revocation for non-current account devices. Apple Settings
      now exposes a destructive confirmation flow that revokes the selected own
      device through MartinOMEMO's reviewed `removeDevices(withIds:)` path,
      refreshes published account-device state, and keeps clear wording that
      old ciphertext already delivered to the revoked device cannot be removed.
      The scrubbed `own-device-revocation` smoke mode validates the
      publish/remove/refresh behavior without printing secrets.
- [x] Show peer OMEMO device visual challenges and manual trust controls for DMs.
- [x] Confirm untrusted or unknown device behavior is understandable.
- [x] Confirm the app does not silently trust all devices.
- [x] Confirm the composer blocks sending when required OMEMO state is missing.
- [x] Confirm Device Passport server state cannot silently expand OMEMO fanout.
      The checked-in claim processor rejects server-only claims, requires an
      OMEMO-backed approval descriptor tied to the approving device id,
      confirms the approver fingerprint belongs to an already trusted local
      identity, refreshes MartinOMEMO identity state, and compares the refreshed
      target fingerprint hash before calling the reviewed trust API.
      First-contact recipients remain pending instead of silently trusting a
      new device.
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
- [x] First native admin-app slice exists: `apps/trix-admin-api` provides a
      loopback bearer-auth backend for the macOS `TrixAdminMac` target. It wraps
      user operations, push test requests, media storage status, metrics/log
      summaries, secret-safe audit events, and feature-flag storage without
      exposing raw ejabberd `5280`.
- [x] Shared Apple feature-flag evaluator exists in
      `apple/Sources/SharedFeatureFlags`, and the operator workflow is
      documented in `docs/feature-flags.md`.
- [x] Keep admin credentials out of logs and repo files.
- [x] Device Passport control-plane state exists as a separate Rust service from
      `trix-admin-api` and the Python invite wrapper. It authenticates app
      routes with the signed-in XMPP account, keeps operator reset behind a
      separate bearer token, stores only fingerprint hashes and labels, rejects
      weak placeholder operator tokens, and keeps its Compose profile
      loopback-published by default.
- [x] Device Passport service is deployed on `trix.selfhost.ru`. On 2026-06-03
      `trix-device-passport` built from `/opt/trix-build`, started through the
      `device-passport` Compose profile, exposed only `127.0.0.1:8094`, and
      returned `status:ok` on the loopback health check. nginx proxies the
      app-facing `/v1/device-passport/*` routes over HTTPS, leaves
      `/v1/operator/device-passport/*` unpublished, and a disposable XMPP
      account smoke proved authenticated current-device upsert plus state sync
      before deleting the smoke account.

## Deferred MVP Items

- [x] Production device trust UX for the MVP: current-account device list,
      visual fingerprint challenge, active/trust labels, hidden technical
      fingerprint disclosure, and explicit per-device manual trust are wired
      through existing MartinOMEMO/store APIs. The visual challenge is a
      deterministic display transform over the MartinOMEMO identity fingerprint;
      the pinned libsignal source includes displayable/scannable fingerprint
      primitives, but no reviewed Swift SAS flow is wired. Reviewed interactive
      SAS verification and QR/cross-signing flows are still not implemented.
      Own-device revocation for non-current devices is implemented through the
      reviewed MartinOMEMO publish/remove API path, and the UI keeps remaining
      trust limitations visible instead of trusting devices automatically.
- [x] Account recovery/reinstall UX for the MVP: the app documents the current
      limitation in Settings and docs. Real server-side OMEMO key backup or
      recovery remains blocked until a reviewed MartinOMEMO recovery path is
      selected; no custom key recovery was added. Decision record:
      `docs/tasks/2026-05-20-reviewed-omemo-recovery-decision.md`.
- [x] Push notifications through APNs. The checked-in `trix-push-gateway`
      component is deployed behind ejabberd `mod_push`/XEP-0357 with
      deployment-local APNs signing material. The Apple app requests notification
      authorization and accepts only generic APNs alerts or plaintext-free sync
      hints. Foreground handling now filters presentation locally, allowing
      generic local alerts for newly unread unselected rooms while suppressing
      the open room. On 2026-05-20 signed macOS APNs smoke passed with provider
      response `delivered=true` and QA-visible notification text limited to
      `Trix`, `New encrypted message`, and timestamp-only system text.
- [x] Persistent tests around encrypted DM/group sync. On 2026-05-20 the signed
      macOS persistent gate passed with scrubbed output: DM restart overlap was
      nonzero, encrypted group MUC restart overlap was nonzero, and no
      credentials or decrypted message bodies were printed.
- [x] Full signed-app quit/relaunch timeline smoke. On 2026-05-20 the signed
      macOS persistent gate ran `timeline-relaunch-seed` and
      `timeline-relaunch-verify` in separate processes, restored from the
      smoke Keychain session, found nonzero overlap, and cleaned up the smoke
      marker/session state.
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
      silent sync fallback plus foreground generic local notifications for
      newly unread unselected rooms.
- [x] Trix APNs gateway/push component exists as `trix-push-gateway`: it accepts
      Martin/Tigase registration, stores XEP-0357 node mappings, stores separate
      VoIP PushKit registrations under `trix-voip/`, and calls the APNs sender
      with silent sync wake payloads for XEP-0357 component publishes, generic
      sync notification payloads for the internal HTTP notification endpoint, or
      opaque call-push payloads.
- [x] Trix APNs gateway/push component is deployed with deployment-local
      credentials outside the repo. On 2026-05-10 `trix-push-gateway` built on
      the VPS, started healthy, exposed `127.0.0.1:8090` only, and connected to
      ejabberd as the private XEP-0114 component `push.trix.selfhost.ru`.
- [ ] Signed Device Passport smoke. Still needs same-account two-device approval
      on signed profiles, a third account with prior trust auto-applying the
      OMEMO-backed claim, a no-prior-trust account showing only a pending
      notice, and an operator reset path with strong notice plus scrubbed logs.
      The Apple `device-passport` live-smoke mode is wired for the same-account
      approval, no-silent-trust, prior-trust auto-apply, and no-prior pending
      notice checks, but still requires disposable live credentials and a signed
      app run before this item can close. Local deploy readiness is covered by
      `server/xmpp/scripts/device-passport-smoke.sh`, `cargo test -p
      trix-device-passport`, and the Apple Device Passport/verification tests;
      the server smoke also checks high-severity operator reset notice state plus
      scrubbed SQLite audit rows and service logs. The remaining item is signed
      live-device evidence.

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
- [x] APNs delivery is no longer blocked on signed-device smoke. ejabberd `mod_push`
      is wired to a private XEP-0114 component path, and `trix-push-gateway`
      owns APNs sender plus Martin/XEP-0357 registration mapping. On 2026-05-10
      the gateway deployed with APNs credentials and connected to ejabberd.
      On 2026-05-20 the push crates (`trix-push`, `trix-push-gateway`) passed
      targeted `cargo check` and `cargo test`, and the gateway README now
      documents private deployment prerequisites, bring-up sequencing, and open
      operational risks for CTO/TPM review. Later on 2026-05-20 a signed macOS
      APNs token handoff produced a generic sync wake accepted by APNs through
      `trix-push-gateway` with `delivered=true` and HTTP 200; QA then confirmed
      the visible notification remained generic and plaintext-free. The Apple
      client now keeps the XMPP session push-eligible in foreground and handles
      open-room suppression locally rather than using app-wide active state as a
      push suppressor.
- [x] Trix control-plane model is selected: for MVP closeout, checked-in
      operator scripts use loopback-only ejabberd `mod_http_api`, and the first
      native admin-app backend is a loopback bearer-auth wrapper. Any public or
      multi-operator admin exposure still requires a separate reviewed access
      path before exposure.
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
- The 2026-06-10 client QoL batch (persistent drafts, chat-list
  pin/mute/read actions, unread divider, macOS quick switcher/hotkeys/Dock
  badge, offline outbox, media gallery) was verified with `TrixMatrixMac` and
  `TrixMatrixiOS` debug builds plus the macOS unit suite: 165 tests, 0
  failures. No live or credentialed XMPP smoke was run for these items.
- A same-day independent review of that batch produced fixes that are now in:
  stable origin-id across outbox retries, draft survival on reply/thread
  cancel, outbox cleared on explicit sign-out, an LRU cap (32 entries) on
  resident inline attachment previews, per-iteration outbox queue reloads,
  `undefined_condition` reclassified as fatal, account-id AAD binding for the
  draft and outbox stores, and a main-actor hop instead of
  `MainActor.assumeIsolated` in the Dock badge sink. Verified with both debug
  builds and the macOS unit suite (168 tests, 0 failures); still no live
  smoke.
