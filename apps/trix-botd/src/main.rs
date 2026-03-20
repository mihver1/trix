use std::{env, path::PathBuf};

use anyhow::{Context, Result, anyhow};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    sync::mpsc,
};
use trix_bot::{Bot, BotEvent, BotInitConfig, BotLoadConfig};
use trix_types::ChatId;
use uuid::Uuid;

#[tokio::main]
async fn main() -> Result<()> {
    let args = env::args().collect::<Vec<_>>();
    let Some(command) = args.get(1).map(String::as_str) else {
        return Err(anyhow!(
            "expected subcommand: init | run | publish-key-packages | stdio"
        ));
    };

    match command {
        "init" => run_init(&args[2..]).await,
        "run" => run_forever(&args[2..]).await,
        "publish-key-packages" => run_publish_key_packages(&args[2..]).await,
        "stdio" => run_stdio().await,
        other => Err(anyhow!("unknown subcommand `{other}`")),
    }
}

async fn run_init(args: &[String]) -> Result<()> {
    let bot = Bot::init(parse_init_config(args)?).await?;
    write_stdout_json(&bot.identity()).await
}

async fn run_forever(args: &[String]) -> Result<()> {
    let bot = Bot::load(parse_load_config(args)?).await?;
    let mut events = bot.subscribe();
    bot.start().await?;

    let mut stdout = tokio::io::stdout();
    loop {
        tokio::select! {
            event = events.recv() => {
                let event = event.context("bot event stream closed")?;
                let line = serde_json::to_string(&event)?;
                stdout.write_all(line.as_bytes()).await?;
                stdout.write_all(b"\n").await?;
                stdout.flush().await?;
            }
            _ = tokio::signal::ctrl_c() => {
                bot.stop().await?;
                return Ok(());
            }
        }
    }
}

async fn run_publish_key_packages(args: &[String]) -> Result<()> {
    let bot = Bot::load(parse_load_config(args)?).await?;
    let count = flag_value(args, "--count")
        .map(|value| parse_usize(&value, "count"))
        .transpose()?
        .unwrap_or(128);
    let published = bot.publish_key_packages(count).await?;
    write_stdout_json(&json!({ "published": published })).await
}

async fn run_stdio() -> Result<()> {
    let stdin = tokio::io::stdin();
    let stdout = tokio::io::stdout();
    let mut lines = BufReader::new(stdin).lines();
    let (tx, mut rx) = mpsc::unbounded_channel::<String>();

    let writer = tokio::spawn(async move {
        let mut stdout = stdout;
        while let Some(message) = rx.recv().await {
            if stdout.write_all(message.as_bytes()).await.is_err() {
                break;
            }
            if stdout.write_all(b"\n").await.is_err() {
                break;
            }
            if stdout.flush().await.is_err() {
                break;
            }
        }
    });

    let mut session = RpcSession::default();
    while let Some(line) = lines.next_line().await? {
        if line.trim().is_empty() {
            continue;
        }

        let reply = match handle_rpc_request(&mut session, &tx, &line).await {
            Ok(Some(reply)) => Some(reply),
            Ok(None) => None,
            Err(err) => Some(make_error_response(Value::Null, -32000, err.to_string())),
        };

        if let Some(reply) = reply {
            let _ = tx.send(reply);
        }
    }

    if let Some(bot) = &session.bot {
        let _ = bot.stop().await;
    }
    if let Some(task) = session.events_task.take() {
        task.abort();
    }
    drop(tx);
    let _ = writer.await;
    Ok(())
}

#[derive(Default)]
struct RpcSession {
    bot: Option<Bot>,
    events_task: Option<tokio::task::JoinHandle<()>>,
}

#[derive(Debug, Deserialize)]
struct JsonRpcRequest {
    jsonrpc: String,
    id: Value,
    method: String,
    #[serde(default)]
    params: Value,
}

