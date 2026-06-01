# XMPP Protocol Feature Map

This map ties intended Trix product behavior to the XMPP primitive, Trix
control-plane owner, Apple implementation surface, and verification path. It is
not a claim that every XEP is production-ready in the chosen Apple stack. OMEMO
group live validation, encrypted attachments, and signed macOS APNs delivery
have passed the current MVP evidence gates. Message reactions are implemented
but keep a focused live follow-up. The remaining launch-level gates are
encrypted calls, signed two-device trust proof, and reviewed OMEMO
recovery/backfill.

| Product feature | XMPP or control-plane primitive | Apple implementation surface | Verification |
|---|---|---|---|
| Private single-server deployment, no federation | ejabberd or Prosody with server-to-server disabled; no public `5269`; no s2s DNS records | No federation UI; fixed Trix account domain from config | Server config check, external `5222` positive check, external `5269` negative check |
| Operator account lifecycle | ejabberd admin API or Trix control-plane wrapper; public registration disabled; single-use invite issue/redemption and self-service password change allowed | Settings invite-code issuing, invite-code account creation, password change, login, disabled-account state | Create invite from app, redeem once, change password from Settings, log in both platforms, disable user, verify new sessions fail |
| Login, logout, restore | SASL/TLS, resource binding, XEP-0198 stream management, secure local session store | `TrixSessionStore`, `TrixAuthService`, Keychain-backed iOS/macOS state | Fresh login, quit/relaunch restore, logout cleanup, secret-redacted logs |
| Mandatory E2EE | OMEMO XEP-0384, PEP/PubSub device bundles, fail-closed send policy | `TrixDeviceVerificationService` gate before create/send; visible blocked state | Two-account encrypted DM, three-account encrypted group, server archive plaintext check |
| DM creation and duplicate prevention | Bare-JID messaging plus Trix DM registry or deterministic merge rule; MAM and carbons for continuity | Directory result to DM in the new-room flow | Create the same pair twice, verify one conversation or documented merge behavior |
| Private groups | Members-only, non-anonymous MUC rooms plus OMEMO group support after spike | Shared group create/invite view model; iOS participants sheet; macOS inspector | Three-account private group, invite/accept/decline, OMEMO send/receive, restart reload |
| Group membership management | MUC affiliations/roles plus Trix control-plane membership policy | Shared membership service; iOS participants UI; macOS inspector add/remove | Add/remove from both platforms, refresh member list, show permission failures |
| Timeline and restart history | MAM XEP-0313, stable stanza IDs, local cache | `TrixSyncService`, `TrixRoomService`, timeline view models | Send while one client is offline, relaunch, backfill without duplicates |
| Multi-device delivery | XMPP resources, Message Carbons XEP-0280, OMEMO device lists/bundles | Device/encryption settings and blocked send states | Same account on iOS and macOS receives inbound/outbound continuity |
| Device trust | Selected OMEMO library trust/fingerprint model; Trix-visible summaries | Settings device list, fingerprint/trust state, reset/import if supported | Add second device, verify/trust flow, no key material in logs |
| Directory/search | Trix control-plane directory as source of truth; XEP-0055 only as optional server support | Search picker for DM/group/add-member; shared directory view model | Search users, create DM, select group invitees, add group member |
| Profile metadata | Trix-owned profile store; optional vCard4/user avatar mapping | Profile settings on iOS/macOS; participant metadata in rows | Edit profile metadata, search/result rows update, field ownership documented |
| Text send/receive | XMPP message stanzas wrapped by OMEMO | Timeline composer, pending/sent/failed states | DM/group text round trips, archive contains no plaintext body |
| Attachments and media | HTTP Upload XEP-0363 plus encrypted references/media after Apple stack spike | iOS file/photo picker; macOS file importer; preview/open/share | Image and generic file round trip, metadata exposure documented, no decrypted bytes in logs |
| Reactions | XEP-0444 reactions metadata; message content stays inside OMEMO messages | iOS long-press actions; macOS context menu; aggregate chips | Model/service/view-model/UI and Martin-backed send/receive/cache path are wired; `dm-reaction` remains the focused live follow-up |
| Reply/quote preview | XEP-0461 reply metadata; reply target ids/JIDs are server-visible while quote preview text stays encrypted/local | Timeline item reply metadata, composer reply banner, compact quote preview | `dm-reply` smoke exercises the shared request API and Martin metadata path; live proof still needs DM reply delivery plus MAM/restart reload |
| Edit/retract | XEP-0308 last-message correction and XEP-0424 retraction; target ids and event timing are server-visible, replacement text stays OMEMO-encrypted | Own-message edit/delete actions, edited marker, tombstone state | `dm-edit-retract` smoke exercises edit/retract APIs; live proof still needs peer delivery plus reload, and group coverage needs stable group target ids |
| Mentions | XEP-0372 references; mention target JIDs/`xmpp:` URIs and begin/end offsets are server-visible, mention context stays encrypted | Mention picker from known room members, timeline highlighting, generic local mention notification after decrypt | `group-mention` smoke exercises mention metadata; live proof must validate known-member-only insertion, stable group target ids, and no plaintext APNs context |
| Threaded replies | XEP-0201 thread elements; thread ids and parent relationships are server-visible, message bodies/snippets stay encrypted | Group "reply in thread" action, thread summary/detail or filtered view | `group-thread` smoke exercises thread metadata; live proof still needs peer/third delivery, MAM/restart reload, and stable group target ids |
| Delivery/read/unread | XEP-0184 receipts, XEP-0333 chat markers, local unread model, and a private Trix read cursor for same-account convergence when marker archive/carbon delivery is unreliable | Room-list badges, timeline outgoing decorations, explicit mark-read behavior | Delivery receipt smoke exists; `read-markers` live smoke validates XEP-0333 send plus same-account cursor convergence; peer-visible marker observation remains best effort |
| Typing/composing | Chat State Notifications XEP-0085 | Debounced composer updates, compact incoming indicator | Typing in encrypted DM/group sends composing/paused and clears on leave |
| Notifications | XEP-0357 plus Trix APNs gateway; visible text stays generic and local | APNs registration, push handling, per-room local presentation filters, badge sync | Signed macOS APNs smoke passed with generic visible text; XMPP component publish now produces silent sync wakes; keep iOS physical proof as a platform-specific follow-up if required |
| Chat lifecycle | MUC leave/destroy where allowed, local hide/forget, XEP-0424 for message retraction only | Leave group, hide/remove DM with accurate wording | Leave from both platforms, wording does not promise impossible remote deletion |
| Diagnostics/status | Trix diagnostics/control plane plus XMPP connection/archive/push/OMEMO state | iOS status view, macOS advanced/status panels, redacted diagnostic export | Offline/server failure states, secret-redaction checks during login/send/push |
| Centralized server management | ejabberd admin API or Trix wrapper for accounts, groups, health, backups | Operator script or future operator UI | Create/disable users, inspect groups, verify backup status, no committed secrets |
| Bot/runtime parity | Bot as ordinary XMPP account using the same OMEMO policy | Separate bot service/CLI, not SwiftUI | Bot logs in, joins encrypted DM/group if supported, no bot-only plaintext path |
| Release parity | XMPP iOS/macOS targets, existing signing/APNs assumptions preserved | Current `apple/` archive/TestFlight script | iOS/macOS debug builds, archive/TestFlight path, fresh install login smoke |

## Protocol References

- OMEMO: XEP-0384.
- Multi-User Chat: XEP-0045.
- Message Archive Management: XEP-0313.
- Stream Management: XEP-0198.
- Message Carbons: XEP-0280.
- HTTP File Upload: XEP-0363.
- Push Notifications: XEP-0357.
- Message Reactions: XEP-0444.
- Message Replies: XEP-0461.
- Last Message Correction: XEP-0308.
- Message Retraction: XEP-0424.
- References/Mentions: XEP-0372.
- Message Threads: XEP-0201.
- Chat Markers: XEP-0333.
