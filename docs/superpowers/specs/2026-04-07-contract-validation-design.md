# Contract Validation: trix-core ↔ trix-server

**Date:** 2026-04-07
**Status:** Draft
**Goal:** Zero uncaught client-server bugs in production (UI excluded).

## Problem

The client (`trix-core`) and server (`trix-server`) share types via `trix-types`, but the contract between them is enforced only by convention:

- **75+ transport methods** in `ServerApiClient` are hand-coded — each manually specifies the URL path, HTTP method, request type, and response type. Any of these can silently drift.
- **OpenAPI spec** (`openapi/v0.yaml`) is maintained manually and has fallen behind the actual implementation — it's documentation, not a source of truth.
- **Existing contract test** (`openapi_v0_contract.rs`) only validates that route paths/methods match the spec. It doesn't verify request/response schemas, status codes, or field-level correctness.
- **WebSocket protocol** has no formal state machine — protocol violations (e.g., missed acks, double Hello) are only caught by E2E tests if a scenario happens to trigger them.

## Approach: Contract Trait + Tests

Hybrid approach: compile-time type safety through a contract trait system, plus property-based and integration tests for runtime/protocol behavior.

## Design

### 1. Contract Trait (`trix-types/src/contract.rs`)

Central abstraction that binds each endpoint to its types at the compiler level:

```rust
use http::Method;
use serde::{de::DeserializeOwned, Serialize};

/// Marker for endpoints with no request body (GET, DELETE, HEAD).
pub type NoBody = ();

/// Marker for endpoints with no JSON response (204, blob downloads).
pub type NoResponse = ();

/// Associates an API endpoint with its path, method, and request/response types.
pub trait ApiEndpoint {
    const PATH: &'static str;
    const METHOD: Method;

    type Request: Serialize + DeserializeOwned;
    type Response: Serialize + DeserializeOwned;
}

/// Extension for endpoints with path parameters.
/// Implementors provide a method to interpolate the path.
pub trait PathEndpoint: ApiEndpoint {
    type PathParams;

    fn render_path(params: &Self::PathParams) -> String;
}

/// Extension for endpoints with query parameters.
pub trait QueryEndpoint: ApiEndpoint {
    type Query: Serialize;
}
```

**Example declarations:**

```rust
pub struct CreateAccount;

impl ApiEndpoint for CreateAccount {
    const PATH: &'static str = "/v0/accounts";
    const METHOD: Method = Method::POST;
    type Request = CreateAccountRequest;
    type Response = CreateAccountResponse;
}

pub struct GetChat;

impl ApiEndpoint for GetChat {
    const PATH: &'static str = "/v0/chats/{chat_id}";
    const METHOD: Method = Method::GET;
    type Request = NoBody;
    type Response = ChatDetailResponse;
}

impl PathEndpoint for GetChat {
    type PathParams = ChatId;

    fn render_path(chat_id: &ChatId) -> String {
        format!("/v0/chats/{}", chat_id.0)
    }
}

pub struct SearchDirectory;

impl ApiEndpoint for SearchDirectory {
    const PATH: &'static str = "/v0/accounts/directory";
    const METHOD: Method = Method::GET;
    type Request = NoBody;
    type Response = AccountDirectoryResponse;
}

impl QueryEndpoint for SearchDirectory {
    type Query = DirectorySearchQuery; // new struct: { q: String, limit: Option<u32> }
}
```

**Endpoint registry macro** — declares all endpoints in one place for test discovery:

```rust
/// Expands to: a list of all endpoint structs for exhaustiveness checks.
macro_rules! all_endpoints {
    ($($endpoint:ident),* $(,)?) => {
        pub const ALL_ENDPOINT_PATHS: &[(&str, Method)] = &[
            $((<$endpoint as ApiEndpoint>::PATH, <$endpoint as ApiEndpoint>::METHOD)),*
        ];
    };
}

all_endpoints!(
    CreateAccount,
    AuthChallenge,
    AuthSession,
    GetMe,
    UpdateProfile,
    // ... all ~50 endpoints
);
```

### 2. Generic Client Transport

Replace hand-coded methods with generic dispatch:

