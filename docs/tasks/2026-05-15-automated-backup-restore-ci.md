# Task: Automated Backup Restore Verification

You are the next coding agent working in the Trix repo. Wire
`server/xmpp/scripts/restore-verify.sh` into regular automation so restore
validity is checked continuously, not only by hand.

## Current Context

Relevant files:

- `docs/security.md`
- `docs/mvp-checklist.md`
- `server/xmpp/README.md`
- `server/xmpp/scripts/backup.sh`
- `server/xmpp/scripts/restore-verify.sh`
- `server/xmpp/scripts/local-smoke.sh`
- `server/xmpp/docker-compose.yml`
- `server/xmpp/ejabberd.yml`

`restore-verify.sh` creates a disposable ejabberd instance, registers a
generated account, writes an upload sentinel, performs ejabberd-native Mnesia
backup/restore plus upload archive restore, then confirms the restored account
can authenticate over XMPP. There is no checked-in `.github` workflow in this
worktree.

## Goal

Run restore verification automatically on a schedule and on demand, with
secret-safe output.

## Non-Goals

- Do not use production backups in public CI.
- Do not require APNs, XMPP passwords, real TLS private keys, or deployment
  secrets in CI.
- Do not replace the production root-only backup timer.
- Do not rely on tar-only volume restore as proof of account-state restore.

## Implementation Plan

1. Add a CI workflow if this repo uses GitHub Actions, or a local CI script if
   this checkout intentionally avoids `.github`:
   - `workflow_dispatch`;
   - scheduled run, for example daily or weekly;
   - PR/push trigger for changes under `server/xmpp/**`.
2. Install or select a container runtime:
   - prefer Docker on hosted Linux;
   - allow `TRIX_XMPP_CONTAINER_RUNTIME=docker`;
   - document Podman for local runs.
3. Run:
   - `bash -n server/xmpp/scripts/*.sh`;
   - `server/xmpp/scripts/restore-verify.sh`;
   - optionally `server/xmpp/scripts/local-smoke.sh` if runtime cost is
     acceptable.
4. Keep logs redacted:
   - do not print generated disposable passwords;
   - let `restore-verify.sh` keep its existing redaction behavior;
   - archive only non-secret logs if artifacts are needed.
5. Add a CI status marker for operator diagnostics if useful:
   - for local/deploy automation, write latest successful restore timestamp to a
     root-only or operator-readable status file;
   - do not write CI tokens or secrets into the repo.
6. Update docs:
   - `server/xmpp/README.md` with CI/local commands;
   - `docs/security.md` backup risk section with the automated gate.

## Acceptance Criteria

- A scheduled/manual automation runs `restore-verify.sh`.
- The automation requires no production secrets.
- CI failure clearly reports restore failure without exposing generated
  credentials.
- Docs explain how to run the same gate locally.
- `docs/security.md` no longer implies restore verification is purely manual.

## Verification Commands

```bash
bash -n server/xmpp/scripts/*.sh
server/xmpp/scripts/restore-verify.sh
git diff --check
```

If Docker/Podman is unavailable in the current environment, report the skip
with the exact missing runtime and still verify shell syntax plus workflow YAML.
