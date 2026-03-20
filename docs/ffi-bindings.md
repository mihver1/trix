# FFI Bindings

`trix-core` now exposes a `UniFFI` surface and ships a local `uniffi-bindgen` binary.

## Build The Library

```bash
cargo build -p trix-core --lib
```

This produces the Rust library artifacts, including the macOS debug dylib at:

```text
target/debug/libtrix_core.dylib
```

## Generate Swift Bindings

```bash
cargo run -p trix-core --bin uniffi-bindgen -- generate \
  --library target/debug/libtrix_core.dylib \
  --language swift \
  --out-dir bindings/swift
```

## Generate Kotlin Bindings

```bash
cargo run -p trix-core --bin uniffi-bindgen -- generate \
  --library target/debug/libtrix_core.dylib \
  --language kotlin \
  --out-dir bindings/kotlin
```

## Generate Both At Once

```bash
cargo run -p trix-core --bin uniffi-bindgen -- generate \
  --library target/debug/libtrix_core.dylib \
  --language swift \
  --language kotlin \
  --out-dir bindings
```

## Make Targets

```bash
make ffi-bindings
make ffi-bindings-swift
make ffi-bindings-kotlin
make ffi-bindings OUT=/tmp/trix-bindings
```

## Notes

- The exported API is defined in [ffi.rs](/Users/m.verhovyh/Projects/trix/crates/trix-core/src/ffi.rs).
- The crate now builds as `lib`, `cdylib`, and `staticlib`.
- The current FFI surface is synchronous on purpose; client apps should call it off the UI thread.
- `FfiMlsFacade` now supports persistent state via `new_persistent(storage_root)`, `load_persistent(storage_root)`, `save_state()`, and `storage_root()`.
- Persistent MLS state is stored under the provided root as `storage.json` and `metadata.json`.
- Kotlin generation works without `ktlint`, but UniFFI will print a non-fatal formatting warning if `ktlint` is not installed.
- Kotlin sources are generated under `bindings/uniffi/trix_core/`.
