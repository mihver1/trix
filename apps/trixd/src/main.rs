use anyhow::Result;
use std::sync::Arc;
use tracing_subscriber::{EnvFilter, fmt, layer::SubscriberExt, util::SubscriberInitExt};
use trix_server::{AdminLogBuffer, AdminLogLayer, AppConfig, run_with_admin_log_buffer};

#[tokio::main]
async fn main() -> Result<()> {
    let config = AppConfig::from_env()?;
    let admin_log_buffer = Arc::new(AdminLogBuffer::default());

    tracing_subscriber::registry()
        .with(EnvFilter::new(config.log_filter.clone()))
        .with(AdminLogLayer::new(admin_log_buffer.clone()))
        .with(fmt::layer())
        .init();

    run_with_admin_log_buffer(config, admin_log_buffer).await
}
