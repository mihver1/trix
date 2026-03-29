# macOS Admin Control App Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use @superpowers:subagent-driven-development (recommended) or @superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a separate internal macOS admin app plus a dedicated `/v0/admin/*` backend surface for cluster switching, operator auth, user provisioning/update/disable/reactivate, and runtime server settings.

**Architecture:** Add a small admin slice inside `trix-server` with its own JWT model, DB-backed runtime settings, reversible account disable, and a provisioning record flow that feeds the existing cryptographic account bootstrap. In parallel, scaffold `apps/macos-admin` as a separate `SwiftUI` app with local cluster profiles, per-cluster admin sessions in `Keychain`, and workspaces for Overview, Users, Registration, and Server Settings.

**Tech Stack:** Rust, Axum, SQLx/PostgreSQL migrations, OpenAPI, `trix-types`, SwiftUI, SwiftPM, XcodeGen/Xcode, Security.framework `Keychain`, `URLSession`, Bash smoke commands.

---

## Scope Check

This remains one plan because the backend admin surface and the new macOS admin app form one vertical slice. The app is not useful without the admin API, and the admin API is intentionally scoped around the workflows the app must ship in `v1`.

## File Structure

### Existing files to modify

- `.env.example`
  - add cluster-local admin auth env vars for local development and manual verification
- `README.md`
  - document the new admin app and local commands once the slice exists
- `openapi/v0.yaml`
  - document the `/v0/admin/*` contract alongside the existing consumer `v0` surface
- `scripts/client-smoke-harness.sh`
  - add an optional `macos-admin` smoke suite so the new package has a repeatable entrypoint
- `crates/trix-server/src/lib.rs`
  - register the new `admin_auth` module
- `crates/trix-server/src/app.rs`
  - keep router wiring and CORS methods aligned with `DELETE /v0/admin/session`
- `crates/trix-server/src/config.rs`
  - read and validate admin credential env vars and admin JWT settings
- `crates/trix-server/src/state.rs`
  - add admin auth helpers and account-scoped websocket closure support
- `crates/trix-server/src/routes/mod.rs`
  - mount `/v0/admin`
- `crates/trix-server/src/routes/accounts.rs`
  - consume provisioning tokens during first-device bootstrap and enforce registration gating
- `crates/trix-server/src/routes/auth.rs`
  - reject disabled accounts during auth challenge/session creation
- `crates/trix-server/src/routes/devices.rs`
  - reject new pending-device registration and related device-link operations for disabled accounts
- `crates/trix-server/src/db.rs`
  - store runtime settings, provisioning records, admin user listing, reversible disable state, and new authorization gates
- `crates/trix-types/src/api.rs`
  - add admin request/response DTOs and the optional consumer `provision_token`
- `crates/trix-types/src/lib.rs`
  - re-export the new API types

### New backend files to create

- `migrations/0007_admin_runtime_settings_and_provisions.sql`
  - add reversible account-disable columns, runtime settings, and operator provisioning storage
- `crates/trix-server/src/admin_auth.rs`
  - separate admin JWT manager and principal model from the consumer device-token path
- `crates/trix-server/src/routes/admin.rs`
  - define the `/v0/admin/*` router and handlers

### New macOS admin app files to create

- `apps/macos-admin/Package.swift`
  - SwiftPM entrypoint for local build and test
- `apps/macos-admin/project.yml`
  - XcodeGen source of truth for the admin app, tests, and scheme
- `apps/macos-admin/TrixMacAdmin.entitlements`
  - app sandbox, network client, and keychain-safe baseline for the admin tool
- `apps/macos-admin/TrixMacAdmin.xcodeproj/project.pbxproj`
  - generated and committed Xcode project
- `apps/macos-admin/TrixMacAdmin.xcodeproj/xcshareddata/xcschemes/TrixMacAdmin.xcscheme`
  - generated shared scheme for `xcodebuild`
- `apps/macos-admin/README.md`
  - run/build/test instructions for operators and developers
- `apps/macos-admin/Sources/TrixMacAdmin/App/TrixMacAdminApp.swift`
  - `@main` app entry
- `apps/macos-admin/Sources/TrixMacAdmin/App/AdminAppModel.swift`
  - top-level cluster, session, and workspace state
- `apps/macos-admin/Sources/TrixMacAdmin/Features/Shell/RootView.swift`
  - `NavigationSplitView` shell
- `apps/macos-admin/Sources/TrixMacAdmin/Features/Clusters/ClusterSidebarView.swift`
  - cluster list and selection UI
- `apps/macos-admin/Sources/TrixMacAdmin/Features/Clusters/ClusterProfileEditorView.swift`
  - add/edit cluster profiles
- `apps/macos-admin/Sources/TrixMacAdmin/Features/Auth/AdminLoginView.swift`
  - cluster-local admin login flow
- `apps/macos-admin/Sources/TrixMacAdmin/Features/Workspace/AdminWorkspaceView.swift`
  - overview/users/settings workspace container
- `apps/macos-admin/Sources/TrixMacAdmin/Features/Overview/OverviewView.swift`
  - health, version, registration state, and session banner
- `apps/macos-admin/Sources/TrixMacAdmin/Features/Registration/RegistrationSettingsView.swift`
  - `allow_public_account_registration` editor
- `apps/macos-admin/Sources/TrixMacAdmin/Features/ServerSettings/ServerSettingsView.swift`
  - runtime DB-backed settings editor
- `apps/macos-admin/Sources/TrixMacAdmin/Features/Users/UserListView.swift`
  - searchable, paginated user table
- `apps/macos-admin/Sources/TrixMacAdmin/Features/Users/UserDetailView.swift`
  - profile/device detail plus disable/reactivate actions
- `apps/macos-admin/Sources/TrixMacAdmin/Features/Users/ProvisionUserView.swift`
  - operator provisioning subflow
- `apps/macos-admin/Sources/TrixMacAdmin/Models/ClusterProfile.swift`
  - local cluster configuration model
- `apps/macos-admin/Sources/TrixMacAdmin/Models/AdminAPIModels.swift`
  - app-local DTOs mirroring admin OpenAPI responses
- `apps/macos-admin/Sources/TrixMacAdmin/Services/AdminAPIClient.swift`
  - `URLSession`-backed admin API wrapper