#[derive(Debug, Deserialize)]
struct RpcInitParams {
    server_url: String,
    state_dir: String,
    profile_name: String,
    handle: Option<String>,
    master_secret_env: Option<String>,
    #[serde(default)]
    plaintext_dev_store: bool,
}

#[derive(Debug, Deserialize)]
struct RpcTimelineParams {
    chat_id: String,
    limit: Option<usize>,
}

#[derive(Debug, Deserialize)]
struct RpcSendTextParams {
    chat_id: String,
    text: String,
}

#[derive(Debug, Deserialize)]
struct RpcPublishKeyPackagesParams {
    count: Option<usize>,
}

async fn handle_rpc_request(
    session: &mut RpcSession,
    tx: &mpsc::UnboundedSender<String>,
    line: &str,
) -> Result<Option<String>> {
    let request: JsonRpcRequest =
        serde_json::from_str(line).context("failed to decode json-rpc request")?;
    if request.jsonrpc != "2.0" {
        return Ok(Some(make_error_response(
            request.id,
            -32600,
            "jsonrpc must be `2.0`".to_owned(),
        )));
    }

    let result = match request.method.as_str() {
        "bot.v1.init" => {
            let params: RpcInitParams = serde_json::from_value(request.params)?;
            let bot = Bot::init(BotInitConfig {
                server_url: params.server_url,
                state_dir: PathBuf::from(params.state_dir),
                profile_name: params.profile_name,
                handle: params.handle,
                master_secret_env: params.master_secret_env,
                plaintext_dev_store: params.plaintext_dev_store,
            })
            .await?;
            replace_event_forwarder(session, tx.clone(), &bot);
            session.bot = Some(bot.clone());
            serde_json::to_value(bot.identity())?
        }
        "bot.v1.start" => {
            let bot = session
                .bot
                .as_ref()
                .ok_or_else(|| anyhow!("bot.v1.init must be called first"))?;
            bot.start().await?;
            json!({ "ok": true })
        }
        "bot.v1.stop" => {
            let bot = session
                .bot
                .as_ref()
                .ok_or_else(|| anyhow!("bot.v1.init must be called first"))?;
            bot.stop().await?;
            json!({ "ok": true })
        }
        "bot.v1.list_chats" => {
            let bot = session
                .bot
                .as_ref()
                .ok_or_else(|| anyhow!("bot.v1.init must be called first"))?;
            let chats = bot.list_chats().await?;
            json!({
                "chats": chats.into_iter().map(chat_list_item_json).collect::<Vec<_>>()
            })
        }
        "bot.v1.get_timeline" => {
            let bot = session
                .bot
                .as_ref()
                .ok_or_else(|| anyhow!("bot.v1.init must be called first"))?;
            let params: RpcTimelineParams = serde_json::from_value(request.params)?;
            let chat_id = parse_chat_id(&params.chat_id)?;
            let timeline = bot.get_timeline(chat_id, params.limit).await?;
            json!({
                "items": timeline.into_iter().map(timeline_item_json).collect::<Vec<_>>()
            })
        }
        "bot.v1.send_text" => {
            let bot = session
                .bot
                .as_ref()
                .ok_or_else(|| anyhow!("bot.v1.init must be called first"))?;
            let params: RpcSendTextParams = serde_json::from_value(request.params)?;
            let chat_id = parse_chat_id(&params.chat_id)?;
            serde_json::to_value(bot.send_text(chat_id, params.text).await?)?
        }
        "bot.v1.publish_key_packages" => {
            let bot = session
                .bot
                .as_ref()
                .ok_or_else(|| anyhow!("bot.v1.init must be called first"))?;
            let params: RpcPublishKeyPackagesParams = serde_json::from_value(request.params)?;
            let published = bot
                .publish_key_packages(params.count.unwrap_or(128))
                .await?;
            json!({ "published": published })
        }
        other => {
            return Ok(Some(make_error_response(
                request.id,
                -32601,
                format!("unknown method `{other}`"),
            )));
        }
    };

    Ok(Some(make_success_response(request.id, result)))
}

