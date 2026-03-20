pub mod config;
pub mod crypto;
pub mod ffi;
pub mod storage;
pub mod sync;
pub mod transport;

uniffi::setup_scaffolding!();

pub use config::CoreConfig;
pub use crypto::{
    AccountRootMaterial, DEFAULT_CIPHERSUITE, DeviceKeyMaterial, MlsCommitBundle, MlsConversation,
    MlsFacade, MlsMemberIdentity, MlsProcessResult,
};
pub use ffi::*;
pub use storage::{
    AttachmentStore, LocalHistoryStore, LocalProjectedMessage, LocalProjectionApplyReport,
    LocalProjectionKind, LocalStoreApplyReport, MlsStateStore, SyncStateStore,
};
pub use sync::{
    CoreEvent, CoreEventSink, InboxApplyOutcome, SyncChatCursor, SyncCoordinator, SyncStateSnapshot,
};
pub use transport::{
    AuthChallengeMaterial, BlobHeadMaterial, BlobMetadataMaterial, CompleteLinkIntentParams,
    CompletedLinkIntentMaterial, CreateAccountParams, DeviceApprovePayloadMaterial,
    DeviceTransferBundleMaterial, HistorySyncChunkMaterial, PublishKeyPackageMaterial,
    ReservedKeyPackageMaterial, ServerApiClient, ServerApiError, decode_b64_field, encode_b64,
    make_control_message_input, make_create_message_request, make_publish_key_package_item,
};
