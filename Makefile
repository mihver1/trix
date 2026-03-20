OUT ?= bindings

check:
	cargo check --workspace

fmt:
	cargo fmt --all

run-server:
	cargo run -p trixd

build-trix-core-lib:
	cargo build -p trix-core --lib

ffi-bindings-swift: build-trix-core-lib
	mkdir -p $(OUT)
	cargo run -p trix-core --bin uniffi-bindgen -- generate --library target/debug/libtrix_core.dylib --language swift --out-dir $(OUT)

ffi-bindings-kotlin: build-trix-core-lib
	mkdir -p $(OUT)
	cargo run -p trix-core --bin uniffi-bindgen -- generate --library target/debug/libtrix_core.dylib --language kotlin --out-dir $(OUT)

ffi-bindings: build-trix-core-lib
	mkdir -p $(OUT)
	cargo run -p trix-core --bin uniffi-bindgen -- generate --library target/debug/libtrix_core.dylib --language swift --language kotlin --out-dir $(OUT)
