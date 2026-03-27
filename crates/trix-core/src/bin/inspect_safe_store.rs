use anyhow::{Context, Result, anyhow};
use serde::Deserialize;
use std::{
    collections::{BTreeMap, BTreeSet},
    fs,
    path::Path,
};
use trix_core::{LocalHistoryStore, MlsFacade};
use trix_types::ChatId;
use uuid::Uuid;

fn main() -> Result<()> {
    let mut args = std::env::args().skip(1);
    let root_path = args
        .next()
        .context(
            "usage: inspect_safe_store <root_path> <database_key_b64> [chat_id] [after_server_seq] [limit]",
        )?;
    let database_key_b64 = args
        .next()
        .context(
            "usage: inspect_safe_store <root_path> <database_key_b64> [chat_id] [after_server_seq] [limit]",
        )?;
    let chat_id = args
        .next()
        .map(|value| Uuid::parse_str(&value).map(ChatId))
        .transpose()?;
    let after_server_seq = args
        .next()
        .map(|value| {
            value
                .parse::<u64>()
                .context("after_server_seq must be an integer")
        })
        .transpose()?;
    let limit = args
        .next()
        .map(|value| value.parse::<usize>().context("limit must be an integer"))
        .transpose()?;

    let database_key =
        base64::Engine::decode(&base64::engine::general_purpose::STANDARD, database_key_b64)?;

    let root = std::path::PathBuf::from(&root_path);
    let database_path = root.join("client-store.sqlite");
    let mls_root = root.join("mls");

    let mut store = LocalHistoryStore::new_encrypted(&database_path, database_key.clone())?;
    println!("database_path={}", database_path.display());
    println!("mls_root={}", mls_root.display());
    let chats = store.list_chats();
    println!("chat_count={}", chats.len());
    if chat_id.is_none() {
        for chat in chats {
            println!(
                "chat id={} type={:?} title={:?} last_seq={} epoch={} projected_cursor={:?} group={:?}",
                chat.chat_id.0,
                chat.chat_type,
                chat.title,
                chat.last_server_seq,
                chat.epoch,
                store.projected_cursor(chat.chat_id),
                store
                    .chat_mls_group_id(chat.chat_id)
                    .as_deref()
                    .map(trix_core::encode_b64),
            );
            let timeline = store.get_local_timeline_items(chat.chat_id, None, None, None);
            for item in timeline
                .iter()
                .rev()
                .take(8)
                .collect::<Vec<_>>()
                .into_iter()
                .rev()
            {
                println!(
                    "  timeline seq={} kind={:?} content={:?} projection={:?} outgoing={} preview={:?} body={} parse_error={:?}",
                    item.server_seq,
                    item.message_kind,
                    item.content_type,
                    item.projection_kind,
                    item.is_outgoing,
                    item.preview_text,
                    summarize_body(item.body.as_ref()),
                    item.body_parse_error,
                );
            }
        }
        return Ok(());
    }
    let chat_id = chat_id.expect("checked above");
    println!("target_chat={}", chat_id.0);
    println!(
        "target_mapping_before={:?}",
        store
            .chat_mls_group_id(chat_id)
            .as_deref()
            .map(trix_core::encode_b64)
    );
    println!("target_cursor_before={:?}", store.projected_cursor(chat_id));

    let history = store.get_chat_history(chat_id, None, Some(10));
    println!("target_message_count={}", history.messages.len());
    for message in history.messages.iter().take(10) {
        println!(
            "  seq={} kind={:?} content={:?} message_id={}",
            message.server_seq, message.message_kind, message.content_type, message.message_id.0
        );
    }
    let timeline_before = store.get_local_timeline_items(chat_id, None, after_server_seq, limit);
    println!("timeline_before_count={}", timeline_before.len());
    for item in &timeline_before {
        println!(
            "  timeline_before seq={} kind={:?} content={:?} projection={:?} outgoing={} preview={:?} body={} parse_error={:?}",
            item.server_seq,
            item.message_kind,
            item.content_type,
            item.projection_kind,
            item.is_outgoing,
            item.preview_text,
            summarize_body(item.body.as_ref()),
            item.body_parse_error,
        );
    }

    let facade = MlsFacade::load_persistent(&mls_root)?;
    match store.project_chat_with_facade(chat_id, &facade, Some(1)) {
        Ok(report) => {
            println!("project_report={report:?}");
            println!(
                "target_mapping_after={:?}",
                store
                    .chat_mls_group_id(chat_id)
                    .as_deref()
                    .map(trix_core::encode_b64)
            );
            println!("target_cursor_after={:?}", store.projected_cursor(chat_id));
            let timeline_after =
                store.get_local_timeline_items(chat_id, None, after_server_seq, limit);
            println!("timeline_after_count={}", timeline_after.len());
            for item in &timeline_after {
                println!(
                    "  timeline_after seq={} kind={:?} content={:?} projection={:?} outgoing={} preview={:?} body={} parse_error={:?}",
                    item.server_seq,
                    item.message_kind,
                    item.content_type,
                    item.projection_kind,
                    item.is_outgoing,
                    item.preview_text,
                    summarize_body(item.body.as_ref()),
                    item.body_parse_error,
                );
            }
        }
        Err(error) => {
            println!("project_error={error:#}");
            println!(
                "target_mapping_after_error={:?}",
                store
                    .chat_mls_group_id(chat_id)
                    .as_deref()
                    .map(trix_core::encode_b64)
            );
            println!(
                "target_cursor_after_error={:?}",
                store.projected_cursor(chat_id)
            );
        }
    }

    let persisted_group_ids = persisted_group_ids_from_storage_root(&mls_root)?;
    println!("persisted_group_ids={}", persisted_group_ids.len());
    for group_id in &persisted_group_ids {
        println!("  persisted_group_id={}", trix_core::encode_b64(group_id));
    }
    drop(store);

    for group_id in persisted_group_ids {
        let mut forced_store =
            LocalHistoryStore::new_encrypted(&database_path, database_key.clone())?;
        forced_store.set_chat_mls_group_id(chat_id, &group_id)?;
        let facade = MlsFacade::load_persistent(&mls_root)?;
        println!("forced_group_attempt={}", trix_core::encode_b64(&group_id));
        match forced_store.project_chat_with_facade(chat_id, &facade, Some(1)) {
            Ok(report) => {
                println!("forced_project_report={report:?}");
                println!(
                    "forced_mapping_after={:?}",
                    forced_store
                        .chat_mls_group_id(chat_id)
                        .as_deref()
                        .map(trix_core::encode_b64)
                );
                println!(
                    "forced_cursor_after={:?}",
                    forced_store.projected_cursor(chat_id)
                );
            }
            Err(error) => {
                println!("forced_project_error={error:#}");
                println!(
                    "forced_mapping_after_error={:?}",
                    forced_store
                        .chat_mls_group_id(chat_id)
                        .as_deref()
                        .map(trix_core::encode_b64)
                );
                println!(
                    "forced_cursor_after_error={:?}",
                    forced_store.projected_cursor(chat_id)
                );
            }
        }
    }

    Ok(())
}

