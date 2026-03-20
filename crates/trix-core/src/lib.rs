pub mod attachments;
pub mod config;
pub mod crypto;
pub mod ffi;
pub mod message;
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
pub use ffi::*;
pub use message::{
    AttachmentMessageBody, ChatEventMessageBody, MessageBody, ReactionAction, ReactionMessageBody,
    ReceiptMessageBody, ReceiptType, TextMessageBody,
};
pub use signatures::{account_bootstrap_message, device_revoke_message};
pub use storage::{
    AttachmentStore, LocalChatListItem, LocalChatReadState, LocalHistoryStore,
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
    UpdateAccountProfileParams, decode_b64_field, encode_b64, make_control_message_input,
    make_create_message_request, make_publish_key_package_item,
};
