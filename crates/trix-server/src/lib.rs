pub mod admin_auth;
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

pub use app::run;
pub use build::BuildInfo;
pub use config::AppConfig;

#[cfg(test)]
pub mod test_support {
    use std::sync::LazyLock;

    use tokio::sync::Mutex;

    /// Shared lock for tests that mutate the same local Postgres database.
    pub static POSTGRES_TEST_LOCK: LazyLock<Mutex<()>> = LazyLock::new(|| Mutex::new(()));
}
