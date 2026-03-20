use std::path::PathBuf;

#[derive(Debug, Clone)]
pub struct CoreConfig {
    pub database_path: PathBuf,
    pub attachment_cache_root: PathBuf,
    pub mls_storage_root: PathBuf,
}

impl Default for CoreConfig {
    fn default() -> Self {
        Self {
            database_path: PathBuf::from("trix-client.db"),
            attachment_cache_root: PathBuf::from("attachments"),
            mls_storage_root: PathBuf::from("mls"),
        }
    }
}