- `apps/macos-admin/Sources/TrixMacAdmin/Services/AdminRequestCoordinator.swift`
  - cancellation/invalidation of stale requests during cluster switching
- `apps/macos-admin/Sources/TrixMacAdmin/Support/AppIdentity.swift`
  - admin-only bundle ID, keychain service, and app support names
- `apps/macos-admin/Sources/TrixMacAdmin/Support/AdminKeychainStore.swift`
  - per-cluster credential and token persistence
- `apps/macos-admin/Sources/TrixMacAdmin/Support/ClusterProfileStore.swift`
  - `Application Support` storage for cluster profiles and last selection
- `apps/macos-admin/Sources/TrixMacAdmin/Support/AdminSessionStore.swift`
  - token expiry/logout/session restoration helpers
- `apps/macos-admin/Sources/TrixMacAdmin/Support/MacAdminUITestSupport.swift`
  - accessibility IDs and launch arguments for smoke UI coverage
- `apps/macos-admin/Tests/TrixMacAdminTests/AppIdentityTests.swift`
  - prevent collisions with the consumer app identity
- `apps/macos-admin/Tests/TrixMacAdminTests/ClusterProfileStoreTests.swift`
  - cluster profile persistence coverage
- `apps/macos-admin/Tests/TrixMacAdminTests/AdminSessionStoreTests.swift`
  - token persistence and expiry behavior
- `apps/macos-admin/Tests/TrixMacAdminTests/AdminAPIClientTests.swift`
  - request building and bearer token injection
- `apps/macos-admin/Tests/TrixMacAdminTests/AdminAppModelTests.swift`
  - cluster switching, stale response dropping, destructive action confirmation, and onboarding artifact state
- `apps/macos-admin/TrixMacAdminUITests/UserAdminSmokeTests.swift`
  - launch, cluster sidebar, and one operator flow smoke test

## Preconditions

- For Rust integration tests that require the local database:

```bash
docker compose up -d postgres
```

- For local manual server runs after Task 1:

```bash
cp .env.example .env
set -a
source .env
set +a
```

- For macOS project generation:

```bash
xcodegen --version
```

Expected: a version compatible with the repo’s current `project.yml` usage, not `command not found`.

## Task 1: Add Admin Schema And Config Primitives

**Files:**
- Create: `migrations/0007_admin_runtime_settings_and_provisions.sql`
- Modify: `.env.example`
- Modify: `crates/trix-server/src/config.rs`
- Modify: `crates/trix-server/src/db.rs`
- Test: `crates/trix-server/src/config.rs`
- Test: `crates/trix-server/src/db.rs`

- [ ] **Step 1: Write the failing config and DB tests**

Add a config validation test in `crates/trix-server/src/config.rs`:

```rust
#[test]
fn validate_requires_admin_credentials() {
    let mut config = valid_config();
    config.admin_username = "".to_owned();
    config.admin_password = "".to_owned();
    config.admin_jwt_signing_key = "admin-test-secret".to_owned();

    assert!(config.validate().is_err());
}
```

Add a Postgres-backed DB test in `crates/trix-server/src/db.rs`:

```rust
#[tokio::test]
#[ignore = "requires local postgres"]
async fn admin_runtime_settings_defaults_to_public_registration_enabled() {
    let db = connect_test_db().await;
    reset_test_db(&db).await;

    let settings = db.get_admin_runtime_settings().await.expect("settings");

    assert!(settings.allow_public_account_registration);
    assert_eq!(settings.brand_display_name, None);
    assert_eq!(settings.support_contact, None);
    assert_eq!(settings.policy_text, None);
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:

```bash
cargo test -p trix-server validate_requires_admin_credentials -- --exact
cargo test -p trix-server admin_runtime_settings_defaults_to_public_registration_enabled -- --ignored --exact
```

Expected:

- the config test fails to compile or fails because the admin fields do not exist yet
- the DB test fails because the runtime settings accessor and migration do not exist yet

- [ ] **Step 3: Implement the schema and config primitives**

Extend `AppConfig` and `.env.example` with concrete `v1` admin env vars:

```text
TRIX_ADMIN_USERNAME=ops
TRIX_ADMIN_PASSWORD=dev-admin-secret-change-me
TRIX_ADMIN_JWT_SIGNING_KEY=dev-admin-jwt-secret-change-me
TRIX_ADMIN_SESSION_TTL_SECONDS=900
```

Create `migrations/0007_admin_runtime_settings_and_provisions.sql` with explicit runtime-state tables and reversible disable storage:

```sql
ALTER TABLE accounts
    ADD COLUMN disabled_at timestamptz,
    ADD COLUMN disabled_reason text;

