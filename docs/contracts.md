# Contract Gates

This repo treats the following as release-blocking contracts. If one drifts, `make contract-check` must fail.

## Single Entrypoint

```bash
make contract-check
```

`make check` now runs `make contract-check` before `cargo check --workspace`.

## Contract List

### 1. FFI surface stays executable

- Enforced by: `cargo test -p trix-core --test ffi_surface_test`
- Scope: client-local `trix-core` FFI records, enums, helpers, stores, crypto material, and message-body helpers that should remain constructible and callable without panics.

### 2. FFI client usage stays within the declared contract

- Enforced by: `python3 scripts/ffi_parity_audit.py --strict`
- Truth sources:
  - exported surface: `crates/trix-core/src/ffi.rs`
  - declared transitive coverage + search rules: `scripts/ffi_parity_audit.py`
  - explicit allowlisted exceptions: `contracts/ffi-usage-contract.json`
- Notes:
  - raw gaps/orphans are still printed for visibility
  - `--strict` only fails on non-allowlisted drift
  - stale labels inside `contracts/ffi-usage-contract.json` also fail the audit

### 3. Checked-in UniFFI bridges stay in sync with `ffi.rs`

- Enforced by: `./scripts/verify-uniffi-bindings.sh`
- Scope:
  - iOS checked-in Swift/header/modulemap bridge
  - macOS checked-in Swift/header/modulemap bridge
  - Android checked-in Kotlin bridge

### 4. Server JSON wire shapes stay stable

- Enforced by: `cargo test -p trix-types --test api_json_contract`
- Truth source: `crates/trix-types/src/api.rs`
- Scope: representative request/response payload shapes plus enum wire values consumed by server and clients.

### 5. Documented HTTP route surface stays stable

- Enforced by: `cargo test -p trix-server --test openapi_v0_contract`
- Truth sources:
  - documented surface: `openapi/v0.yaml`
  - declared server routes: `crates/trix-server/src/routes/*.rs`
- Scope: v0 path+method catalog must match the real route declarations, and `operationId` values stay unique.

### 6. Client interop contract helpers stay stable

- Enforced by: `python3 -m unittest discover -s scripts -p 'test_*.py' -v`
- Truth sources:
  - `scripts/interop/contracts.py`
  - `scripts/interop/preflight.py`
  - `scripts/interop/scenarios.py`
  - `scripts/interop/runner.py`
  - repo-wide Python contract helper tests under `scripts/tests/`

## When Contract Drift Is Intentional

Update the contract and the implementation in the same change:

1. Change the code.
2. Update the authoritative contract artifact:
   - `contracts/ffi-usage-contract.json`
   - `openapi/v0.yaml`
   - checked-in generated bindings
   - `trix-types` JSON contract expectations
3. Re-run `make contract-check`.

If the change does not include the contract update, the repo should stay red.
