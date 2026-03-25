use std::{
    env,
    fs::{self, File},
    path::{Path, PathBuf},
};

use anyhow::{Context, Result, anyhow};
use ed25519_dalek::{Signature, Signer as _, SigningKey, Verifier as _, VerifyingKey};
use openmls::prelude::{
    BasicCredential, CredentialWithKey, GroupId, KeyPackage, KeyPackageIn, LeafNodeIndex, MlsGroup,
    MlsGroupCreateConfig, MlsGroupJoinConfig, MlsMessageBodyIn, MlsMessageIn,
    ProcessedMessageContent, ProtocolMessage, ProtocolVersion, RatchetTreeIn, StagedWelcome,
};
use openmls_basic_credential::SignatureKeyPair;
use openmls_memory_storage::MemoryStorage;
use openmls_rust_crypto::RustCrypto;
use openmls_traits::{OpenMlsProvider as _, types::Ciphersuite};
use serde::{Deserialize as SerdeDeserialize, Serialize as SerdeSerialize};
use tls_codec::{Deserialize, Serialize};

pub const DEFAULT_CIPHERSUITE: Ciphersuite =
    Ciphersuite::MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519;

#[derive(Debug, Default)]
struct TrixOpenMlsProvider {
    crypto: RustCrypto,
    key_store: MemoryStorage,
}

impl openmls_traits::OpenMlsProvider for TrixOpenMlsProvider {
    type CryptoProvider = RustCrypto;
    type RandProvider = RustCrypto;
    type StorageProvider = MemoryStorage;

    fn storage(&self) -> &Self::StorageProvider {
        &self.key_store
    }

    fn crypto(&self) -> &Self::CryptoProvider {
        &self.crypto
    }

    fn rand(&self) -> &Self::RandProvider {
        &self.crypto
    }
}

#[derive(Debug, Clone)]
struct MlsPersistencePaths {
    root: PathBuf,
    storage_file: PathBuf,
    metadata_file: PathBuf,
}

#[derive(Debug, Clone, SerdeSerialize, SerdeDeserialize)]
struct PersistedMlsMetadata {
    version: u32,
    credential_identity: Vec<u8>,
    ciphersuite: u16,
    signature_public_key: Vec<u8>,
}

#[derive(Debug, Clone)]
pub struct MlsFacadeSnapshot {
    storage_snapshot: Vec<u8>,
    metadata: PersistedMlsMetadata,
}

#[derive(Debug, Clone)]
pub struct AccountRootMaterial {
    private_key: [u8; 32],
}

impl AccountRootMaterial {
    pub fn generate() -> Self {
        Self {
            private_key: rand::random(),
        }
    }

    pub fn from_bytes(private_key: [u8; 32]) -> Self {
        Self { private_key }
    }

    pub fn private_key_bytes(&self) -> [u8; 32] {
        self.private_key
    }

    pub fn public_key_bytes(&self) -> Vec<u8> {
        self.signing_key().verifying_key().to_bytes().to_vec()
    }

    pub fn sign(&self, payload: &[u8]) -> Vec<u8> {
        self.signing_key().sign(payload).to_bytes().to_vec()
    }

    pub fn verify(&self, payload: &[u8], signature_bytes: &[u8]) -> Result<()> {
        verify_ed25519_signature(&self.public_key_bytes(), payload, signature_bytes)
    }

    fn signing_key(&self) -> SigningKey {
        SigningKey::from_bytes(&self.private_key)
    }
}

#[derive(Debug, Clone)]
pub struct DeviceKeyMaterial {
    private_key: [u8; 32],
}

impl DeviceKeyMaterial {
    pub fn generate() -> Self {
        Self {
            private_key: rand::random(),
        }
    }

    pub fn from_bytes(private_key: [u8; 32]) -> Self {
        Self { private_key }
    }

    pub fn private_key_bytes(&self) -> [u8; 32] {
        self.private_key
    }

    pub fn public_key_bytes(&self) -> Vec<u8> {
        self.signing_key().verifying_key().to_bytes().to_vec()
    }

    pub fn sign(&self, payload: &[u8]) -> Vec<u8> {
        self.signing_key().sign(payload).to_bytes().to_vec()
    }

    pub fn verify(&self, payload: &[u8], signature_bytes: &[u8]) -> Result<()> {
        verify_ed25519_signature(&self.public_key_bytes(), payload, signature_bytes)
    }