```rust
// crates/trix-core/src/transport.rs

impl ServerApiClient {
    /// Call an endpoint with a JSON body (POST, PATCH, PUT).
    pub async fn call<E: ApiEndpoint>(
        &self,
        request: &E::Request,
    ) -> Result<E::Response, ServerApiError> {
        let url = format!("{}{}", self.base_url, E::PATH);
        let resp = self.http.request(E::METHOD.clone(), &url)
            .bearer_auth_if(self.access_token.as_deref())
            .json(request)
            .send()
            .await
            .map_err(ServerApiError::Request)?;
        self.handle_response::<E::Response>(resp).await
    }

    /// Call an endpoint with path parameters and no body (GET, DELETE).
    pub async fn call_path<E: PathEndpoint<Request = NoBody>>(
        &self,
        params: &E::PathParams,
    ) -> Result<E::Response, ServerApiError> {
        let url = format!("{}{}", self.base_url, E::render_path(params));
        let resp = self.http.request(E::METHOD.clone(), &url)
            .bearer_auth_if(self.access_token.as_deref())
            .send()
            .await
            .map_err(ServerApiError::Request)?;
        self.handle_response::<E::Response>(resp).await
    }

    /// Call an endpoint with path parameters and a body.
    pub async fn call_path_with_body<E: PathEndpoint>(
        &self,
        params: &E::PathParams,
        request: &E::Request,
    ) -> Result<E::Response, ServerApiError> {
        let url = format!("{}{}", self.base_url, E::render_path(params));
        let resp = self.http.request(E::METHOD.clone(), &url)
            .bearer_auth_if(self.access_token.as_deref())
            .json(request)
            .send()
            .await
            .map_err(ServerApiError::Request)?;
        self.handle_response::<E::Response>(resp).await
    }

    /// Call an endpoint with query parameters and no body.
    pub async fn call_query<E: QueryEndpoint<Request = NoBody>>(
        &self,
        query: &E::Query,
    ) -> Result<E::Response, ServerApiError> {
        let url = format!("{}{}", self.base_url, E::PATH);
        let resp = self.http.request(E::METHOD.clone(), &url)
            .bearer_auth_if(self.access_token.as_deref())
            .query(query)
            .send()
            .await
            .map_err(ServerApiError::Request)?;
        self.handle_response::<E::Response>(resp).await
    }

    async fn handle_response<T: DeserializeOwned>(
        &self,
        resp: reqwest::Response,
    ) -> Result<T, ServerApiError> {
        let status = resp.status().as_u16();
        if resp.status().is_success() {
            resp.json::<T>().await.map_err(|e| {
                ServerApiError::InvalidResponse(format!("deserialize failed: {e}"))
            })
        } else {
            let err: ErrorResponse = resp.json().await.map_err(|e| {
                ServerApiError::InvalidResponse(format!("error body: {e}"))
            })?;
            Err(ServerApiError::Api { status, code: err.code, message: err.message })
        }
    }
}
```

**Higher-level wrappers stay** for methods that do base64 encoding, MLS material preparation, etc. But internally they call `self.call::<E>()`:

```rust
impl ServerApiClient {
    /// High-level: creates account from raw key material.
    /// Handles base64 encoding, then delegates to generic call.
    pub async fn create_account(
        &self,
        params: CreateAccountParams,
    ) -> Result<CreateAccountMaterial, ServerApiError> {
        let request = CreateAccountRequest {
            credential_identity_b64: encode_b64(&params.credential_identity),
            // ... base64 encoding ...
        };
        let response = self.call::<CreateAccount>(&request).await?;
        Ok(CreateAccountMaterial {
            account_id: response.account_id,
            // ... base64 decoding ...
        })
    }
}
```

### 3. Generic Server Endpoint Registration

Type-safe route registration on the server side:

```rust
// crates/trix-server/src/contract.rs

use axum::{Json, Router, extract::State, routing::MethodRouter};
use trix_types::contract::ApiEndpoint;
use crate::state::AppState;

/// Build a typed MethodRouter that enforces the contract's request/response types.
pub fn typed_route<E, F, Fut>(handler: F) -> MethodRouter<AppState>
where
    E: ApiEndpoint + 'static,
    E::Request: Send + 'static,
    E::Response: Send + 'static,
    F: Fn(/* extractors */) -> Fut + Clone + Send + 'static,
    Fut: std::future::Future<Output = Result<Json<E::Response>, crate::error::AppError>> + Send,
{
    // Dispatch based on E::METHOD
    // Each handler must accept Json<E::Request> and return Result<Json<E::Response>, AppError>
    todo!("implementation depends on extractor combinations")
}
```

In practice, Axum's type system already enforces handler signatures. The key guarantee comes from using `E::PATH` for route paths instead of string literals:

```rust
// crates/trix-server/src/routes/mod.rs (after migration)

use trix_types::contract::*;

pub fn v0_router() -> Router<AppState> {
    Router::new()
        .route(Health::PATH, get(system::health))
        .route(Version::PATH, get(system::version))
        .route(CreateAccount::PATH, post(accounts::create_account))
        .route(AuthChallenge::PATH, post(auth::challenge))
        // ...
}
```