fn replace_event_forwarder(session: &mut RpcSession, tx: mpsc::UnboundedSender<String>, bot: &Bot) {
    if let Some(task) = session.events_task.take() {
        task.abort();
    }

    let mut events = bot.subscribe();
    session.events_task = Some(tokio::spawn(async move {
        while let Ok(event) = events.recv().await {
            if let Some(message) = event_notification(event) {
                if tx.send(message).is_err() {
                    break;
                }
            }
        }
    }));
}

fn event_notification(event: BotEvent) -> Option<String> {
    let (method, params) = match event {
        BotEvent::Ready {
            account_id,
            device_id,
        } => (
            "bot.v1.ready",
            json!({
                "account_id": account_id,
                "device_id": device_id,
            }),
        ),
        BotEvent::ConnectionChanged { connected, mode } => (
            "bot.v1.connection_changed",
            json!({
                "connected": connected,
                "mode": mode,
            }),
        ),
        BotEvent::TextMessage {
            chat_id,
            message_id,
            server_seq,
            sender_account_id,
            sender_device_id,
            text,
            created_at_unix,
        } => (
            "bot.v1.text_message",
            json!({
                "chat_id": chat_id,
                "message_id": message_id,
                "server_seq": server_seq,
                "sender_account_id": sender_account_id,
                "sender_device_id": sender_device_id,
                "text": text,
                "created_at_unix": created_at_unix,
            }),
        ),
        BotEvent::UnsupportedMessage {
            chat_id,
            message_id,
            server_seq,
            content_type,
            projection_kind,
            created_at_unix,
        } => (
            "bot.v1.unsupported_message",
            json!({
                "chat_id": chat_id,
                "message_id": message_id,
                "server_seq": server_seq,
                "content_type": content_type,
                "projection_kind": projection_kind,
                "created_at_unix": created_at_unix,
            }),
        ),
        BotEvent::Error { message } => (
            "bot.v1.error",
            json!({
                "message": message,
            }),
        ),
    };

    serde_json::to_string(&json!({
        "jsonrpc": "2.0",
        "method": method,
        "params": params,
    }))
    .ok()
}

fn make_success_response(id: Value, result: Value) -> String {
    serde_json::to_string(&json!({
        "jsonrpc": "2.0",
        "id": id,
        "result": result,
    }))
    .unwrap_or_else(|_| {
        "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32603,\"message\":\"failed to encode response\"}}".to_owned()
    })
}

fn make_error_response(id: Value, code: i64, message: String) -> String {
    serde_json::to_string(&json!({
        "jsonrpc": "2.0",
        "id": id,
        "error": {
            "code": code,
            "message": message,
        }
    }))
    .unwrap_or_else(|_| {
        "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32603,\"message\":\"failed to encode error response\"}}".to_owned()
    })
}

async fn write_stdout_json(value: &impl Serialize) -> Result<()> {
    let encoded = serde_json::to_string_pretty(value)?;
    let mut stdout = tokio::io::stdout();
    stdout.write_all(encoded.as_bytes()).await?;
    stdout.write_all(b"\n").await?;
    stdout.flush().await?;
    Ok(())
}

fn chat_list_item_json(item: trix_core::LocalChatListItem) -> Value {
    json!({
        "chat_id": item.chat_id.0.to_string(),
        "chat_type": item.chat_type,
        "title": item.title,
        "display_title": item.display_title,
        "last_server_seq": item.last_server_seq,
        "epoch": item.epoch,
        "pending_message_count": item.pending_message_count,
        "unread_count": item.unread_count,
        "preview_text": item.preview_text,
        "preview_sender_account_id": item.preview_sender_account_id.map(|id| id.0.to_string()),
        "preview_sender_display_name": item.preview_sender_display_name,
        "preview_is_outgoing": item.preview_is_outgoing,
        "preview_server_seq": item.preview_server_seq,
        "preview_created_at_unix": item.preview_created_at_unix,
        "participant_profiles": item.participant_profiles.into_iter().map(|profile| {
            json!({
                "account_id": profile.account_id.0.to_string(),
                "handle": profile.handle,
                "profile_name": profile.profile_name,
                "profile_bio": profile.profile_bio,
            })
        }).collect::<Vec<_>>()
    })
}

