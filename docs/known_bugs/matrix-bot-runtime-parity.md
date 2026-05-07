# Matrix: Bot Runtime Parity

Status: Open.

## Summary

Legacy Trix has a bot library and `trix-botd` daemon that can initialize,
start/stop, list chats, inspect timelines, send text, send files, download
files, and maintain a websocket/polling loop. Matrix Apple has no replacement
bot runtime.

## Legacy behavior to match

- Bot sessions can authenticate and publish key material.
- Bots can list chats and read timelines.
- Bots can send text and file messages.
- Bots can download files.
- Bot daemon has lifecycle commands.

Relevant legacy entry points:

- `crates/trix-bot/src/bot.rs`
- `apps/trix-botd/src/main.rs`
- `docs/bot-harness.md`

## Current Matrix state

- No Matrix bot crate, daemon, or documented bot workflow was found.
- Matrix SDK should own protocol/E2EE behavior if bot support is rebuilt.

## Required implementation

- Decide whether bot parity is required for the Matrix MVP or can remain out of
  scope.
- If required, define a Matrix-native bot architecture using Matrix SDK or a
  supported Matrix client library.
- Cover login/session storage, encrypted room participation, text send, media
  send/download, and safe logging.
- Document unsupported legacy bot capabilities.

## Boundaries

- Do not implement custom crypto or custom Matrix protocol handling.
- Do not copy legacy MLS bot internals into Matrix.
- Do not log access tokens, passwords, recovery keys, or decrypted bodies.

## Acceptance criteria

- Either bot runtime is explicitly documented as out of MVP scope, or a
  Matrix-native bot can log in, join/list rooms, send text, send media, and
  download media in encrypted rooms.
- Docs explain how to run it with disposable credentials.
- No secrets are committed or printed.

## Verification plan

- If implementation is added, run a live encrypted DM and group bot smoke.
- Confirm safe logs.
- Run relevant builds/tests and `git diff --check`.
