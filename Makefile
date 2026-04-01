OUT ?= bindings

check:
	$(MAKE) contract-check
	cargo check --workspace

fmt:
	cargo fmt --all

contract-check:
	cargo test -p trix-core --test ffi_surface_test
	cargo test -p trix-types --test api_json_contract
	cargo test -p trix-server --test openapi_v0_contract
	python3 scripts/ffi_parity_audit.py --strict
	./scripts/verify-uniffi-bindings.sh
	python3 -m unittest discover -s scripts -p 'test_*.py' -v

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

ffi-parity-audit:
	python3 scripts/ffi_parity_audit.py --strict
