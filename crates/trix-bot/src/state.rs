use std::{
    collections::BTreeMap,
    fs::{self, File},
    path::{Path, PathBuf},
};

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use trix_types::ChatId;

#[derive(Debug, Clone)]
pub struct BotStateLayout {
    pub state_dir: PathBuf,
    pub history_store_path: PathBuf,
    pub sync_state_path: PathBuf,
    pub runtime_state_path: PathBuf,
    pub mls_storage_root: PathBuf,
    pub identity_path: PathBuf,
    pub encrypted_identity_path: PathBuf,
}

impl BotStateLayout {
    pub fn new(state_dir: impl Into<PathBuf>) -> Self {
        let state_dir = state_dir.into();
        Self {
            history_store_path: state_dir.join("history-store.json"),
            sync_state_path: state_dir.join("sync-state.json"),
            runtime_state_path: state_dir.join("runtime-state.json"),
            mls_storage_root: state_dir.join("mls"),
            identity_path: state_dir.join("identity.json"),
            encrypted_identity_path: state_dir.join("identity.enc.json"),
            state_dir,
        }
    }

    pub fn ensure_root(&self) -> Result<()> {
        fs::create_dir_all(&self.state_dir).with_context(|| {
            format!(
                "failed to create bot state directory {}",
                self.state_dir.display()
            )
        })
    }
}

#[derive(Debug, Clone)]
pub struct RuntimeState {
    path: PathBuf,
    persisted: PersistedRuntimeState,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
struct PersistedRuntimeState {
    version: u32,
    #[serde(default)]
    emitted_cursors: BTreeMap<String, u64>,
}

impl RuntimeState {
    pub fn load_or_create(path: impl Into<PathBuf>) -> Result<Self> {
        let path = path.into();
        if path.exists() {
            let file = File::open(&path)
                .with_context(|| format!("failed to open bot runtime state {}", path.display()))?;
            let persisted: PersistedRuntimeState =
                serde_json::from_reader(file).with_context(|| {
                    format!("failed to decode bot runtime state {}", path.display())
                })?;
            Ok(Self { path, persisted })
        } else {
            let state = Self {
                path,
                persisted: PersistedRuntimeState {
                    version: 1,
                    emitted_cursors: BTreeMap::new(),
                },
            };
            state.save()?;
            Ok(state)
        }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn emitted_cursor(&self, chat_id: ChatId) -> Option<u64> {
        self.persisted
            .emitted_cursors
            .get(&chat_id.0.to_string())
            .copied()
    }

    pub fn record_emitted_cursor(&mut self, chat_id: ChatId, server_seq: u64) -> Result<bool> {
        let key = chat_id.0.to_string();
        let current = self
            .persisted
            .emitted_cursors
            .get(&key)
            .copied()
            .unwrap_or_default();
        if server_seq <= current {
            return Ok(false);
        }
        self.persisted.emitted_cursors.insert(key, server_seq);
        self.save()?;
        Ok(true)
    }

    pub fn save(&self) -> Result<()> {
        if let Some(parent) = self.path.parent() {
            fs::create_dir_all(parent).with_context(|| {
                format!(
                    "failed to create parent directory for bot runtime state {}",
                    parent.display()
                )
            })?;
        }
        let file = File::create(&self.path).with_context(|| {
            format!("failed to create bot runtime state {}", self.path.display())
        })?;
        serde_json::to_writer_pretty(file, &self.persisted)
            .context("failed to persist bot runtime state")
    }
}

#[cfg(test)]
mod tests {
    use anyhow::Result;
    use trix_types::ChatId;
    use uuid::Uuid;

    use super::RuntimeState;

    #[test]
    fn runtime_state_persists_emitted_cursors() -> Result<()> {
        let path = std::env::temp_dir().join(format!("trix-bot-runtime-{}.json", Uuid::new_v4()));
        let chat_id = ChatId(Uuid::new_v4());

        let mut state = RuntimeState::load_or_create(&path)?;
        assert_eq!(state.emitted_cursor(chat_id), None);
        assert!(state.record_emitted_cursor(chat_id, 7)?);

        let restored = RuntimeState::load_or_create(&path)?;
        assert_eq!(restored.emitted_cursor(chat_id), Some(7));

        std::fs::remove_file(path).ok();
        Ok(())
    }
}
