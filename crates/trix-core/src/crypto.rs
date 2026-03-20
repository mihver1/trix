use anyhow::{Context, Result, anyhow};
use ed25519_dalek::{Signature, Signer as _, SigningKey, Verifier as _, VerifyingKey};
use openmls::prelude::{
    BasicCredential, CredentialWithKey, GroupId, KeyPackage, KeyPackageIn, LeafNodeIndex, MlsGroup,
    MlsGroupCreateConfig, MlsGroupJoinConfig, MlsMessageBodyIn, MlsMessageIn,
    ProcessedMessageContent, ProtocolMessage, ProtocolVersion, RatchetTreeIn, StagedWelcome,
};
use openmls_basic_credential::SignatureKeyPair;
use openmls_rust_crypto::OpenMlsRustCrypto;
use openmls_traits::{OpenMlsProvider as _, types::Ciphersuite};
use tls_codec::{Deserialize, Serialize};

pub const DEFAULT_CIPHERSUITE: Ciphersuite =
    Ciphersuite::MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519;

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
    provider: OpenMlsRustCrypto,
    signer: SignatureKeyPair,
    credential_with_key: CredentialWithKey,
    credential_identity: Vec<u8>,
    ciphersuite: Ciphersuite,
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

    pub fn with_ciphersuite(
        credential_identity: impl Into<Vec<u8>>,
        ciphersuite: Ciphersuite,
    ) -> Result<Self> {
        let credential_identity = credential_identity.into();
        let provider = OpenMlsRustCrypto::default();
        let signer = SignatureKeyPair::new(ciphersuite.signature_algorithm())
            .context("failed to generate MLS signature key pair")?;
        signer
            .store(provider.storage())
            .context("failed to store MLS signer in key store")?;

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
        })
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

        bundle
            .key_package()
            .tls_serialize_detached()
            .context("failed to serialize MLS key package")
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
        conversation
            .group
            .create_message(&self.provider, &self.signer, plaintext)
            .context("failed to create MLS application message")?
            .to_bytes()
            .context("failed to serialize MLS application message")
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

        match processed.into_content() {
            ProcessedMessageContent::ApplicationMessage(message) => {
                Ok(MlsProcessResult::ApplicationMessage(message.into_bytes()))
            }
            ProcessedMessageContent::ProposalMessage(proposal) => {
                conversation
                    .group
                    .store_pending_proposal(self.provider.storage(), *proposal)
                    .context("failed to store MLS proposal")?;
                Ok(MlsProcessResult::ProposalQueued)
            }
            ProcessedMessageContent::ExternalJoinProposalMessage(proposal) => {
                conversation
                    .group
                    .store_pending_proposal(self.provider.storage(), *proposal)
                    .context("failed to store external MLS join proposal")?;
                Ok(MlsProcessResult::ProposalQueued)
            }
            ProcessedMessageContent::StagedCommitMessage(staged_commit) => {
                conversation
                    .group
                    .merge_staged_commit(&self.provider, *staged_commit)
                    .context("failed to merge staged MLS commit")?;
                Ok(MlsProcessResult::CommitMerged {
                    epoch: conversation.group.epoch().as_u64(),
                })
            }
        }
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
    provider: &OpenMlsRustCrypto,
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
}
