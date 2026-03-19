use std::path::PathBuf;

#[derive(Debug, Clone)]
pub struct LocalHistoryStore {
    pub database_path: PathBuf,
}

impl LocalHistoryStore {
    pub fn new(database_path: impl Into<PathBuf>) -> Self {
        Self {
            database_path: database_path.into(),
        }
    }
}

#[derive(Debug, Clone)]
pub struct AttachmentStore {
    pub root: PathBuf,
}

impl AttachmentStore {
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }
}