CREATE TABLE admin_runtime_settings (
    singleton boolean PRIMARY KEY DEFAULT TRUE CHECK (singleton),
    allow_public_account_registration boolean NOT NULL DEFAULT TRUE,
    brand_display_name text,
    support_contact text,
    policy_text text,
    updated_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO admin_runtime_settings (singleton) VALUES (TRUE)
ON CONFLICT (singleton) DO NOTHING;

CREATE TABLE admin_user_provisions (
    provision_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    provision_token_hash bytea NOT NULL UNIQUE,
    handle text,
    profile_name text NOT NULL,
    profile_bio text,
    expires_at timestamptz NOT NULL,
    claimed_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now()
);
```

Add minimal DB accessors in `crates/trix-server/src/db.rs` for:

- `get_admin_runtime_settings`
- `update_admin_runtime_settings`
- `create_admin_user_provision`
- `consume_admin_user_provision`

Also extend `reset_test_db` so new admin-state tables cannot leak between tests:

```rust
async fn reset_test_db(db: &Database) {
    sqlx::query("TRUNCATE TABLE admin_user_provisions, accounts CASCADE")
        .execute(&db.pool)
        .await
        .unwrap();

    sqlx::query("DELETE FROM admin_runtime_settings")
        .execute(&db.pool)
        .await
        .unwrap();

    sqlx::query(
        "INSERT INTO admin_runtime_settings (singleton) VALUES (TRUE) ON CONFLICT (singleton) DO NOTHING",
    )
    .execute(&db.pool)
    .await
    .unwrap();
}
```

- [ ] **Step 4: Run targeted verification**

Run:

```bash
cargo test -p trix-server validate_requires_admin_credentials -- --exact
cargo test -p trix-server admin_runtime_settings_defaults_to_public_registration_enabled -- --ignored --exact
cargo test -p trix-server
```

Expected:

- the targeted config and DB tests pass
- the package test suite still passes

- [ ] **Step 5: Commit**

```bash
git add .env.example migrations/0007_admin_runtime_settings_and_provisions.sql crates/trix-server/src/config.rs crates/trix-server/src/db.rs
git commit -m "feat: add admin config and storage primitives"
```

## Task 2: Add Admin Auth And Route Skeleton

**Files:**
- Create: `crates/trix-server/src/admin_auth.rs`
- Create: `crates/trix-server/src/routes/admin.rs`
- Modify: `crates/trix-server/src/lib.rs`
- Modify: `crates/trix-server/src/app.rs`
- Modify: `crates/trix-server/src/state.rs`
- Modify: `crates/trix-server/src/routes/mod.rs`
- Modify: `crates/trix-types/src/api.rs`
- Modify: `crates/trix-types/src/lib.rs`
- Modify: `openapi/v0.yaml`
- Test: `crates/trix-server/src/admin_auth.rs`
- Test: `crates/trix-server/src/routes/admin.rs`

- [ ] **Step 1: Write the failing auth and route tests**

In `crates/trix-server/src/admin_auth.rs`, add:

```rust
#[test]
fn admin_token_round_trip_authenticates() {
    let manager = AdminAuthManager::new("admin-signing-key", Duration::from_secs(900));
    let (token, _) = manager.issue_token("ops".to_owned()).expect("token");

    let mut headers = HeaderMap::new();
    headers.insert(
        header::AUTHORIZATION,
        HeaderValue::from_str(&format!("Bearer {token}")).unwrap(),
    );

    let principal = manager.authenticate_headers(&headers).expect("principal");
    assert_eq!(principal.username, "ops");
}
```

In `crates/trix-server/src/routes/admin.rs`, add a route test that proves a consumer token is rejected:

```rust
#[tokio::test]
async fn admin_routes_reject_consumer_bearer_tokens() {
    let app = test_app().await;
    let consumer_token = issue_consumer_token_for_tests(&app);

    let response = app
        .oneshot(
            Request::builder()
                .uri("/v0/admin/overview")
                .header(header::AUTHORIZATION, format!("Bearer {consumer_token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
}
```

Add the symmetric route test that proves admin tokens are rejected by consumer routes:

```rust
#[tokio::test]
async fn consumer_routes_reject_admin_bearer_tokens() {
    let app = test_app().await;
    let admin_token = issue_admin_token_for_tests(&app).await;

    let response = app
        .oneshot(
            Request::builder()
                .uri("/v0/accounts/me")
                .header(header::AUTHORIZATION, format!("Bearer {admin_token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:

```bash
cargo test -p trix-server admin_token_round_trip_authenticates -- --exact
cargo test -p trix-server admin_routes_reject_consumer_bearer_tokens -- --exact
cargo test -p trix-server consumer_routes_reject_admin_bearer_tokens -- --exact
```

Expected: FAIL because the admin auth manager and `/v0/admin` router do not exist yet.

- [ ] **Step 3: Implement the admin auth and route skeleton**

Create `crates/trix-server/src/admin_auth.rs` with a dedicated JWT model:

```rust
#[derive(Debug, Clone, Serialize, Deserialize)]
struct AdminJwtClaims {
    sub: String,
    username: String,
    exp: usize,
}

#[derive(Debug, Clone)]
pub struct AdminPrincipal {
    pub username: String,
}
```

Then:

- wire `pub mod admin_auth;` in `crates/trix-server/src/lib.rs`
- add `authenticate_admin_headers` in `crates/trix-server/src/state.rs`
- mount `.nest("/admin", admin::router())` in `crates/trix-server/src/routes/mod.rs`
- allow `DELETE` in `crates/trix-server/src/app.rs` CORS methods
- create `POST /v0/admin/session`, `DELETE /v0/admin/session`, and `GET /v0/admin/overview` in `crates/trix-server/src/routes/admin.rs`
- treat `DELETE /v0/admin/session` as an authenticated stateless logout acknowledgment that returns `204 No Content`
- add matching request/response types to `crates/trix-types/src/api.rs`
- document the new paths in `openapi/v0.yaml`

- [ ] **Step 4: Run targeted verification**

Run:

```bash
cargo test -p trix-server admin_token_round_trip_authenticates -- --exact
cargo test -p trix-server admin_routes_reject_consumer_bearer_tokens -- --exact
cargo test -p trix-server consumer_routes_reject_admin_bearer_tokens -- --exact
cargo test -p trix-server
```

Expected:

- all three targeted tests pass
- the package still compiles with the new `/v0/admin` router

- [ ] **Step 5: Commit**

```bash
git add crates/trix-server/src/admin_auth.rs crates/trix-server/src/routes/admin.rs crates/trix-server/src/lib.rs crates/trix-server/src/app.rs crates/trix-server/src/state.rs crates/trix-server/src/routes/mod.rs crates/trix-types/src/api.rs crates/trix-types/src/lib.rs openapi/v0.yaml
git commit -m "feat: add admin auth and route skeleton"
```

## Task 3: Implement Runtime Settings And Overview Endpoints

**Files:**
- Modify: `crates/trix-server/src/routes/admin.rs`
- Modify: `crates/trix-server/src/db.rs`
- Modify: `crates/trix-types/src/api.rs`
- Modify: `crates/trix-types/src/lib.rs`
- Modify: `openapi/v0.yaml`
- Test: `crates/trix-server/src/db.rs`
- Test: `crates/trix-server/src/routes/admin.rs`

- [ ] **Step 1: Write the failing settings and overview tests**

Add a DB-backed route test in `crates/trix-server/src/routes/admin.rs`:

```rust
#[tokio::test]
async fn admin_can_toggle_public_registration_and_read_it_back() {
    let app = test_app().await;
    let admin_token = issue_admin_token_for_tests(&app).await;

    let patch = serde_json::json!({
        "allow_public_account_registration": false
    });

    let patch_response = admin_json(
        &app,
        Method::PATCH,
        "/v0/admin/settings/registration",
        &admin_token,
        patch,
    )
    .await;
    assert_eq!(patch_response.status(), StatusCode::OK);

    let get_response = admin_empty(&app, Method::GET, "/v0/admin/settings/registration", &admin_token).await;
    assert_eq!(get_response.status(), StatusCode::OK);
}
```

Add an overview route test:

```rust
#[tokio::test]
async fn overview_reports_user_count_and_registration_state() {
    let app = test_app().await;
    let admin_token = issue_admin_token_for_tests(&app).await;

    let response = admin_empty(&app, Method::GET, "/v0/admin/overview", &admin_token).await;
    assert_eq!(response.status(), StatusCode::OK);

    let body: AdminOverviewResponse = read_json_body(response).await;
    assert_eq!(body.user_count, 0);
    assert!(body.allow_public_account_registration);
}
```

Add a DB test in `crates/trix-server/src/db.rs`:

```rust
#[tokio::test]
#[ignore = "requires local postgres"]
async fn update_admin_runtime_settings_persists_server_fields() {
    let db = connect_test_db().await;
    reset_test_db(&db).await;

    db.update_admin_runtime_settings(UpdateAdminRuntimeSettingsInput {
        allow_public_account_registration: Some(false),
        brand_display_name: Some(Some("Trix EU".to_owned())),
        support_contact: Some(Some("ops@example.com".to_owned())),
        policy_text: Some(Some("Internal use only".to_owned())),
    })
    .await
    .unwrap();

    let settings = db.get_admin_runtime_settings().await.unwrap();
    assert_eq!(settings.brand_display_name.as_deref(), Some("Trix EU"));
    assert_eq!(settings.support_contact.as_deref(), Some("ops@example.com"));
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:

```bash
cargo test -p trix-server admin_can_toggle_public_registration_and_read_it_back -- --exact
cargo test -p trix-server overview_reports_user_count_and_registration_state -- --exact
cargo test -p trix-server update_admin_runtime_settings_persists_server_fields -- --ignored --exact
```

Expected: FAIL because the settings endpoints and update paths are not implemented yet.

- [ ] **Step 3: Implement the runtime settings and overview endpoints**

Add explicit DTOs such as:

```rust
pub struct AdminRegistrationSettingsResponse {
    pub allow_public_account_registration: bool,
}

pub struct AdminServerSettingsResponse {
    pub brand_display_name: Option<String>,
    pub support_contact: Option<String>,
    pub policy_text: Option<String>,
}
```

Implement in `crates/trix-server/src/routes/admin.rs`:

- `GET /v0/admin/settings/registration`
- `PATCH /v0/admin/settings/registration`
- `GET /v0/admin/settings/server`
- `PATCH /v0/admin/settings/server`
- `GET /v0/admin/overview`

`GET /v0/admin/overview` should return:

- current backend version/build metadata
- health status summary
- `allow_public_account_registration`
- `user_count`
- high-level user stats such as `disabled_user_count`
- current admin username/session expiry if already modeled in the response

- [ ] **Step 4: Run targeted verification**

Run:

```bash
cargo test -p trix-server admin_can_toggle_public_registration_and_read_it_back -- --exact
cargo test -p trix-server overview_reports_user_count_and_registration_state -- --exact
cargo test -p trix-server update_admin_runtime_settings_persists_server_fields -- --ignored --exact
cargo test -p trix-server
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add crates/trix-server/src/routes/admin.rs crates/trix-server/src/db.rs crates/trix-types/src/api.rs crates/trix-types/src/lib.rs openapi/v0.yaml
git commit -m "feat: add admin runtime settings endpoints"
```

## Task 4: Implement Admin User Listing, Detail, Update, And Provision Flow

**Files:**
- Modify: `crates/trix-server/src/routes/admin.rs`
- Modify: `crates/trix-server/src/routes/accounts.rs`
- Modify: `crates/trix-server/src/db.rs`
- Modify: `crates/trix-types/src/api.rs`
- Modify: `crates/trix-types/src/lib.rs`
- Modify: `openapi/v0.yaml`
- Test: `crates/trix-server/src/db.rs`
- Test: `crates/trix-server/src/routes/admin.rs`

- [ ] **Step 1: Write the failing user-list and provision tests**

In `crates/trix-server/src/db.rs`, add a pagination test:

```rust
#[tokio::test]
#[ignore = "requires local postgres"]
async fn admin_user_list_paginates_in_reverse_creation_order() {
    let db = connect_test_db().await;
    reset_test_db(&db).await;

    let _alice = db
        .create_account(make_account_input("alice", "Alice Primary", [11; 32], [12; 32]))
        .await
        .unwrap();
    let bob = db
        .create_account(make_account_input("bob", "Bob Primary", [21; 32], [22; 32]))
        .await
        .unwrap();
    let carol = db
        .create_account(make_account_input("carol", "Carol Primary", [31; 32], [32; 32]))
        .await
        .unwrap();

    let first_page = db
        .list_admin_users(ListAdminUsersInput {
            query: None,
            status: None,
            cursor: None,
            limit: 2,
        })
        .await
        .unwrap();

    assert_eq!(first_page.users.len(), 2);
    assert_eq!(first_page.users[0].account_id, carol.account_id);
    assert_eq!(first_page.users[1].account_id, bob.account_id);
}
```

Add a provisioning test:

```rust
#[tokio::test]
#[ignore = "requires local postgres"]
async fn provision_token_allows_account_bootstrap_when_public_registration_is_disabled() {
    let db = connect_test_db().await;
    reset_test_db(&db).await;

    db.update_admin_runtime_settings(UpdateAdminRuntimeSettingsInput {
        allow_public_account_registration: Some(false),
        brand_display_name: None,
        support_contact: None,
        policy_text: None,
    })
    .await
    .unwrap();

    let provision = db
        .create_admin_user_provision(CreateAdminUserProvisionInput {
            handle: Some("alice".to_owned()),
            profile_name: "Alice".to_owned(),
            profile_bio: None,
            ttl_seconds: 86400,
        })
        .await
        .unwrap();

    let consumed = db.consume_admin_user_provision(&provision.plaintext_token).await.unwrap();
    assert_eq!(consumed.profile_name, "Alice");
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:

```bash
cargo test -p trix-server admin_user_list_paginates_in_reverse_creation_order -- --ignored --exact
cargo test -p trix-server provision_token_allows_account_bootstrap_when_public_registration_is_disabled -- --ignored --exact
```

Expected: FAIL because the admin-user queries, cursor format, and provision token flow do not exist yet.

- [ ] **Step 3: Implement user list/detail/update and provisioning**

Add DTOs and handlers for:

- `GET /v0/admin/users?q=&status=&cursor=&limit=`
- `GET /v0/admin/users/{account_id}`
- `PATCH /v0/admin/users/{account_id}`
- `POST /v0/admin/users`

Use a stable cursor based on reverse creation order:

```rust
ORDER BY a.created_at DESC, a.account_id DESC
```

Implement provisioning as:

1. admin route creates a one-time provision record and returns an onboarding artifact
2. `CreateAccountRequest` gains:

```rust
pub provision_token: Option<String>,
```

3. `POST /v0/accounts` consumes that provision token during the normal cryptographic bootstrap path when public registration is off

Do not synthesize root keys or device identities on the server.

- [ ] **Step 4: Run targeted verification**

Run:

```bash
cargo test -p trix-server admin_user_list_paginates_in_reverse_creation_order -- --ignored --exact
cargo test -p trix-server provision_token_allows_account_bootstrap_when_public_registration_is_disabled -- --ignored --exact
cargo test -p trix-server
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add crates/trix-server/src/routes/admin.rs crates/trix-server/src/routes/accounts.rs crates/trix-server/src/db.rs crates/trix-types/src/api.rs crates/trix-types/src/lib.rs openapi/v0.yaml
git commit -m "feat: add admin user listing and provisioning"
```

## Task 5: Implement Disable/Reactivate And Consumer Gate Enforcement

**Files:**
- Modify: `crates/trix-server/src/routes/admin.rs`
- Modify: `crates/trix-server/src/routes/auth.rs`
- Modify: `crates/trix-server/src/routes/accounts.rs`
- Modify: `crates/trix-server/src/routes/devices.rs`
- Modify: `crates/trix-server/src/state.rs`
- Modify: `crates/trix-server/src/db.rs`
- Modify: `crates/trix-types/src/api.rs`
- Modify: `crates/trix-types/src/lib.rs`
- Modify: `openapi/v0.yaml`
- Test: `crates/trix-server/src/db.rs`
- Test: `crates/trix-server/src/state.rs`

- [ ] **Step 1: Write the failing disable and websocket tests**

Add a DB integration test:

```rust
#[tokio::test]
#[ignore = "requires local postgres"]
async fn disabled_account_is_hidden_from_directory_and_rejected_by_session_gate() {
    let db = connect_test_db().await;
    reset_test_db(&db).await;

    let alice = db
        .create_account(make_account_input("alice", "Alice Primary", [41; 32], [42; 32]))
        .await
        .unwrap();
    let bob = db
        .create_account(make_account_input("bob", "Bob Primary", [51; 32], [52; 32]))
        .await
        .unwrap();

    db.disable_account(alice.account_id, Some("policy")).await.unwrap();

    let directory = db
        .search_account_directory(bob.account_id, Some("alice"), true, Some(10))
        .await
        .unwrap();
    assert!(directory.is_empty());

    let err = db
        .ensure_active_device_session(alice.account_id, alice.device_id)
        .await
        .unwrap_err();
    assert!(matches!(err, AppError::Unauthorized(_)));
}
```

Add a reactivation test in the same task:

```rust
#[tokio::test]
#[ignore = "requires local postgres"]
async fn reactivated_account_reappears_in_directory_and_session_gate() {
    let db = connect_test_db().await;
    reset_test_db(&db).await;

    let alice = db
        .create_account(make_account_input("alice", "Alice Primary", [61; 32], [62; 32]))
        .await
        .unwrap();
    let bob = db
        .create_account(make_account_input("bob", "Bob Primary", [71; 32], [72; 32]))
        .await
        .unwrap();

    db.disable_account(alice.account_id, Some("policy")).await.unwrap();
    db.reactivate_account(alice.account_id).await.unwrap();

    let directory = db
        .search_account_directory(bob.account_id, Some("alice"), true, Some(10))
        .await
        .unwrap();
    assert_eq!(directory.len(), 1);

    db.ensure_active_device_session(alice.account_id, alice.device_id)
        .await
        .unwrap();
}
```

Add a websocket-registry unit test in `crates/trix-server/src/state.rs`:

```rust
#[tokio::test]
async fn close_many_sends_session_replaced_frames() {
    let registry = WebSocketSessionRegistry::default();
    let (tx, mut rx) = mpsc::unbounded_channel();
    let device_id = Uuid::new_v4();

    registry.register(device_id, tx).await;
    registry.close_many(&[device_id], "account disabled").await;

    let command = rx.recv().await.expect("command");
    assert!(matches!(
        command,
        WebSocketSessionCommand::Frame(WebSocketServerFrame::SessionReplaced { .. })
    ));
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:

```bash
cargo test -p trix-server disabled_account_is_hidden_from_directory_and_rejected_by_session_gate -- --ignored --exact
cargo test -p trix-server reactivated_account_reappears_in_directory_and_session_gate -- --ignored --exact
cargo test -p trix-server close_many_sends_session_replaced_frames -- --exact
```

Expected: FAIL because disable/reactivate and account-scoped websocket closure are not implemented.

- [ ] **Step 3: Implement disable/reactivate and all consumer gates**

Implement in `crates/trix-server/src/db.rs`:

- `disable_account`
- `reactivate_account`
- `list_active_device_ids_for_account`

Then extend consumer gating so disabled accounts:

- do not appear in directory search
- cannot create auth challenges or sessions
- cannot complete first-device account creation without a valid provision path
- cannot create pending-device registrations or similar device-link flows
- fail `ensure_active_device_session`

Add explicit admin action routes:

```text
POST /v0/admin/users/{account_id}/disable
POST /v0/admin/users/{account_id}/reactivate
```

Finally, add `WebSocketSessionRegistry::close_many(&[Uuid], reason: &str)` and call it after a successful disable using the account’s active device IDs.

- [ ] **Step 4: Run targeted verification**

Run:

```bash
cargo test -p trix-server disabled_account_is_hidden_from_directory_and_rejected_by_session_gate -- --ignored --exact
cargo test -p trix-server reactivated_account_reappears_in_directory_and_session_gate -- --ignored --exact
cargo test -p trix-server close_many_sends_session_replaced_frames -- --exact
cargo test -p trix-server -- --ignored
```

Expected:

- the disable-specific tests pass
- the ignored Postgres-backed suite still passes

- [ ] **Step 5: Commit**

```bash
git add crates/trix-server/src/routes/admin.rs crates/trix-server/src/routes/auth.rs crates/trix-server/src/routes/accounts.rs crates/trix-server/src/routes/devices.rs crates/trix-server/src/state.rs crates/trix-server/src/db.rs crates/trix-types/src/api.rs crates/trix-types/src/lib.rs openapi/v0.yaml
git commit -m "feat: enforce disabled account admin controls"
```

## Task 6: Scaffold The macOS Admin App Package And Project

**Files:**
- Create: `apps/macos-admin/Package.swift`
- Create: `apps/macos-admin/project.yml`
- Create: `apps/macos-admin/TrixMacAdmin.entitlements`
- Create: `apps/macos-admin/README.md`
- Create: `apps/macos-admin/Sources/TrixMacAdmin/App/TrixMacAdminApp.swift`
- Create: `apps/macos-admin/Sources/TrixMacAdmin/App/AdminAppModel.swift`
- Create: `apps/macos-admin/Sources/TrixMacAdmin/Features/Shell/RootView.swift`
- Create: `apps/macos-admin/Sources/TrixMacAdmin/Support/AppIdentity.swift`
- Create: `apps/macos-admin/Tests/TrixMacAdminTests/AppIdentityTests.swift`
- Create: `apps/macos-admin/TrixMacAdmin.xcodeproj/project.pbxproj`
- Create: `apps/macos-admin/TrixMacAdmin.xcodeproj/xcshareddata/xcschemes/TrixMacAdmin.xcscheme`

- [ ] **Step 1: Write the failing smoke test for the new app identity**

Create `apps/macos-admin/Tests/TrixMacAdminTests/AppIdentityTests.swift`:

```swift
import XCTest
@testable import TrixMacAdmin

final class AppIdentityTests: XCTestCase {
    func testAdminBundleIdentityDoesNotCollideWithConsumerApp() {
        XCTAssertEqual(AppIdentity.bundleIdentifier, "com.softgrid.trixadmin")
        XCTAssertNotEqual(AppIdentity.bundleIdentifier, "com.softgrid.trixapp")
        XCTAssertEqual(AppIdentity.keychainService, "com.softgrid.trixadmin")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:

```bash
swift test --package-path apps/macos-admin --filter AppIdentityTests
```

Expected: FAIL because the package, target, and `AppIdentity` do not exist yet.

- [ ] **Step 3: Implement the minimal app shell**

Mirror the existing `apps/macos` structure, but omit `trix_coreFFI` and Rust linker configuration. The initial app target should compile with:

```swift
@main
struct TrixMacAdminApp: App {
    @StateObject private var model = AdminAppModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .task { await model.start() }
        }
    }
}
```

Create `project.yml` with:

- product name `TrixMacAdmin`
- bundle ID `com.softgrid.trixadmin`
- unit-test target
- UI-test target placeholder if you prefer to wire it immediately

Generate and commit the Xcode project:

```bash
xcodegen generate --spec apps/macos-admin/project.yml
```

- [ ] **Step 4: Run targeted verification**

Run:

```bash
swift test --package-path apps/macos-admin --filter AppIdentityTests
swift build --package-path apps/macos-admin
xcodebuild -project "apps/macos-admin/TrixMacAdmin.xcodeproj" -scheme "TrixMacAdmin" -destination "platform=macOS" build CODE_SIGNING_ALLOWED=NO
```

Expected:

- the identity test passes
- `swift build` succeeds
- `xcodebuild` ends with `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add apps/macos-admin
git commit -m "feat: scaffold macOS admin app shell"
```

## Task 7: Implement Cluster Profiles, Keychain Sessions, And The Admin API Client

**Files:**
- Create: `apps/macos-admin/Sources/TrixMacAdmin/Models/ClusterProfile.swift`
- Create: `apps/macos-admin/Sources/TrixMacAdmin/Models/AdminAPIModels.swift`
- Create: `apps/macos-admin/Sources/TrixMacAdmin/Services/AdminAPIClient.swift`
- Create: `apps/macos-admin/Sources/TrixMacAdmin/Services/AdminRequestCoordinator.swift`
- Create: `apps/macos-admin/Sources/TrixMacAdmin/Support/AdminKeychainStore.swift`
- Create: `apps/macos-admin/Sources/TrixMacAdmin/Support/ClusterProfileStore.swift`
- Create: `apps/macos-admin/Sources/TrixMacAdmin/Support/AdminSessionStore.swift`
- Create: `apps/macos-admin/Sources/TrixMacAdmin/Features/Clusters/ClusterSidebarView.swift`
- Create: `apps/macos-admin/Sources/TrixMacAdmin/Features/Clusters/ClusterProfileEditorView.swift`
- Create: `apps/macos-admin/Sources/TrixMacAdmin/Features/Auth/AdminLoginView.swift`
- Modify: `apps/macos-admin/Sources/TrixMacAdmin/App/AdminAppModel.swift`
- Modify: `apps/macos-admin/Sources/TrixMacAdmin/Features/Shell/RootView.swift`
- Create: `apps/macos-admin/Tests/TrixMacAdminTests/ClusterProfileStoreTests.swift`
- Create: `apps/macos-admin/Tests/TrixMacAdminTests/AdminSessionStoreTests.swift`
- Create: `apps/macos-admin/Tests/TrixMacAdminTests/AdminAPIClientTests.swift`

- [ ] **Step 1: Write the failing store and client tests**

Create `ClusterProfileStoreTests.swift`:

```swift
func testRoundTripsClusterProfilesAndLastSelection() throws {
    let store = ClusterProfileStore(rootURL: temporaryRoot)
    let eu = ClusterProfile(
        id: UUID(),
        displayName: "prod-eu",
        baseURL: URL(string: "https://eu.example")!,
        environmentLabel: "prod",
        authMode: .localCredentials
    )
    let us = ClusterProfile(
        id: UUID(),
        displayName: "staging",
        baseURL: URL(string: "https://staging.example")!,
        environmentLabel: "staging",
        authMode: .localCredentials
    )

    try store.save([eu, us], lastSelectedClusterID: us.id)
    let snapshot = try store.load()

    XCTAssertEqual(snapshot.profiles.count, 2)
    XCTAssertEqual(snapshot.lastSelectedClusterID, us.id)
}
```

Create `AdminAPIClientTests.swift`:

```swift
func testOverviewRequestUsesClusterBaseURLAndBearerToken() async throws {
    let recorder = HTTPRequestRecorder()
    let client = AdminAPIClient(session: recorder.session)
    let cluster = ClusterProfile(
        id: UUID(),
        displayName: "prod-eu",
        baseURL: URL(string: "https://eu.example")!,
        environmentLabel: "prod"
    )

    _ = try await client.fetchOverview(cluster: cluster, accessToken: "token-123")

    XCTAssertEqual(recorder.lastRequest?.url?.absoluteString, "https://eu.example/v0/admin/overview")
    XCTAssertEqual(recorder.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer token-123")
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:

```bash
swift test --package-path apps/macos-admin --filter ClusterProfileStoreTests
swift test --package-path apps/macos-admin --filter AdminAPIClientTests
```

Expected: FAIL because the stores, DTOs, and client do not exist yet.

- [ ] **Step 3: Implement cluster and session infrastructure**

Implement:

- `ClusterProfile` with `id`, `displayName`, `baseURL`, `environmentLabel`, and `authMode`
- `ClusterProfileStore` backed by `Application Support`
- `AdminKeychainStore` with per-cluster keys such as `cluster.<uuid>.access-token`
- `AdminSessionStore` with expiry handling
- `AdminAPIClient` for:
  - `createSession`
  - `deleteSession`
  - `fetchOverview`
  - `fetchRegistrationSettings`
  - `updateRegistrationSettings`
  - `fetchServerSettings`
  - `updateServerSettings`
  - `fetchUsers`
  - `fetchUserDetail`
  - `provisionUser`
  - `disableUser`
  - `reactivateUser`
- `AdminRequestCoordinator` that cancels in-flight cluster-scoped tasks when the active cluster changes

- [ ] **Step 4: Run targeted verification**

Run:

```bash
swift test --package-path apps/macos-admin --filter ClusterProfileStoreTests
swift test --package-path apps/macos-admin --filter AdminSessionStoreTests
swift test --package-path apps/macos-admin --filter AdminAPIClientTests
swift build --package-path apps/macos-admin
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/macos-admin
git commit -m "feat: add admin cluster and session infrastructure"
```

## Task 8: Implement Overview, Registration, And Server Settings Workspaces

**Files:**
- Create: `apps/macos-admin/Sources/TrixMacAdmin/Features/Workspace/AdminWorkspaceView.swift`
- Create: `apps/macos-admin/Sources/TrixMacAdmin/Features/Overview/OverviewView.swift`
- Create: `apps/macos-admin/Sources/TrixMacAdmin/Features/Registration/RegistrationSettingsView.swift`
- Create: `apps/macos-admin/Sources/TrixMacAdmin/Features/ServerSettings/ServerSettingsView.swift`
- Modify: `apps/macos-admin/Sources/TrixMacAdmin/App/AdminAppModel.swift`
- Modify: `apps/macos-admin/Sources/TrixMacAdmin/Features/Shell/RootView.swift`
- Modify: `apps/macos-admin/Sources/TrixMacAdmin/Services/AdminAPIClient.swift`
- Create: `apps/macos-admin/Tests/TrixMacAdminTests/AdminAppModelTests.swift`

- [ ] **Step 1: Write the failing app-model tests**

Add `AdminAppModelTests.swift`:

```swift
@MainActor
func testSwitchClusterDropsStaleOverviewResponse() async throws {
    let client = MockAdminAPIClient()
    let eu = ClusterProfile(id: UUID(), displayName: "prod-eu", baseURL: URL(string: "https://eu.example")!, environmentLabel: "prod")
    let us = ClusterProfile(id: UUID(), displayName: "staging", baseURL: URL(string: "https://staging.example")!, environmentLabel: "staging")
    let model = AdminAppModel(client: client)

    client.enqueueDelayedOverview(clusterID: eu.id, title: "EU")
    client.enqueueImmediateOverview(clusterID: us.id, title: "STAGING")

    await model.selectCluster(eu)
    await model.selectCluster(us)

    XCTAssertEqual(model.overview?.clusterDisplayName, "STAGING")
}
```

Add a canonical-refresh test:

```swift
@MainActor
func testTogglePublicRegistrationRefreshesCanonicalSettings() async throws {
    let client = MockAdminAPIClient()
    let model = AdminAppModel(client: client)
    let cluster = ClusterProfile(id: UUID(), displayName: "prod-eu", baseURL: URL(string: "https://eu.example")!, environmentLabel: "prod")

    await model.selectCluster(cluster)
    try await model.setPublicRegistrationEnabled(false)

    XCTAssertEqual(client.updatedRegistrationStates, [false])
    XCTAssertEqual(model.registrationSettings?.allowPublicAccountRegistration, false)
}
```

Add expired-session coverage:

```swift
@MainActor
func testExpiredSessionSurfacesReconnectRequirement() async throws {
    let client = MockAdminAPIClient()
    client.nextOverviewError = .unauthorized
    let model = AdminAppModel(client: client)
    let cluster = ClusterProfile(
        id: UUID(),
        displayName: "prod-eu",
        baseURL: URL(string: "https://eu.example")!,
        environmentLabel: "prod",
        authMode: .localCredentials
    )

    await model.selectCluster(cluster)

    XCTAssertTrue(model.requiresReauthentication)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:

```bash
swift test --package-path apps/macos-admin --filter AdminAppModelTests
```

Expected: FAIL because the workspace state and settings flows are not implemented yet.

- [ ] **Step 3: Implement the overview and settings workspaces**

Build the shell so the active cluster header always shows:

- cluster display name
- environment label
- session state

Implement:

- `OverviewView`
- `RegistrationSettingsView`
- `ServerSettingsView`
- `AdminWorkspaceView`

The patch flows should:

1. show confirmation UI for destructive or high-impact changes
2. call the admin API
3. refetch canonical server state
4. ignore stale responses from the previous cluster

- [ ] **Step 4: Run targeted verification**

Run:

```bash
swift test --package-path apps/macos-admin --filter AdminAppModelTests
swift build --package-path apps/macos-admin
xcodebuild -project "apps/macos-admin/TrixMacAdmin.xcodeproj" -scheme "TrixMacAdmin" -destination "platform=macOS" build CODE_SIGNING_ALLOWED=NO
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/macos-admin
git commit -m "feat: add admin overview and settings workspaces"
```

## Task 9: Implement The Users Workspace And Operator Flows

**Files:**
- Create: `apps/macos-admin/Sources/TrixMacAdmin/Features/Users/UserListView.swift`
- Create: `apps/macos-admin/Sources/TrixMacAdmin/Features/Users/UserDetailView.swift`
- Create: `apps/macos-admin/Sources/TrixMacAdmin/Features/Users/ProvisionUserView.swift`
- Create: `apps/macos-admin/Sources/TrixMacAdmin/Support/MacAdminUITestSupport.swift`
- Create: `apps/macos-admin/TrixMacAdminUITests/UserAdminSmokeTests.swift`
- Modify: `apps/macos-admin/project.yml`
- Modify: `apps/macos-admin/Sources/TrixMacAdmin/App/AdminAppModel.swift`
- Modify: `apps/macos-admin/Sources/TrixMacAdmin/Features/Workspace/AdminWorkspaceView.swift`
- Modify: `apps/macos-admin/Sources/TrixMacAdmin/Services/AdminAPIClient.swift`
- Modify: `apps/macos-admin/Tests/TrixMacAdminTests/AdminAppModelTests.swift`

- [ ] **Step 1: Write the failing user workflow tests**

Extend `AdminAppModelTests.swift`:

```swift
@MainActor
func testConfirmDisableUserRequiresMatchingClusterName() async throws {
    let client = MockAdminAPIClient()
    let cluster = ClusterProfile(id: UUID(), displayName: "prod-eu", baseURL: URL(string: "https://eu.example")!, environmentLabel: "prod")
    let model = AdminAppModel(client: client)

    await model.selectCluster(cluster)
    model.beginDisable(userID: UUID(), clusterName: "prod-eu")
    model.disableConfirmationText = "prod-eu"
    try await model.confirmDisableUser()

    XCTAssertEqual(client.disabledUserIDs.count, 1)
}
```

Add a provisioning-state test:

```swift
@MainActor
func testProvisionFlowStoresReturnedOnboardingArtifact() async throws {
    let client = MockAdminAPIClient()
    client.nextProvisionResponse = .init(
        provisionID: UUID().uuidString,
        onboardingToken: "invite-token",
        onboardingURL: "trix://provision/invite-token"
    )

    let model = AdminAppModel(client: client)
    try await model.provisionUser(handle: "alice", profileName: "Alice", profileBio: nil)

    XCTAssertEqual(model.lastProvisioningArtifact?.onboardingToken, "invite-token")
}
```

Create `apps/macos-admin/TrixMacAdminUITests/UserAdminSmokeTests.swift`:

```swift
func testLaunchesClusterSidebar() {
    let app = XCUIApplication()
    app.launchArguments = [MacAdminUITestLaunchArgument.enableUITesting]
    app.launch()

    XCTAssertTrue(app.staticTexts["Clusters"].waitForExistence(timeout: 2))
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:

```bash
swift test --package-path apps/macos-admin --filter AdminAppModelTests
xcodegen generate --spec apps/macos-admin/project.yml
xcodebuild -project "apps/macos-admin/TrixMacAdmin.xcodeproj" -scheme "TrixMacAdmin" -destination "platform=macOS" test CODE_SIGNING_ALLOWED=NO
```

Expected:

- the unit tests fail because the users workspace is not implemented yet
- the UI smoke test fails or does not build because the accessibility surface is not present yet

- [ ] **Step 3: Implement the user list, detail, provision, and destructive flows**

Implement:

- searchable user table with cursor pagination
- user detail screen with profile and device summaries
- provisioning modal/subflow that surfaces the returned onboarding artifact
- disable/reactivate flows with typed cluster-name confirmation
- `MacAdminUITestSupport` accessibility identifiers for the sidebar, search field, and primary action buttons

Keep destructive writes non-optimistic: only update the UI after the server confirms the mutation and the canonical list/detail state is reloaded.

- [ ] **Step 4: Run targeted verification**

Run:

```bash
swift test --package-path apps/macos-admin --filter AdminAppModelTests
swift test --package-path apps/macos-admin
xcodebuild -project "apps/macos-admin/TrixMacAdmin.xcodeproj" -scheme "TrixMacAdmin" -destination "platform=macOS" test CODE_SIGNING_ALLOWED=NO
```

Expected:

- the unit tests pass
- the package tests pass
- `xcodebuild test` ends with `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add apps/macos-admin
git commit -m "feat: add admin user workflows"
```

## Task 10: Wire Docs, Smoke Harness, And Full Validation

**Files:**
- Modify: `scripts/client-smoke-harness.sh`
- Modify: `README.md`
- Modify: `apps/macos-admin/README.md`

- [ ] **Step 1: Add the admin app to docs and smoke commands**

Update `scripts/client-smoke-harness.sh` to support:

```bash
--suite macos-admin
```

with:

```bash
run_root_command swift test --package-path "$ROOT_DIR/apps/macos-admin"
```

Then update:

- `README.md` component list and common commands
- `apps/macos-admin/README.md` with `swift build`, `swift run`, `swift test`, and `xcodegen` usage

- [ ] **Step 2: Run the macOS admin package verification**

Run:

```bash
swift test --package-path apps/macos-admin
swift build --package-path apps/macos-admin
xcodebuild -project "apps/macos-admin/TrixMacAdmin.xcodeproj" -scheme "TrixMacAdmin" -destination "platform=macOS" test CODE_SIGNING_ALLOWED=NO
```

Expected:

- the package tests pass
- the app builds
- the Xcode test run succeeds

- [ ] **Step 3: Run the backend verification**

Run:

```bash
cargo test -p trix-server
cargo test -p trix-server -- --ignored
```

Expected:

- the unit suite passes
- the Postgres-backed ignored suite passes with the local database running

- [ ] **Step 4: Run the contract and harness checks**

Run:

```bash
rg "^  /v0/admin/" openapi/v0.yaml
./scripts/client-smoke-harness.sh --suite macos-admin --no-postgres
```

Expected:

- `rg` prints the `/v0/admin/*` paths you implemented
- the `macos-admin` smoke suite completes successfully

- [ ] **Step 5: Commit**

```bash
git add scripts/client-smoke-harness.sh README.md apps/macos-admin/README.md
git commit -m "chore: wire admin app docs and smoke checks"
```
