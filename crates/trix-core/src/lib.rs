pub mod attachments;
pub mod config;
pub mod crypto;
pub mod device_transfer;
pub mod ffi;
pub mod history_sync_payload;
pub mod message;
pub mod messenger;
pub mod realtime;
pub mod signatures;
pub mod storage;
pub mod sync;
pub mod transport;

uniffi::setup_scaffolding!();

pub const DEFAULT_QUICK_REACTION_EMOJIS: [&str; 12] = [
    "👍", "❤️", "🔥", "👎", "💔", "🤔", "😕", "🤨", "😡", "🤡", "💩", "🗿",
];

pub fn default_quick_reaction_emojis() -> Vec<String> {
    DEFAULT_QUICK_REACTION_EMOJIS
        .iter()
        .map(|emoji| (*emoji).to_owned())
        .collect()
}

pub use attachments::{
    ATTACHMENT_FILE_KEY_BYTES, ATTACHMENT_NONCE_BYTES, PreparedAttachmentUpload,
    decrypt_attachment_payload, prepare_attachment_upload,
};
pub use config::CoreConfig;
pub use crypto::{
    AccountRootMaterial, DEFAULT_CIPHERSUITE, DeviceKeyMaterial, MlsCommitBundle, MlsConversation,
    MlsFacade, MlsMemberIdentity, MlsProcessResult,
};
pub use device_transfer::{
    CreateDeviceTransferBundleInput, ImportedDeviceTransferBundle, create_device_transfer_bundle,
    decrypt_device_transfer_bundle,
};
pub use ffi::*;
pub use message::{
    AttachmentMessageBody, ChatEventMessageBody, MessageBody, ReactionAction, ReactionMessageBody,
    ReceiptMessageBody, ReceiptType, TextMessageBody,
};
pub use messenger::*;
pub use realtime::{
    RealtimeConfig, RealtimeDriver, RealtimeEvent, RealtimeEventKind, RealtimeMode,
};
pub use signatures::{account_bootstrap_message, device_revoke_message};
pub use storage::{
    AttachmentStore, LocalChatListItem, LocalChatReadState, LocalHistoryRepairCandidate,
    LocalHistoryRepairReason, LocalHistoryRepairWindow, LocalHistoryStore,
    LocalMessageReactionSummary, LocalMessageRecoveryState, LocalOutboxAttachmentDraft,
    LocalOutboxMessage, LocalOutboxPayload, LocalOutboxStatus, LocalOutgoingMessageApplyOutcome,
    LocalProjectedMessage, LocalProjectionApplyReport, LocalProjectionKind, LocalStoreApplyReport,
    LocalTimelineItem, MlsStateStore, PreparedLocalOutboxSend, SyncStateStore,
};
pub use sync::{
    CoreEvent, CoreEventSink, CreateChatControlInput, CreateChatControlOutcome,
    DmGlobalDeleteControlInput, DmGlobalDeleteControlOutcome, HistorySyncProcessReport,
    InboxApplyOutcome, LeaveChatControlInput, LeaveChatControlOutcome,
    ModifyChatDevicesControlInput, ModifyChatDevicesControlOutcome, ModifyChatMembersControlInput,
    ModifyChatMembersControlOutcome, SendMessageOutcome, SyncChatCursor, SyncCoordinator,
    SyncStateSnapshot,
};
pub use transport::{
    AuthChallengeMaterial, BlobHeadMaterial, BlobMetadataMaterial, CompleteLinkIntentParams,
    CompletedLinkIntentMaterial, CreateAccountParams, DeviceApprovePayloadMaterial,
    DeviceTransferBundleMaterial, DeviceTransportKeyMaterial, DirectoryAccountMaterial,
    HistorySyncChunkMaterial, PublishKeyPackageMaterial, ReservedKeyPackageMaterial,
    ServerApiClient, ServerApiError, ServerWebSocketClient, UpdateAccountProfileParams,
    control_message_ratchet_tree, decode_b64_field, encode_b64, make_control_message_input,
    make_control_message_input_with_ratchet_tree, make_create_message_request,
    make_publish_key_package_item,
};