Server handlers use the contract types in their signatures:

```rust
// Before:
pub async fn create_account(
    State(state): State<AppState>,
    Json(req): Json<CreateAccountRequest>,
) -> Result<Json<CreateAccountResponse>, AppError> { ... }

// After (same, but the test suite verifies it matches the contract):
pub async fn create_account(
    State(state): State<AppState>,
    Json(req): Json<<CreateAccount as ApiEndpoint>::Request>,
) -> Result<Json<<CreateAccount as ApiEndpoint>::Response>, AppError> { ... }
```

### 4. WebSocket Protocol State Machine

Formal description of the WebSocket protocol for testing:

```rust
// crates/trix-types/src/ws_protocol.rs

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WsState {
    Connected,   // TCP connected, awaiting Hello
    Active,      // Received Hello, normal operation
    Replaced,    // SessionReplaced received, must disconnect
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WsTransition {
    Valid(WsState),
    Invalid(&'static str), // reason why this is invalid
}

impl WsState {
    /// What server frames are valid in this state?
    pub fn valid_server_frame(&self, frame: &WebSocketServerFrame) -> WsTransition {
        match (self, frame) {
            // Connected: only Hello is valid
            (WsState::Connected, WebSocketServerFrame::Hello { .. }) =>
                WsTransition::Valid(WsState::Active),
            (WsState::Connected, _) =>
                WsTransition::Invalid("server must send Hello first"),

            // Active: anything except Hello
            (WsState::Active, WebSocketServerFrame::Hello { .. }) =>
                WsTransition::Invalid("duplicate Hello"),
            (WsState::Active, WebSocketServerFrame::SessionReplaced { .. }) =>
                WsTransition::Valid(WsState::Replaced),
            (WsState::Active, _) =>
                WsTransition::Valid(WsState::Active),

            // Replaced: nothing valid
            (WsState::Replaced, _) =>
                WsTransition::Invalid("session replaced, must disconnect"),
        }
    }

    /// What client frames are valid in this state?
    pub fn valid_client_frame(&self, frame: &WebSocketClientFrame) -> WsTransition {
        match (self, frame) {
            (WsState::Active, _) => WsTransition::Valid(WsState::Active),
            (WsState::Connected, _) =>
                WsTransition::Invalid("must wait for Hello before sending"),
            (WsState::Replaced, _) =>
                WsTransition::Invalid("session replaced, must disconnect"),
        }
    }
}
```

**Debug-mode validator:** In test builds, both `ServerWebSocketClient` and the WS handler wrap every frame send/receive through `WsState::valid_*_frame()`, panicking on violations.

### 5. Test Layers

#### Layer 1: Compile-time (free, always on)

- `ApiEndpoint` trait forces type agreement between client and server.
- Changing a type in `trix-types` breaks compilation on both sides.

#### Layer 2: `cargo test` (fast, no database)

**a) Serde roundtrip tests** — auto-generated for every endpoint:

```rust
// crates/trix-types/tests/serde_roundtrip.rs

macro_rules! roundtrip_test {
    ($name:ident, $type:ty, $example:expr) => {
        #[test]
        fn $name() {
            let original: $type = $example;
            let json = serde_json::to_string(&original).unwrap();
            let decoded: $type = serde_json::from_str(&json).unwrap();
            assert_eq!(original, decoded);
        }
    };
}

roundtrip_test!(create_account_request, CreateAccountRequest, CreateAccountRequest {
    handle: "alice".into(),
    display_name: "Alice".into(),
    // ...
});
```

**b) Exhaustiveness test** — verifies every server route has a contract:

```rust
// crates/trix-server/tests/contract_exhaustiveness.rs

#[test]
fn all_server_routes_have_contracts() {
    let server_routes = extract_routes_from_router(); // existing openapi test technique
    let contract_routes: HashSet<_> = ALL_ENDPOINT_PATHS.iter().collect();

    for (path, method) in &server_routes {
        assert!(
            contract_routes.contains(&(path.as_str(), method.clone())),
            "Server route {method} {path} has no ApiEndpoint contract"
        );
    }
}
```

**c) OpenAPI sync test** — generates OpenAPI from contracts, compares to committed spec:

```rust
// crates/trix-server/tests/openapi_sync.rs

#[test]
fn openapi_spec_matches_contracts() {
    let generated = generate_openapi_from_contracts(); // walks ALL_ENDPOINT_PATHS
    let committed = std::fs::read_to_string("openapi/v0.yaml").unwrap();
    assert_eq!(generated, committed, "OpenAPI spec is stale. Run `cargo run --bin generate-openapi` to update.");
}
```