fn summarize_body(body: Option<&trix_core::MessageBody>) -> String {
    match body {
        Some(trix_core::MessageBody::Text(value)) => format!("Text({:?})", value.text),
        Some(trix_core::MessageBody::Reaction(value)) => format!(
            "Reaction(target={}, emoji={:?}, action={:?})",
            value.target_message_id.0, value.emoji, value.action
        ),
        Some(trix_core::MessageBody::Receipt(value)) => format!(
            "Receipt(target={}, type={:?}, at={:?})",
            value.target_message_id.0, value.receipt_type, value.at_unix
        ),
        Some(trix_core::MessageBody::Attachment(value)) => format!(
            "Attachment(mime={:?}, file_name={:?}, size={})",
            value.mime_type, value.file_name, value.size_bytes
        ),
        Some(trix_core::MessageBody::ChatEvent(value)) => {
            format!("ChatEvent(type={:?})", value.event_type)
        }
        None => "None".to_owned(),
    }
}

#[derive(Debug, Deserialize)]
struct PersistedMlsStorageSnapshot {
    values: BTreeMap<String, String>,
}

#[derive(Debug, Deserialize)]
struct PersistedMlsGroupContext {
    #[serde(rename = "group_id")]
    group_id: PersistedMlsByteVecWrapper,
}

#[derive(Debug, Deserialize)]
struct PersistedMlsByteVecWrapper {
    value: PersistedMlsByteVec,
}

#[derive(Debug, Deserialize)]
struct PersistedMlsByteVec {
    vec: Vec<u8>,
}

fn persisted_group_ids_from_storage_root(storage_root: &Path) -> Result<Vec<Vec<u8>>> {
    let storage_file = storage_root.join("storage.json");
    if !storage_file.exists() {
        return Ok(Vec::new());
    }

    let content = fs::read_to_string(&storage_file).with_context(|| {
        format!(
            "failed to read persisted MLS storage snapshot {}",
            storage_file.display()
        )
    })?;
    let snapshot: PersistedMlsStorageSnapshot =
        serde_json::from_str(&content).with_context(|| {
            format!(
                "failed to parse persisted MLS storage snapshot {}",
                storage_file.display()
            )
        })?;

    let mut group_ids = Vec::new();
    let mut seen = BTreeSet::new();
    for (key_b64, value_b64) in snapshot.values {
        let key = decode_b64(&key_b64).context("failed to decode persisted MLS storage key")?;
        if !key
            .windows(b"GroupContext".len())
            .any(|window| window == b"GroupContext")
        {
            continue;
        }

        let value =
            decode_b64(&value_b64).context("failed to decode persisted MLS storage value")?;
        let context: PersistedMlsGroupContext = serde_json::from_slice(&value)
            .context("failed to decode persisted MLS group context")?;
        let marker = trix_core::encode_b64(&context.group_id.value.vec);
        if seen.insert(marker) {
            group_ids.push(context.group_id.value.vec);
        }
    }

    Ok(group_ids)
}

fn decode_b64(value: &str) -> Result<Vec<u8>> {
    base64::Engine::decode(&base64::engine::general_purpose::STANDARD, value)
        .map_err(|err| anyhow!("invalid base64: {err}"))
}
