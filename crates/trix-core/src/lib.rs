pub mod attachments;
pub mod config;
pub mod crypto;
pub mod device_transfer;
pub mod ffi;
pub mod message;
pub mod realtime;
pub mod signatures;
pub mod storage;
pub mod sync;
pub mod transport;

uniffi::setup_scaffolding!();

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
pub use realtime::{
    RealtimeConfig, RealtimeDriver, RealtimeEvent, RealtimeEventKind, RealtimeMode,
};
pub use signatures::{account_bootstrap_message, device_revoke_message};
pub use storage::{
    AttachmentStore, LocalChatListItem, LocalChatReadState, LocalHistoryStore,
    LocalOutboxAttachmentDraft, LocalOutboxMessage, LocalOutboxPayload, LocalOutboxStatus,
    LocalOutgoingMessageApplyOutcome, LocalProjectedMessage, LocalProjectionApplyReport,
    LocalProjectionKind, LocalStoreApplyReport, LocalTimelineItem, MlsStateStore, SyncStateStore,
};
pub use sync::{
    CoreEvent, CoreEventSink, CreateChatControlInput, CreateChatControlOutcome, InboxApplyOutcome,
    ModifyChatDevicesControlInput, ModifyChatDevicesControlOutcome, ModifyChatMembersControlInput,
    ModifyChatMembersControlOutcome, SendMessageOutcome, SyncChatCursor, SyncCoordinator,
    SyncStateSnapshot,
};
pub use transport::{
    AuthChallengeMaterial, BlobHeadMaterial, BlobMetadataMaterial, CompleteLinkIntentParams,
    CompletedLinkIntentMaterial, CreateAccountParams, DeviceApprovePayloadMaterial,
    DeviceTransferBundleMaterial, DirectoryAccountMaterial, HistorySyncChunkMaterial,
    PublishKeyPackageMaterial, ReservedKeyPackageMaterial, ServerApiClient, ServerApiError,
    ServerWebSocketClient, UpdateAccountProfileParams, control_message_ratchet_tree,
    decode_b64_field, encode_b64, make_control_message_input,
    make_control_message_input_with_ratchet_tree, make_create_message_request,
    make_publish_key_package_item,
};
