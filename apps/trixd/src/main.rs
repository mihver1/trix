use anyhow::Result;
use tracing_subscriber::{EnvFilter, fmt, layer::SubscriberExt, util::SubscriberInitExt};
use trix_server::{AppConfig, run};

#[tokio::main]
async fn main() -> Result<()> {
    let config = AppConfig::from_env()?;

    tracing_subscriber::registry()
        .with(EnvFilter::new(config.log_filter.clone()))
        .with(fmt::layer())
        .init();

    run(config).await
}