**d) WebSocket state machine property tests:**

```rust
// crates/trix-types/tests/ws_protocol.rs

use proptest::prelude::*;

proptest! {
    #[test]
    fn ws_state_machine_never_panics(frames in prop::collection::vec(arb_server_frame(), 0..100)) {
        let mut state = WsState::Connected;
        for frame in frames {
            match state.valid_server_frame(&frame) {
                WsTransition::Valid(next) => state = next,
                WsTransition::Invalid(_) => {} // invalid is fine, just don't transition
            }
        }
    }
}
```

**e) WebSocket scenario tests:**

```rust
#[test]
fn ws_ack_before_hello_is_invalid() { ... }

#[test]
fn ws_double_hello_is_invalid() { ... }

#[test]
fn ws_send_after_session_replaced_is_invalid() { ... }

#[test]
fn ws_normal_flow_hello_then_inbox_then_ack() { ... }
```

#### Layer 3: Integration tests (needs PostgreSQL)

Existing E2E tests (`client_scenario_e2e.rs`) stay unchanged. Additionally:

**Contract smoke tests** — for each endpoint, call the real server and verify the response deserializes into the contract type:

```rust
// crates/trix-server/tests/contract_smoke.rs

#[tokio::test]
async fn smoke_create_account() {
    let server = TestServer::spawn().await;
    let client = server.api_client();

    let req = CreateAccountRequest { /* minimal valid data */ };
    let resp = client.call::<CreateAccount>(&req).await;
    assert!(resp.is_ok()); // if it deserialized, the contract holds
}

// One test per endpoint, testing that the types actually work end-to-end.
```

### 6. Pre-commit Hook

```bash
#!/bin/sh
# Fast checks only — no database required
cargo check --workspace 2>&1 | head -50
if [ $? -ne 0 ]; then
    echo "❌ Compilation failed"
    exit 1
fi

cargo test -p trix-types --lib 2>&1 | tail -5
cargo test -p trix-server --test contract_exhaustiveness 2>&1 | tail -5
if [ $? -ne 0 ]; then
    echo "❌ Contract tests failed"
    exit 1
fi
```

Runs in ~10-15 seconds after incremental compilation.

### 7. GitHub Actions (optional)

```yaml
# .github/workflows/contract.yml
name: Contract Validation
on: [pull_request]

jobs:
  contract:
    runs-on: ubuntu-latest
    services:
      postgres:
        image: postgres:16
        env:
          POSTGRES_PASSWORD: test
        ports: [5432:5432]
    steps:
      - uses: actions/checkout@v4
      - uses: dtolnay/rust-toolchain@stable
      - uses: Swatinem/rust-cache@v2
      - run: cargo test --workspace
        env:
          DATABASE_URL: postgres://postgres:test@localhost:5432/trix_test
```

### 8. Migration Strategy

Gradual, endpoint-by-endpoint:

1. **Phase 1:** Add `contract.rs` to `trix-types` with trait + 3 pilot endpoints (`CreateAccount`, `AuthChallenge`, `AuthSession`). Add generic `call::<E>()` to transport. Add exhaustiveness test (initially expects only 3 contracts).
2. **Phase 2:** Migrate remaining ~47 endpoints to contract declarations. For each: add struct + impl, switch transport method to use `call::<E>()`, mark old method `#[deprecated]`.
3. **Phase 3:** Switch server `routes/mod.rs` to use `E::PATH` constants. Update handler signatures to reference contract types.
4. **Phase 4:** Add WebSocket state machine, property tests, serde roundtrip tests. Remove deprecated transport methods.
5. **Phase 5:** Add OpenAPI generation from contracts. Replace stale `v0.yaml` with generated version. Add sync test.
6. **Phase 6:** Add pre-commit hook and optional GitHub Actions workflow.

## Out of Scope

- Runtime production monitoring (approach 3 in original discussion — can add later)
- FFI contract validation (already covered by `ffi-usage-contract.json`)
- UI client testing
- Message content validation (encrypted payloads — not inspectable by server)
- Admin endpoint contracts (can be added later, lower priority)

## Dependencies

- `http` crate (already in workspace) — for `Method` type in trait
- `proptest` — for property-based WebSocket tests (new dev-dependency)
- No new production dependencies required

## Success Criteria

- Changing a request/response type in `trix-types` without updating both client and server causes a compilation error
- Adding a new server route without a contract declaration causes test failure
- OpenAPI spec is always in sync with code (test failure if stale)
- WebSocket protocol violations are caught by state machine tests
- All contract tests run in <30 seconds without a database
