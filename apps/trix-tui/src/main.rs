mod app;
mod ui;

use std::path::PathBuf;

use anyhow::Result;
use clap::Parser;

/// Terminal UI client for Trix (uses the same local state model as `trix-bot` / `trix-botd`).
#[derive(Debug, Parser)]
#[command(name = "trix-tui", version)]
pub struct Cli {
    /// Base URL of the Trix server (e.g. http://127.0.0.1:8080).
    #[arg(long)]
    server_url: String,

    /// Directory for bot state (history, MLS, identity). Must not be shared with another running `trix-botd` or second TUI instance.
    #[arg(long)]
    state_dir: PathBuf,

    /// Profile display name (only used when creating a new account).
    #[arg(long, default_value = "Trix TUI")]
    profile_name: String,

    /// Optional public handle (only used when creating a new account).
    #[arg(long)]
    handle: Option<String>,

    /// Env var name holding the master secret for encrypted `identity.enc.json` (default `TRIX_BOT_MASTER_SECRET`).
    #[arg(long)]
    master_secret_env: Option<String>,

    /// Store identity as plaintext JSON (development only).
    #[arg(long)]
    plaintext_dev_store: bool,
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    app::run(&cli).await
}
