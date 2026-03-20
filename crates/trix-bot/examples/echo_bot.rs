use std::{env, path::PathBuf};

use anyhow::{Context, Result, anyhow};
use tokio::sync::broadcast::error::RecvError;
use trix_bot::{Bot, BotEvent, BotInitConfig};
use trix_types::ChatId;
use uuid::Uuid;

#[tokio::main]
async fn main() -> Result<()> {
    let server_url = required_env("TRIX_SERVER_URL")?;
    let state_dir = PathBuf::from(required_env("TRIX_BOT_STATE_DIR")?);
    let profile_name = env::var("TRIX_BOT_PROFILE_NAME").unwrap_or_else(|_| "Echo Bot".to_owned());
    let handle = env::var("TRIX_BOT_HANDLE").ok();
    let plaintext_dev_store = env_flag("TRIX_BOT_PLAINTEXT_STORE");
    let master_secret_env = env::var("TRIX_BOT_MASTER_SECRET_ENV").ok();

    let bot = Bot::init(BotInitConfig {
        server_url,
        state_dir,
        profile_name,
        handle,
        master_secret_env,
        plaintext_dev_store,
    })
    .await?;
    let identity = bot.identity();
    let self_account_id = identity.account_id.clone();
    let mut events = bot.subscribe();
    bot.start().await?;

    eprintln!(
        "bot ready: account_id={} device_id={}",
        identity.account_id, identity.device_id
    );

    loop {
        tokio::select! {
            _ = tokio::signal::ctrl_c() => {
                bot.stop().await?;
                return Ok(());
            }
            event = events.recv() => {
                match event {
                    Ok(BotEvent::Ready { .. }) => {}
                    Ok(BotEvent::ConnectionChanged { connected, mode }) => {
                        eprintln!("connection_changed connected={connected} mode={mode:?}");
                    }
                    Ok(BotEvent::TextMessage {
                        chat_id,
                        sender_account_id,
                        text,
                        ..
                    }) => {
                        if sender_account_id == self_account_id {
                            continue;
                        }
                        let reply = format!("echo: {text}");
                        bot.send_text(parse_chat_id(&chat_id)?, reply).await?;
                    }
                    Ok(BotEvent::UnsupportedMessage {
                        chat_id,
                        content_type,
                        projection_kind,
                        ..
                    }) => {
                        eprintln!(
                            "unsupported_message chat_id={chat_id} content_type={content_type} projection_kind={projection_kind}"
                        );
                    }
                    Ok(BotEvent::Error { message }) => {
                        eprintln!("bot_error {message}");
                    }
                    Err(RecvError::Lagged(skipped)) => {
                        eprintln!("bot event stream lagged by {skipped} messages");
                    }
                    Err(RecvError::Closed) => return Err(anyhow!("bot event stream closed")),
                }
            }
        }
    }
}

fn required_env(name: &str) -> Result<String> {
    env::var(name).with_context(|| format!("missing required env var `{name}`"))
}

fn env_flag(name: &str) -> bool {
    env::var(name)
        .map(|value| matches!(value.as_str(), "1" | "true" | "TRUE" | "yes" | "YES"))
        .unwrap_or(false)
}

fn parse_chat_id(value: &str) -> Result<ChatId> {
    Ok(ChatId(
        Uuid::parse_str(value).with_context(|| format!("invalid chat id `{value}`"))?,
    ))
}