    fn signing_key(&self) -> SigningKey {
        SigningKey::from_bytes(&self.private_key)
    }
}

pub struct MlsFacade {
    provider: TrixOpenMlsProvider,
    signer: SignatureKeyPair,
    credential_with_key: CredentialWithKey,
    credential_identity: Vec<u8>,
    ciphersuite: Ciphersuite,
    persistence: Option<MlsPersistencePaths>,
}

pub struct MlsConversation {
    group: MlsGroup,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MlsMemberIdentity {
    pub leaf_index: u32,
    pub signature_key: Vec<u8>,
    pub credential_identity: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MlsCommitBundle {
    pub commit_message: Vec<u8>,
    pub welcome_message: Option<Vec<u8>>,
    pub ratchet_tree: Option<Vec<u8>>,
    pub epoch: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MlsProcessResult {
    ApplicationMessage(Vec<u8>),
    ProposalQueued,
    CommitMerged { epoch: u64 },
}

impl MlsFacade {
    pub fn new(credential_identity: impl Into<Vec<u8>>) -> Result<Self> {
        Self::with_ciphersuite(credential_identity, DEFAULT_CIPHERSUITE)
    }

    pub fn new_persistent(
        credential_identity: impl Into<Vec<u8>>,
        storage_root: impl Into<PathBuf>,
    ) -> Result<Self> {
        Self::with_ciphersuite_and_storage(credential_identity, DEFAULT_CIPHERSUITE, storage_root)
    }

    pub fn with_ciphersuite(
        credential_identity: impl Into<Vec<u8>>,
        ciphersuite: Ciphersuite,
    ) -> Result<Self> {
        let credential_identity = credential_identity.into();
        let provider = TrixOpenMlsProvider::default();
        let signer = SignatureKeyPair::new(ciphersuite.signature_algorithm())
            .context("failed to generate MLS signature key pair")?;
        signer
            .store(provider.storage())
            .context("failed to store MLS signer in key store")?;

        Self::build(provider, signer, credential_identity, ciphersuite, None)
    }

    pub fn with_ciphersuite_and_storage(
        credential_identity: impl Into<Vec<u8>>,
        ciphersuite: Ciphersuite,
        storage_root: impl Into<PathBuf>,
    ) -> Result<Self> {
        let storage_root = storage_root.into();
        let paths = MlsPersistencePaths::new(storage_root);
        if paths.metadata_file.exists() || paths.storage_file.exists() {
            return Err(anyhow!(
                "MLS persistent state already exists at {}",
                paths.root.display()
            ));
        }

        let credential_identity = credential_identity.into();
        let provider = TrixOpenMlsProvider::default();
        let signer = SignatureKeyPair::new(ciphersuite.signature_algorithm())
            .context("failed to generate MLS signature key pair")?;
        signer
            .store(provider.storage())
            .context("failed to store MLS signer in key store")?;

        let facade = Self::build(
            provider,
            signer,
            credential_identity,
            ciphersuite,
            Some(paths),
        )?;
        facade.save_state()?;
        Ok(facade)
    }

    pub fn load_persistent(storage_root: impl Into<PathBuf>) -> Result<Self> {
        let paths = MlsPersistencePaths::new(storage_root.into());
        let metadata = load_persisted_metadata(&paths)?;
        let mut storage = MemoryStorage::default();
        let storage_file = File::open(&paths.storage_file).with_context(|| {
            format!(
                "failed to open MLS storage snapshot at {}",
                paths.storage_file.display()
            )
        })?;
        storage
            .load_from_file(&storage_file)
            .map_err(|err| anyhow!("failed to load MLS storage snapshot: {err}"))?;
        let provider = TrixOpenMlsProvider {
            crypto: RustCrypto::default(),
            key_store: storage,
        };
        let ciphersuite = Ciphersuite::try_from(metadata.ciphersuite)
            .map_err(|err| anyhow!("invalid persisted MLS ciphersuite: {err}"))?;
        let signer = SignatureKeyPair::read(
            provider.storage(),
            &metadata.signature_public_key,
            ciphersuite.signature_algorithm(),
        )
        .ok_or_else(|| anyhow!("persisted MLS signer is missing from storage"))?;

        Self::build(
            provider,
            signer,
            metadata.credential_identity,
            ciphersuite,
            Some(paths),
        )
    }

    pub fn storage_root(&self) -> Option<&Path> {
        self.persistence.as_ref().map(|paths| paths.root.as_path())
    }

    pub fn snapshot_state(&self) -> Result<MlsFacadeSnapshot> {
        let snapshot_path = unique_snapshot_path("storage");
        let output_file = File::create(&snapshot_path).with_context(|| {
            format!(
                "failed to create temporary MLS snapshot file at {}",
                snapshot_path.display()
            )
        })?;
        self.provider
            .storage()
            .save_to_file(&output_file)
            .map_err(|err| anyhow!("failed to write MLS snapshot: {err}"))?;
        let storage_snapshot = fs::read(&snapshot_path).with_context(|| {
            format!(
                "failed to read temporary MLS snapshot file {}",
                snapshot_path.display()
            )
        })?;
        fs::remove_file(&snapshot_path).ok();

        Ok(MlsFacadeSnapshot {
            storage_snapshot,
            metadata: PersistedMlsMetadata {
                version: 1,
                credential_identity: self.credential_identity.clone(),
                ciphersuite: self.ciphersuite.into(),
                signature_public_key: self.signature_public_key().to_vec(),
            },
        })
    }

    pub fn restore_snapshot(&mut self, snapshot: &MlsFacadeSnapshot) -> Result<()> {
        let restored = Self::build_from_snapshot(snapshot.clone(), self.persistence.clone())?;
        *self = restored;
        self.save_state()
    }

    pub fn save_state(&self) -> Result<()> {
        let Some(paths) = &self.persistence else {
            return Ok(());
        };

        paths.ensure_root()?;
        let storage_tmp = paths.storage_tmp_file();
        let metadata_tmp = paths.metadata_tmp_file();

        {
            let output_file = File::create(&storage_tmp).with_context(|| {
                format!(
                    "failed to create temporary MLS storage snapshot at {}",
                    storage_tmp.display()
                )
            })?;
            self.provider
                .storage()
                .save_to_file(&output_file)
                .map_err(|err| anyhow!("failed to write MLS storage snapshot: {err}"))?;
        }

        let metadata = PersistedMlsMetadata {
            version: 1,
            credential_identity: self.credential_identity.clone(),
            ciphersuite: self.ciphersuite.into(),
            signature_public_key: self.signature_public_key().to_vec(),
        };
        {
            let output_file = File::create(&metadata_tmp).with_context(|| {
                format!(
                    "failed to create temporary MLS metadata snapshot at {}",
                    metadata_tmp.display()
                )
            })?;
            serde_json::to_writer_pretty(output_file, &metadata)
                .context("failed to write MLS metadata snapshot")?;
        }

        fs::rename(&storage_tmp, &paths.storage_file).with_context(|| {
            format!(
                "failed to replace MLS storage snapshot at {}",
                paths.storage_file.display()
            )
        })?;
        fs::rename(&metadata_tmp, &paths.metadata_file).with_context(|| {
            format!(
                "failed to replace MLS metadata snapshot at {}",
                paths.metadata_file.display()
            )
        })?;

        Ok(())
    }

    fn build(
        provider: TrixOpenMlsProvider,
        signer: SignatureKeyPair,
        credential_identity: Vec<u8>,
        ciphersuite: Ciphersuite,
        persistence: Option<MlsPersistencePaths>,
    ) -> Result<Self> {
        let credential = BasicCredential::new(credential_identity.clone());
        let credential_with_key = CredentialWithKey {
            credential: credential.into(),
            signature_key: signer.to_public_vec().into(),
        };

        Ok(Self {
            provider,
            signer,
            credential_with_key,
            credential_identity,
            ciphersuite,
            persistence,
        })
    }

    fn build_from_snapshot(
        snapshot: MlsFacadeSnapshot,
        persistence: Option<MlsPersistencePaths>,
    ) -> Result<Self> {
        let snapshot_path = unique_snapshot_path("restore");
        fs::write(&snapshot_path, &snapshot.storage_snapshot).with_context(|| {
            format!(
                "failed to write temporary MLS restore snapshot {}",
                snapshot_path.display()
            )
        })?;
        let storage_file = File::open(&snapshot_path).with_context(|| {
            format!(
                "failed to open temporary MLS restore snapshot {}",
                snapshot_path.display()
            )
        })?;
        let mut storage = MemoryStorage::default();
        storage
            .load_from_file(&storage_file)
            .map_err(|err| anyhow!("failed to load MLS restore snapshot: {err}"))?;
        fs::remove_file(&snapshot_path).ok();

        let provider = TrixOpenMlsProvider {
            crypto: RustCrypto::default(),
            key_store: storage,
        };
        let ciphersuite = Ciphersuite::try_from(snapshot.metadata.ciphersuite)
            .map_err(|err| anyhow!("invalid MLS snapshot ciphersuite: {err}"))?;
        let signer = SignatureKeyPair::read(
            provider.storage(),
            &snapshot.metadata.signature_public_key,
            ciphersuite.signature_algorithm(),
        )
        .ok_or_else(|| anyhow!("MLS snapshot signer is missing from storage"))?;

        Self::build(
            provider,
            signer,
            snapshot.metadata.credential_identity,
            ciphersuite,
            persistence,
        )
    }

    fn persist_if_needed(&self) -> Result<()> {
        self.save_state()
    }

    pub fn ciphersuite(&self) -> Ciphersuite {
        self.ciphersuite
    }

    pub fn ciphersuite_label(&self) -> String {
        format!("{:?}", self.ciphersuite)
    }

    pub fn credential_identity(&self) -> &[u8] {
        &self.credential_identity
    }

    pub fn signature_public_key(&self) -> &[u8] {
        self.credential_with_key.signature_key.as_slice()
    }

    pub fn generate_key_package(&self) -> Result<Vec<u8>> {
        let bundle = KeyPackage::builder()
            .build(
                self.ciphersuite,
                &self.provider,
                &self.signer,
                self.credential_with_key.clone(),
            )
            .context("failed to build MLS key package")?;
        let key_package = bundle
            .key_package()
            .tls_serialize_detached()
            .context("failed to serialize MLS key package")?;
        self.persist_if_needed()?;
        Ok(key_package)
    }

    pub fn generate_key_packages(&self, count: usize) -> Result<Vec<Vec<u8>>> {
        (0..count).map(|_| self.generate_key_package()).collect()
    }

    pub fn create_group(&self, group_id: impl AsRef<[u8]>) -> Result<MlsConversation> {
        let config = default_group_create_config(self.ciphersuite);
        let group = MlsGroup::new_with_group_id(
            &self.provider,
            &self.signer,
            &config,
            GroupId::from_slice(group_id.as_ref()),
            self.credential_with_key.clone(),
        )
        .context("failed to create MLS group")?;
        self.persist_if_needed()?;
        Ok(MlsConversation { group })
    }

    pub fn load_group(&self, group_id: impl AsRef<[u8]>) -> Result<Option<MlsConversation>> {
        let group = MlsGroup::load(
            self.provider.storage(),
            &GroupId::from_slice(group_id.as_ref()),
        )
        .context("failed to load MLS group from storage")?;

        Ok(group.map(|group| MlsConversation { group }))
    }

    pub fn join_group_from_welcome(
        &self,
        welcome_message: &[u8],
        ratchet_tree: Option<&[u8]>,
    ) -> Result<MlsConversation> {
        let welcome_message = MlsMessageIn::tls_deserialize_exact(welcome_message)
            .context("failed to deserialize MLS welcome message")?;
        let welcome = match welcome_message.extract() {
            MlsMessageBodyIn::Welcome(welcome) => welcome,
            _ => return Err(anyhow!("MLS message is not a welcome")),
        };
        let ratchet_tree = ratchet_tree
            .map(deserialize_ratchet_tree)
            .transpose()
            .context("failed to deserialize ratchet tree")?;
        let join_config = default_group_join_config();
        let group =
            StagedWelcome::new_from_welcome(&self.provider, &join_config, welcome, ratchet_tree)
                .context("failed to stage MLS welcome")?
                .into_group(&self.provider)
                .context("failed to create MLS group from welcome")?;
        self.persist_if_needed()?;
        Ok(MlsConversation { group })
    }

    pub fn add_members(
        &self,
        conversation: &mut MlsConversation,
        key_packages: &[Vec<u8>],
    ) -> Result<MlsCommitBundle> {
        let key_packages = key_packages
            .iter()
            .map(|bytes| deserialize_key_package(&self.provider, bytes))
            .collect::<Result<Vec<_>>>()?;

        let (commit, welcome, _) = conversation
            .group
            .add_members(&self.provider, &self.signer, &key_packages)
            .context("failed to add members to MLS group")?;
        conversation
            .group
            .merge_pending_commit(&self.provider)
            .context("failed to merge local add-members commit")?;
        self.persist_if_needed()?;

        Ok(MlsCommitBundle {
            commit_message: commit.to_bytes().context("failed to serialize commit")?,
            welcome_message: Some(
                welcome
                    .to_bytes()
                    .context("failed to serialize welcome message")?,
            ),
            ratchet_tree: Some(export_ratchet_tree(&conversation.group)?),
            epoch: conversation.group.epoch().as_u64(),
        })
    }

    pub fn remove_members(
        &self,
        conversation: &mut MlsConversation,
        leaf_indices: &[u32],
    ) -> Result<MlsCommitBundle> {
        let leaf_indices = leaf_indices
            .iter()
            .map(|index| LeafNodeIndex::new(*index))
            .collect::<Vec<_>>();
        let (commit, _, _) = conversation
            .group
            .remove_members(&self.provider, &self.signer, &leaf_indices)
            .context("failed to remove members from MLS group")?;
        conversation
            .group
            .merge_pending_commit(&self.provider)
            .context("failed to merge local remove-members commit")?;
        self.persist_if_needed()?;

        Ok(MlsCommitBundle {
            commit_message: commit.to_bytes().context("failed to serialize commit")?,
            welcome_message: None,
            ratchet_tree: Some(export_ratchet_tree(&conversation.group)?),
            epoch: conversation.group.epoch().as_u64(),
        })
    }

    pub fn self_update(&self, conversation: &mut MlsConversation) -> Result<MlsCommitBundle> {
        let commit = conversation
            .group
            .self_update(&self.provider, &self.signer, Default::default())
            .context("failed to create self-update commit")?
            .into_commit();
        conversation
            .group
            .merge_pending_commit(&self.provider)
            .context("failed to merge local self-update commit")?;
        self.persist_if_needed()?;

        Ok(MlsCommitBundle {
            commit_message: commit.to_bytes().context("failed to serialize commit")?,
            welcome_message: None,
            ratchet_tree: Some(export_ratchet_tree(&conversation.group)?),
            epoch: conversation.group.epoch().as_u64(),
        })
    }

    pub fn create_application_message(
        &self,
        conversation: &mut MlsConversation,
        plaintext: &[u8],
    ) -> Result<Vec<u8>> {
        let message = conversation
            .group
            .create_message(&self.provider, &self.signer, plaintext)
            .context("failed to create MLS application message")?
            .to_bytes()
            .context("failed to serialize MLS application message")?;
        self.persist_if_needed()?;
        Ok(message)
    }

    pub fn process_message(
        &self,
        conversation: &mut MlsConversation,
        message_bytes: &[u8],
    ) -> Result<MlsProcessResult> {
        let message = MlsMessageIn::tls_deserialize_exact(message_bytes)
            .context("failed to deserialize MLS message")?;
        let protocol_message: ProtocolMessage = match message.extract() {
            MlsMessageBodyIn::PrivateMessage(message) => message.into(),
            MlsMessageBodyIn::PublicMessage(message) => message.into(),
            _ => return Err(anyhow!("MLS message is not a protocol message")),
        };
        let processed = conversation
            .group
            .process_message(&self.provider, protocol_message)
            .context("failed to process MLS message")?;

        let result = match processed.into_content() {
            ProcessedMessageContent::ApplicationMessage(message) => {
                MlsProcessResult::ApplicationMessage(message.into_bytes())
            }
            ProcessedMessageContent::ProposalMessage(proposal) => {
                conversation
                    .group
                    .store_pending_proposal(self.provider.storage(), *proposal)
                    .context("failed to store MLS proposal")?;
                MlsProcessResult::ProposalQueued
            }
            ProcessedMessageContent::ExternalJoinProposalMessage(proposal) => {
                conversation
                    .group
                    .store_pending_proposal(self.provider.storage(), *proposal)
                    .context("failed to store external MLS join proposal")?;
                MlsProcessResult::ProposalQueued
            }
            ProcessedMessageContent::StagedCommitMessage(staged_commit) => {
                conversation
                    .group
                    .merge_staged_commit(&self.provider, *staged_commit)
                    .context("failed to merge staged MLS commit")?;
                MlsProcessResult::CommitMerged {
                    epoch: conversation.group.epoch().as_u64(),
                }
            }
        };
        self.persist_if_needed()?;
        Ok(result)
    }

    pub fn export_secret(
        &self,
        conversation: &MlsConversation,
        label: &str,
        context: &[u8],
        len: usize,
    ) -> Result<Vec<u8>> {
        conversation
            .group
            .export_secret(self.provider.crypto(), label, context, len)
            .context("failed to export MLS secret")
    }

    pub fn members(&self, conversation: &MlsConversation) -> Result<Vec<MlsMemberIdentity>> {
        conversation
            .group
            .members()
            .map(|member| {
                let credential = BasicCredential::try_from(member.credential.clone())
                    .map_err(|err| anyhow!("failed to read member basic credential: {err}"))?;
                Ok(MlsMemberIdentity {
                    leaf_index: member.index.u32(),
                    signature_key: member.signature_key,
                    credential_identity: credential.identity().to_vec(),
                })
            })
            .collect()
    }
}

impl MlsConversation {
    pub fn group_id(&self) -> Vec<u8> {
        self.group.group_id().to_vec()
    }

    pub fn epoch(&self) -> u64 {
        self.group.epoch().as_u64()
    }

    pub fn export_ratchet_tree(&self) -> Result<Vec<u8>> {
        export_ratchet_tree(&self.group)
    }
}

impl MlsPersistencePaths {
    fn new(root: PathBuf) -> Self {
        Self {
            storage_file: root.join("storage.json"),
            metadata_file: root.join("metadata.json"),
            root,
        }
    }

    fn ensure_root(&self) -> Result<()> {
        fs::create_dir_all(&self.root)
            .with_context(|| format!("failed to create MLS storage root {}", self.root.display()))
    }

    fn storage_tmp_file(&self) -> PathBuf {
        self.root
            .join(format!(".storage.json.{}.tmp", uuid::Uuid::new_v4()))
    }

    fn metadata_tmp_file(&self) -> PathBuf {
        self.root
            .join(format!(".metadata.json.{}.tmp", uuid::Uuid::new_v4()))
    }
}

fn load_persisted_metadata(paths: &MlsPersistencePaths) -> Result<PersistedMlsMetadata> {
    let input_file = File::open(&paths.metadata_file).with_context(|| {
        format!(
            "failed to open MLS metadata snapshot at {}",
            paths.metadata_file.display()
        )
    })?;
    let metadata: PersistedMlsMetadata =
        serde_json::from_reader(input_file).context("failed to parse MLS metadata snapshot")?;
    if metadata.version != 1 {
        return Err(anyhow!(
            "unsupported MLS metadata snapshot version {}",
            metadata.version
        ));
    }
    Ok(metadata)
}

fn unique_snapshot_path(kind: &str) -> PathBuf {
    env::temp_dir().join(format!("trix-mls-{kind}-{}.bin", uuid::Uuid::new_v4()))
}

fn default_group_create_config(ciphersuite: Ciphersuite) -> MlsGroupCreateConfig {
    MlsGroupCreateConfig::builder()
        .ciphersuite(ciphersuite)
        .use_ratchet_tree_extension(true)
        .build()
}

fn default_group_join_config() -> MlsGroupJoinConfig {
    MlsGroupJoinConfig::builder()
        .use_ratchet_tree_extension(true)
        .build()
}

fn deserialize_key_package(
    provider: &TrixOpenMlsProvider,
    bytes: &[u8],
) -> Result<openmls::prelude::KeyPackage> {
    let key_package_in = KeyPackageIn::tls_deserialize_exact(bytes)
        .context("failed to deserialize MLS key package")?;
    key_package_in
        .validate(provider.crypto(), ProtocolVersion::Mls10)
        .context("failed to validate MLS key package")
}

fn deserialize_ratchet_tree(bytes: &[u8]) -> Result<RatchetTreeIn> {
    RatchetTreeIn::tls_deserialize_exact(bytes).context("failed to deserialize MLS ratchet tree")
}

fn export_ratchet_tree(group: &MlsGroup) -> Result<Vec<u8>> {
    group
        .export_ratchet_tree()
        .tls_serialize_detached()
        .context("failed to serialize MLS ratchet tree")
}

fn verify_ed25519_signature(
    public_key: &[u8],
    payload: &[u8],
    signature_bytes: &[u8],
) -> Result<()> {
    let public_key: [u8; 32] = public_key
        .try_into()
        .map_err(|_| anyhow!("ed25519 public key must be 32 bytes"))?;
    let verifying_key =
        VerifyingKey::from_bytes(&public_key).context("invalid ed25519 public key")?;
    let signature =
        Signature::from_slice(signature_bytes).context("invalid ed25519 signature length")?;

    verifying_key
        .verify(payload, &signature)
        .context("ed25519 signature verification failed")
}

#[cfg(test)]
mod tests {
    use std::{env, fs};

    use uuid::Uuid;

    use super::{AccountRootMaterial, DeviceKeyMaterial, MlsFacade, MlsProcessResult};

    #[test]
    fn device_and_account_keys_sign_and_verify() {
        let account_root = AccountRootMaterial::generate();
        let device_keys = DeviceKeyMaterial::generate();
        let payload = b"trix-test-payload";

        let account_signature = account_root.sign(payload);
        let device_signature = device_keys.sign(payload);

        account_root.verify(payload, &account_signature).unwrap();
        device_keys.verify(payload, &device_signature).unwrap();
    }

    #[test]
    fn mls_facade_add_member_and_exchange_messages() {
        let alice = MlsFacade::new(b"alice-device".to_vec()).unwrap();
        let bob = MlsFacade::new(b"bob-device".to_vec()).unwrap();

        let bob_key_package = bob.generate_key_package().unwrap();
        let mut alice_group = alice.create_group(b"chat-1".as_slice()).unwrap();
        let add_bundle = alice
            .add_members(&mut alice_group, &[bob_key_package])
            .unwrap();

        let mut bob_group = bob
            .join_group_from_welcome(
                add_bundle.welcome_message.as_ref().unwrap(),
                add_bundle.ratchet_tree.as_deref(),
            )
            .unwrap();

        let alice_ciphertext = alice
            .create_application_message(&mut alice_group, b"hello bob")
            .unwrap();
        let processed = bob
            .process_message(&mut bob_group, &alice_ciphertext)
            .unwrap();
        assert_eq!(
            processed,
            MlsProcessResult::ApplicationMessage(b"hello bob".to_vec())
        );

        let bob_ciphertext = bob
            .create_application_message(&mut bob_group, b"hello alice")
            .unwrap();
        let processed = alice
            .process_message(&mut alice_group, &bob_ciphertext)
            .unwrap();
        assert_eq!(
            processed,
            MlsProcessResult::ApplicationMessage(b"hello alice".to_vec())
        );

        let alice_members = alice.members(&alice_group).unwrap();
        assert_eq!(alice_members.len(), 2);
        assert!(
            alice_members
                .iter()
                .any(|member| member.credential_identity == b"alice-device".to_vec())
        );
        assert!(
            alice_members
                .iter()
                .any(|member| member.credential_identity == b"bob-device".to_vec())
        );
    }

    #[test]
    fn mls_facade_persists_state_across_restart() {
        let storage_root = env::temp_dir().join(format!("trix-mls-{}", Uuid::new_v4()));
        let bob = MlsFacade::new(b"bob-device".to_vec()).unwrap();
        let alice = MlsFacade::new_persistent(b"alice-device".to_vec(), &storage_root).unwrap();

        let bob_key_package = bob.generate_key_package().unwrap();
        let mut alice_group = alice.create_group(b"chat-persist".as_slice()).unwrap();
        let add_bundle = alice
            .add_members(&mut alice_group, &[bob_key_package])
            .unwrap();
        let mut bob_group = bob
            .join_group_from_welcome(
                add_bundle.welcome_message.as_ref().unwrap(),
                add_bundle.ratchet_tree.as_deref(),
            )
            .unwrap();

        let restored_alice = MlsFacade::load_persistent(&storage_root).unwrap();
        let mut restored_group = restored_alice
            .load_group(b"chat-persist".as_slice())
            .unwrap()
            .expect("persisted group should be present");

        let ciphertext = restored_alice
            .create_application_message(&mut restored_group, b"after restart")
            .unwrap();
        let processed = bob.process_message(&mut bob_group, &ciphertext).unwrap();
        assert_eq!(
            processed,
            MlsProcessResult::ApplicationMessage(b"after restart".to_vec())
        );

        fs::remove_dir_all(storage_root).ok();
    }

    #[test]
    fn mls_facade_can_restore_snapshot_after_local_mutation() {
        let mut alice = MlsFacade::new(b"alice-device".to_vec()).unwrap();
        let bob = MlsFacade::new(b"bob-device".to_vec()).unwrap();
        let snapshot = alice.snapshot_state().unwrap();

        let bob_key_package = bob.generate_key_package().unwrap();
        let mut alice_group = alice.create_group(b"chat-rollback".as_slice()).unwrap();
        alice
            .add_members(&mut alice_group, &[bob_key_package])
            .expect("local mutation succeeds");

        assert!(
            alice
                .load_group(b"chat-rollback".as_slice())
                .unwrap()
                .is_some()
        );

        alice.restore_snapshot(&snapshot).unwrap();
        assert!(
            alice
                .load_group(b"chat-rollback".as_slice())
                .unwrap()
                .is_none()
        );
    }

    #[test]
    fn mls_facade_can_remove_readded_member_after_persistent_reload() {
        let storage_root =
            env::temp_dir().join(format!("trix-mls-remove-readd-{}", Uuid::new_v4()));
        let alice = MlsFacade::new_persistent(b"alice-device".to_vec(), &storage_root).unwrap();
        let bob = MlsFacade::new(b"bob-device".to_vec()).unwrap();
        let charlie = MlsFacade::new(b"charlie-device".to_vec()).unwrap();

        let mut alice_group = alice.create_group(b"chat-remove-readd".as_slice()).unwrap();
        let bob_key_package = bob.generate_key_package().unwrap();
        alice
            .add_members(&mut alice_group, &[bob_key_package])
            .unwrap();

        let bob_leaf = alice
            .members(&alice_group)
            .unwrap()
            .into_iter()
            .find(|member| member.credential_identity == b"bob-device".to_vec())
            .map(|member| member.leaf_index)
            .expect("bob leaf should exist");
        alice.remove_members(&mut alice_group, &[bob_leaf]).unwrap();
        alice.save_state().unwrap();

        let reloaded_alice = MlsFacade::load_persistent(&storage_root).unwrap();
        let mut reloaded_group = reloaded_alice
            .load_group(b"chat-remove-readd".as_slice())
            .unwrap()
            .expect("persisted group should be present");
        let charlie_key_package = charlie.generate_key_package().unwrap();
        reloaded_alice
            .add_members(&mut reloaded_group, &[charlie_key_package])
            .unwrap();
        reloaded_alice.save_state().unwrap();

        let reloaded_again = MlsFacade::load_persistent(&storage_root).unwrap();
        let mut reloaded_again_group = reloaded_again
            .load_group(b"chat-remove-readd".as_slice())
            .unwrap()
            .expect("reloaded group should be present");
        let charlie_leaf = reloaded_again
            .members(&reloaded_again_group)
            .unwrap()
            .into_iter()
            .find(|member| member.credential_identity == b"charlie-device".to_vec())
            .map(|member| member.leaf_index)
            .expect("charlie leaf should exist");
        reloaded_again
            .remove_members(&mut reloaded_again_group, &[charlie_leaf])
            .unwrap();

        fs::remove_dir_all(storage_root).ok();
    }

    #[test]
    fn mls_facade_member_can_process_add_commit_after_persistent_reload() {
        let storage_root =
            env::temp_dir().join(format!("trix-mls-member-reload-{}", Uuid::new_v4()));
        let alice = MlsFacade::new(b"alice-device".to_vec()).unwrap();
        let bob = MlsFacade::new_persistent(b"bob-device".to_vec(), &storage_root).unwrap();
        let charlie = MlsFacade::new(b"charlie-device".to_vec()).unwrap();

        let bob_key_package = bob.generate_key_package().unwrap();
        let mut alice_group = alice
            .create_group(b"chat-member-reload".as_slice())
            .unwrap();
        let add_bob_bundle = alice
            .add_members(&mut alice_group, &[bob_key_package])
            .unwrap();
        let _bob_group = bob
            .join_group_from_welcome(
                add_bob_bundle.welcome_message.as_ref().unwrap(),
                add_bob_bundle.ratchet_tree.as_deref(),
            )
            .unwrap();

        let reloaded_bob = MlsFacade::load_persistent(&storage_root).unwrap();
        let mut reloaded_bob_group = reloaded_bob
            .load_group(b"chat-member-reload".as_slice())
            .unwrap()
            .expect("persisted bob group should be present");

        let charlie_key_package = charlie.generate_key_package().unwrap();
        let add_charlie_bundle = alice
            .add_members(&mut alice_group, &[charlie_key_package])
            .unwrap();

        let processed = reloaded_bob
            .process_message(&mut reloaded_bob_group, &add_charlie_bundle.commit_message)
            .unwrap();
        assert_eq!(
            processed,
            MlsProcessResult::CommitMerged {
                epoch: add_charlie_bundle.epoch
            }
        );

        fs::remove_dir_all(storage_root).ok();
    }
}
