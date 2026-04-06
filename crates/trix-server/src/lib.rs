pub mod admin_auth;
pub mod admin_logs;
pub mod app;
pub mod auth;
pub mod blobs;
pub mod build;
pub mod config;
pub mod db;
pub mod error;
pub mod push;
pub mod rate_limit;
pub mod routes;
pub mod signatures;
pub mod state;

pub use admin_logs::{AdminLogBuffer, AdminLogLayer};
pub use app::{run, run_with_admin_log_buffer};
pub use build::BuildInfo;
pub use config::AppConfig;

#[cfg(test)]
pub mod test_support {
    use std::sync::LazyLock;

    use tokio::sync::Mutex;

    /// Shared lock for tests that mutate the same local Postgres database.
    pub static POSTGRES_TEST_LOCK: LazyLock<Mutex<()>> = LazyLock::new(|| Mutex::new(()));
}
