use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail, ensure};
use sha2::{Digest, Sha256};
use tokio::fs;
use uuid::Uuid;

#[derive(Debug, Clone)]
pub struct LocalBlobStore {
    root: PathBuf,
}

#[derive(Debug, Clone)]
pub struct StoredBlob {
    pub relative_path: String,
    pub size_bytes: u64,
}

impl LocalBlobStore {
    pub fn new(root: impl Into<PathBuf>) -> Result<Self> {
        let root = root.into();
        std::fs::create_dir_all(root.join("sha256"))?;
        std::fs::create_dir_all(root.join("tmp"))?;
        Ok(Self { root })
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn blob_id_from_sha256(sha256: &[u8]) -> Result<String> {
        ensure!(
            sha256.len() == 32,
            "sha256 must contain exactly 32 bytes, got {}",
            sha256.len()
        );

        Ok(hex_encode(sha256))
    }

    pub fn relative_path_for_blob_id(blob_id: &str) -> Result<String> {
        validate_blob_id(blob_id)?;
        Ok(format!(
            "sha256/{}/{}/{}.blob",
            &blob_id[0..2],
            &blob_id[2..4],
            blob_id
        ))
    }

    pub async fn put_bytes(&self, blob_id: &str, bytes: &[u8]) -> Result<StoredBlob> {
        validate_blob_id(blob_id)?;

        let computed_blob_id = hex_encode(Sha256::digest(bytes).as_slice());
        ensure!(
            computed_blob_id == blob_id,
            "blob contents sha256 does not match blob_id"
        );

        let relative_path = Self::relative_path_for_blob_id(blob_id)?;
        let final_path = self.root.join(&relative_path);
        if fs::try_exists(&final_path)
            .await
            .with_context(|| format!("failed to check blob path {}", final_path.display()))?
        {
            return Ok(StoredBlob {
                relative_path,
                size_bytes: bytes.len() as u64,
            });
        }

        if let Some(parent) = final_path.parent() {
            fs::create_dir_all(parent)
                .await
                .with_context(|| format!("failed to create blob directory {}", parent.display()))?;
        }

        let tmp_path = self
            .root
            .join("tmp")
            .join(format!("{blob_id}.{}.upload", Uuid::new_v4()));
        fs::write(&tmp_path, bytes)
            .await
            .with_context(|| format!("failed to write temp blob {}", tmp_path.display()))?;

        fs::rename(&tmp_path, &final_path).await.with_context(|| {
            format!(
                "failed to move temp blob {} into {}",
                tmp_path.display(),
                final_path.display()
            )
        })?;

        Ok(StoredBlob {
            relative_path,
            size_bytes: bytes.len() as u64,
        })
    }

    pub async fn get_bytes(&self, blob_id: &str) -> Result<Vec<u8>> {
        let path = self.blob_path(blob_id)?;
        fs::read(&path)
            .await
            .with_context(|| format!("failed to read blob {}", path.display()))
    }

    pub async fn exists(&self, blob_id: &str) -> Result<bool> {
        let path = self.blob_path(blob_id)?;
        fs::try_exists(&path)
            .await
            .with_context(|| format!("failed to stat blob {}", path.display()))
    }

    pub async fn delete_if_exists(&self, blob_id: &str) -> Result<()> {
        let path = self.blob_path(blob_id)?;
        if fs::try_exists(&path)
            .await
            .with_context(|| format!("failed to stat blob {}", path.display()))?
        {
            fs::remove_file(&path)
                .await
                .with_context(|| format!("failed to delete blob {}", path.display()))?;
        }
        Ok(())
    }

    fn blob_path(&self, blob_id: &str) -> Result<PathBuf> {
        Ok(self.root.join(Self::relative_path_for_blob_id(blob_id)?))
    }
}

fn validate_blob_id(blob_id: &str) -> Result<()> {
    if blob_id.len() != 64 {
        bail!("blob_id must be a 64-character sha256 hex string");
    }
    if !blob_id
        .as_bytes()
        .iter()
        .all(|byte| byte.is_ascii_hexdigit())
    {
        bail!("blob_id must be a lowercase sha256 hex string");
    }
    Ok(())
}

fn hex_encode(bytes: impl AsRef<[u8]>) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";

    let bytes = bytes.as_ref();
    let mut output = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        output.push(HEX[(byte >> 4) as usize] as char);
        output.push(HEX[(byte & 0x0f) as usize] as char);
    }
    output
}