fn timeline_item_json(item: trix_core::LocalTimelineItem) -> Value {
    json!({
        "server_seq": item.server_seq,
        "message_id": item.message_id.0.to_string(),
        "sender_account_id": item.sender_account_id.0.to_string(),
        "sender_device_id": item.sender_device_id.0.to_string(),
        "sender_display_name": item.sender_display_name,
        "is_outgoing": item.is_outgoing,
        "epoch": item.epoch,
        "message_kind": item.message_kind,
        "content_type": item.content_type,
        "projection_kind": item.projection_kind,
        "body": item.body,
        "body_parse_error": item.body_parse_error,
        "preview_text": item.preview_text,
        "merged_epoch": item.merged_epoch,
        "created_at_unix": item.created_at_unix,
    })
}

fn parse_init_config(args: &[String]) -> Result<BotInitConfig> {
    Ok(BotInitConfig {
        server_url: required_flag(args, "--server-url")?,
        state_dir: PathBuf::from(required_flag(args, "--state-dir")?),
        profile_name: required_flag(args, "--profile-name")?,
        handle: flag_value(args, "--handle"),
        master_secret_env: flag_value(args, "--master-secret-env"),
        plaintext_dev_store: has_flag(args, "--plaintext-dev-store"),
    })
}

fn parse_load_config(args: &[String]) -> Result<BotLoadConfig> {
    Ok(BotLoadConfig {
        state_dir: PathBuf::from(required_flag(args, "--state-dir")?),
        server_url_override: flag_value(args, "--server-url"),
        master_secret_env: flag_value(args, "--master-secret-env"),
        plaintext_dev_store: has_flag(args, "--plaintext-dev-store"),
    })
}

fn required_flag(args: &[String], name: &str) -> Result<String> {
    flag_value(args, name).ok_or_else(|| anyhow!("missing required flag `{name}`"))
}

fn flag_value(args: &[String], name: &str) -> Option<String> {
    args.iter()
        .position(|value| value == name)
        .and_then(|index| args.get(index + 1))
        .cloned()
}

fn has_flag(args: &[String], name: &str) -> bool {
    args.iter().any(|value| value == name)
}

fn parse_usize(value: &str, field: &str) -> Result<usize> {
    value
        .parse::<usize>()
        .with_context(|| format!("invalid `{field}`"))
}

fn parse_chat_id(value: &str) -> Result<ChatId> {
    Ok(ChatId(
        Uuid::parse_str(value).with_context(|| format!("invalid chat_id `{value}`"))?,
    ))
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::{JsonRpcRequest, make_success_response};

    #[test]
    fn json_rpc_request_schema_decodes() {
        let request: JsonRpcRequest = serde_json::from_value(json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "bot.v1.send_text",
            "params": {
                "chat_id": "3d4eb5be-4906-4459-a8be-63c9360f2d92",
                "text": "hello"
            }
        }))
        .expect("request");

        assert_eq!(request.jsonrpc, "2.0");
        assert_eq!(request.method, "bot.v1.send_text");
    }

    #[test]
    fn json_rpc_success_response_encodes() {
        let response = make_success_response(json!(7), json!({ "ok": true }));
        let value: serde_json::Value = serde_json::from_str(&response).expect("response json");
        assert_eq!(value["jsonrpc"], "2.0");
        assert_eq!(value["id"], 7);
        assert_eq!(value["result"]["ok"], true);
    }
}
