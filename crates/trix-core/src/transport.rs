use base64::{Engine as _, engine::general_purpose};
use futures_util::{SinkExt, StreamExt};
use reqwest::{
    Client, Method, Url,
    header::{AUTHORIZATION, CONTENT_LENGTH, ETAG, HeaderMap, HeaderValue},
};
use serde::{Serialize, de::DeserializeOwned};
use serde_json::{Map, Value};
use thiserror::Error;
use tokio::net::TcpStream;
use tokio_tungstenite::{
    MaybeTlsStream, WebSocketStream, connect_async,
    tungstenite::{Message, client::IntoClientRequest},
};
use trix_types::{
    AccountDirectoryResponse, AccountId, AccountKeyPackagesResponse, AccountProfileResponse,
    AckInboxRequest, AckInboxResponse, AppendHistorySyncChunkRequest,
    AppendHistorySyncChunkResponse, BlobMetadataResponse, BlobUploadStatus, ChatDetailResponse,
    ChatHistoryResponse, ChatId, ChatListResponse, CompleteHistorySyncJobRequest,
    CompleteHistorySyncJobResponse, CompleteLinkIntentRequest, CompleteLinkIntentResponse,
    ControlMessageInput, CreateAccountRequest, CreateAccountResponse, CreateBlobUploadRequest,
    CreateBlobUploadResponse, CreateChatRequest, CreateChatResponse, CreateLinkIntentResponse,
    CreateMessageRequest, CreateMessageResponse, DeviceApprovePayloadResponse, DeviceId,
    DeviceListResponse, DeviceStatus, DeviceTransferBundleResponse, DirectoryAccountSummary,
    ErrorResponse, HealthResponse, HistorySyncChunkListResponse, HistorySyncChunkSummary,
    HistorySyncJobListResponse, HistorySyncJobRole, HistorySyncJobStatus, LeaseInboxRequest,
    LeaseInboxResponse, MessageId, ModifyChatDevicesRequest, ModifyChatDevicesResponse,
    ModifyChatMembersRequest, ModifyChatMembersResponse, PublishKeyPackageItem,
    PublishKeyPackagesRequest, PublishKeyPackagesResponse, ReserveKeyPackagesRequest,
    RevokeDeviceRequest, RevokeDeviceResponse, UpdateAccountProfileRequest, VersionResponse,
    WebSocketClientFrame, WebSocketServerFrame,
};

const CONTROL_AAD_META_KEY: &str = "_trix";
const CONTROL_AAD_META_USER_KEY: &str = "user_aad";
const CONTROL_AAD_META_RATCHET_TREE_B64_KEY: &str = "ratchet_tree_b64";

#[derive(Debug, Error)]
pub enum ServerApiError {
    #[error("invalid base url: {0}")]
    InvalidBaseUrl(String),
    #[error("request failed: {0}")]
    Request(#[from] reqwest::Error),
    #[error("invalid response payload: {0}")]
    InvalidResponse(String),
    #[error("invalid base64 in field `{field}`: {source}")]
    InvalidBase64 {
        field: &'static str,
        #[source]
        source: base64::DecodeError,
    },
    #[error("api error {status}: {code}: {message}")]
    Api {
        status: u16,
        code: String,
        message: String,
    },
    #[error("websocket error: {0}")]
    WebSocket(String),
}

#[derive(Debug, Clone)]
pub struct CreateAccountParams {
    pub handle: Option<String>,
    pub profile_name: String,
    pub profile_bio: Option<String>,
    pub device_display_name: String,
    pub platform: String,
    pub credential_identity: Vec<u8>,
    pub account_root_pubkey: Vec<u8>,
    pub account_root_signature: Vec<u8>,
    pub transport_pubkey: Vec<u8>,
}

#[derive(Debug, Clone)]
pub struct PublishKeyPackageMaterial {
    pub cipher_suite: String,
    pub key_package: Vec<u8>,
}

#[derive(Debug, Clone)]
pub struct ReservedKeyPackageMaterial {
    pub key_package_id: String,
    pub device_id: DeviceId,
    pub cipher_suite: String,
    pub key_package: Vec<u8>,
}

#[derive(Debug, Clone)]
pub struct DirectoryAccountMaterial {
    pub account_id: AccountId,
    pub handle: Option<String>,
    pub profile_name: String,
    pub profile_bio: Option<String>,
}

#[derive(Debug, Clone)]
pub struct UpdateAccountProfileParams {
    pub handle: Option<String>,
    pub profile_name: String,
    pub profile_bio: Option<String>,
}

#[derive(Debug, Clone)]
pub struct AuthChallengeMaterial {
    pub challenge_id: String,
    pub challenge: Vec<u8>,
    pub expires_at_unix: u64,
}

#[derive(Debug, Clone)]
pub struct CompleteLinkIntentParams {
    pub link_token: String,
    pub device_display_name: String,
    pub platform: String,
    pub credential_identity: Vec<u8>,
    pub transport_pubkey: Vec<u8>,
    pub key_packages: Vec<PublishKeyPackageMaterial>,
}

#[derive(Debug, Clone)]
pub struct CompletedLinkIntentMaterial {
    pub account_id: AccountId,
    pub pending_device_id: DeviceId,
    pub device_status: DeviceStatus,
    pub bootstrap_payload: Vec<u8>,
}

#[derive(Debug, Clone)]
pub struct DeviceApprovePayloadMaterial {
    pub account_id: AccountId,
    pub device_id: DeviceId,
    pub device_display_name: String,
    pub platform: String,
    pub device_status: DeviceStatus,
    pub credential_identity: Vec<u8>,
    pub transport_pubkey: Vec<u8>,
    pub bootstrap_payload: Vec<u8>,
}

#[derive(Debug, Clone)]
pub struct DeviceTransferBundleMaterial {
    pub account_id: AccountId,
    pub device_id: DeviceId,
    pub transfer_bundle: Vec<u8>,
    pub uploaded_at_unix: u64,
}

#[derive(Debug, Clone)]
pub struct HistorySyncChunkMaterial {
    pub chunk_id: u64,
    pub sequence_no: u64,
    pub payload: Vec<u8>,
    pub cursor_json: Option<Value>,
    pub is_final: bool,
    pub uploaded_at_unix: u64,
}

#[derive(Debug, Clone)]
pub struct BlobMetadataMaterial {
    pub blob_id: String,
    pub mime_type: String,
    pub size_bytes: u64,
    pub sha256: Vec<u8>,
    pub upload_status: BlobUploadStatus,
    pub created_by_device_id: DeviceId,
}

#[derive(Debug, Clone)]
pub struct BlobHeadMaterial {
    pub blob_id: String,
    pub mime_type: String,
    pub size_bytes: u64,
    pub sha256: Vec<u8>,
    pub upload_status: BlobUploadStatus,
    pub etag: Option<String>,
}

#[derive(Debug, Clone)]
pub struct ServerApiClient {
    base_url: Url,
    http: Client,
    access_token: Option<String>,
}

pub struct ServerWebSocketClient {
    ws: WebSocketStream<MaybeTlsStream<TcpStream>>,
}

#[derive(Debug, Serialize)]
struct ListHistorySyncJobsQuery {
    #[serde(skip_serializing_if = "Option::is_none")]
    role: Option<HistorySyncJobRole>,
    #[serde(skip_serializing_if = "Option::is_none")]
    status: Option<HistorySyncJobStatus>,
    #[serde(skip_serializing_if = "Option::is_none")]
    limit: Option<usize>,
}

#[derive(Debug, Serialize)]
struct HistoryQuery {
    #[serde(skip_serializing_if = "Option::is_none")]
    after_server_seq: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    limit: Option<usize>,
}

#[derive(Debug, Serialize)]
struct InboxQuery {
    #[serde(skip_serializing_if = "Option::is_none")]
    after_inbox_id: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    limit: Option<usize>,
}

#[derive(Debug, Serialize)]
struct AccountDirectoryQuery {
    #[serde(skip_serializing_if = "Option::is_none")]
    q: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    limit: Option<usize>,
    exclude_self: bool,
}

impl ServerApiClient {
    pub fn new(base_url: impl AsRef<str>) -> Result<Self, ServerApiError> {
        let mut normalized = base_url.as_ref().trim().trim_end_matches('/').to_owned();
        normalized.push('/');
        let base_url = Url::parse(&normalized)
            .map_err(|err| ServerApiError::InvalidBaseUrl(err.to_string()))?;
        Ok(Self {
            base_url,
            http: Client::new(),
            access_token: None,
        })
    }

    pub fn with_access_token(mut self, access_token: impl Into<String>) -> Self {
        self.access_token = Some(access_token.into());
        self
    }

    pub fn set_access_token(&mut self, access_token: impl Into<String>) {
        self.access_token = Some(access_token.into());
    }

    pub fn clear_access_token(&mut self) {
        self.access_token = None;
    }

    pub fn access_token(&self) -> Option<&str> {
        self.access_token.as_deref()
    }

    pub async fn create_account(
        &self,
        params: CreateAccountParams,
    ) -> Result<CreateAccountResponse, ServerApiError> {
        self.send_json(
            self.request(Method::POST, "v0/accounts")?
                .json(&CreateAccountRequest {
                    handle: params.handle,
                    profile_name: params.profile_name,
                    profile_bio: params.profile_bio,
                    device_display_name: params.device_display_name,
                    platform: params.platform,
                    credential_identity_b64: encode_b64(&params.credential_identity),
                    account_root_pubkey_b64: encode_b64(&params.account_root_pubkey),
                    account_root_signature_b64: encode_b64(&params.account_root_signature),
                    transport_pubkey_b64: encode_b64(&params.transport_pubkey),
                }),
        )
        .await
    }

    pub async fn get_health(&self) -> Result<HealthResponse, ServerApiError> {
        self.send_json(self.request(Method::GET, "v0/system/health")?)
            .await
    }

    pub async fn get_version(&self) -> Result<VersionResponse, ServerApiError> {
        self.send_json(self.request(Method::GET, "v0/system/version")?)
            .await
    }

    pub async fn create_auth_challenge(
        &self,
        device_id: DeviceId,
    ) -> Result<AuthChallengeMaterial, ServerApiError> {
        let response: trix_types::AuthChallengeResponse = self
            .send_json(
                self.request(Method::POST, "v0/auth/challenge")?
                    .json(&trix_types::AuthChallengeRequest { device_id }),
            )
            .await?;

        Ok(AuthChallengeMaterial {
            challenge_id: response.challenge_id,
            challenge: decode_b64_field("challenge_b64", &response.challenge_b64)?,
            expires_at_unix: response.expires_at_unix,
        })
    }

    pub async fn create_auth_session(
        &self,
        device_id: DeviceId,
        challenge_id: impl Into<String>,
        signature: &[u8],
    ) -> Result<trix_types::AuthSessionResponse, ServerApiError> {
        self.send_json(self.request(Method::POST, "v0/auth/session")?.json(
            &trix_types::AuthSessionRequest {
                device_id,
                challenge_id: challenge_id.into(),
                signature_b64: encode_b64(signature),
            },
        ))
        .await
    }

    pub async fn get_me(&self) -> Result<AccountProfileResponse, ServerApiError> {
        self.send_json(self.request(Method::GET, "v0/accounts/me")?)
            .await
    }

    pub async fn search_account_directory(
        &self,
        query: Option<String>,
        limit: Option<usize>,
        exclude_self: bool,
    ) -> Result<Vec<DirectoryAccountMaterial>, ServerApiError> {
        let response: AccountDirectoryResponse = self
            .send_json(self.request(Method::GET, "v0/accounts/directory")?.query(
                &AccountDirectoryQuery {
                    q: query,
                    limit,
                    exclude_self,
                },
            ))
            .await?;

        Ok(response
            .accounts
            .into_iter()
            .map(directory_account_from_response)
            .collect())
    }

    pub async fn get_account(
        &self,
        account_id: AccountId,
    ) -> Result<DirectoryAccountMaterial, ServerApiError> {
        let response: DirectoryAccountSummary = self
            .send_json(self.request(Method::GET, &format!("v0/accounts/{}", account_id.0))?)
            .await?;
        Ok(directory_account_from_response(response))
    }

    pub async fn update_account_profile(
        &self,
        params: UpdateAccountProfileParams,
    ) -> Result<AccountProfileResponse, ServerApiError> {
        self.send_json(self.request(Method::PATCH, "v0/accounts/me")?.json(
            &UpdateAccountProfileRequest {
                handle: params.handle,
                profile_name: params.profile_name,
                profile_bio: params.profile_bio,
            },
        ))
        .await
    }

    pub async fn list_devices(&self) -> Result<DeviceListResponse, ServerApiError> {
        self.send_json(self.request(Method::GET, "v0/devices")?)
            .await
    }

    pub async fn create_link_intent(&self) -> Result<CreateLinkIntentResponse, ServerApiError> {
        self.send_json(self.request(Method::POST, "v0/devices/link-intents")?)
            .await
    }

    pub async fn complete_link_intent(
        &self,
        link_intent_id: impl AsRef<str>,
        params: CompleteLinkIntentParams,
    ) -> Result<CompletedLinkIntentMaterial, ServerApiError> {
        let response: CompleteLinkIntentResponse = self
            .send_json(
                self.request(
                    Method::POST,
                    &format!(
                        "v0/devices/link-intents/{}/complete",
                        link_intent_id.as_ref()
                    ),
                )?
                .json(&CompleteLinkIntentRequest {
                    link_token: params.link_token,
                    device_display_name: params.device_display_name,
                    platform: params.platform,
                    credential_identity_b64: encode_b64(&params.credential_identity),
                    transport_pubkey_b64: encode_b64(&params.transport_pubkey),
                    key_packages: params
                        .key_packages
                        .into_iter()
                        .map(|package| PublishKeyPackageItem {
                            cipher_suite: package.cipher_suite,
                            key_package_b64: encode_b64(&package.key_package),
                        })
                        .collect(),
                }),
            )
            .await?;

        Ok(CompletedLinkIntentMaterial {
            account_id: response.account_id,
            pending_device_id: response.pending_device_id,
            device_status: response.device_status,
            bootstrap_payload: decode_b64_field(
                "bootstrap_payload_b64",
                &response.bootstrap_payload_b64,
            )?,
        })
    }

    pub async fn get_device_approve_payload(
        &self,
        device_id: DeviceId,
    ) -> Result<DeviceApprovePayloadMaterial, ServerApiError> {
        let response: DeviceApprovePayloadResponse = self
            .send_json(self.request(
                Method::GET,
                &format!("v0/devices/{}/approve-payload", device_id.0),
            )?)
            .await?;

        Ok(DeviceApprovePayloadMaterial {
            account_id: response.account_id,
            device_id: response.device_id,
            device_display_name: response.device_display_name,
            platform: response.platform,
            device_status: response.device_status,
            credential_identity: decode_b64_field(
                "credential_identity_b64",
                &response.credential_identity_b64,
            )?,
            transport_pubkey: decode_b64_field(
                "transport_pubkey_b64",
                &response.transport_pubkey_b64,
            )?,
            bootstrap_payload: decode_b64_field(
                "bootstrap_payload_b64",
                &response.bootstrap_payload_b64,
            )?,
        })
    }

    pub async fn approve_device(
        &self,
        device_id: DeviceId,
        account_root_signature: &[u8],
        transfer_bundle: Option<&[u8]>,
    ) -> Result<trix_types::ApproveDeviceResponse, ServerApiError> {
        self.send_json(
            self.request(Method::POST, &format!("v0/devices/{}/approve", device_id.0))?
                .json(&trix_types::ApproveDeviceRequest {
                    account_root_signature_b64: encode_b64(account_root_signature),
                    transfer_bundle_b64: transfer_bundle.map(encode_b64),
                }),
        )
        .await
    }

    pub async fn get_device_transfer_bundle(
        &self,
        device_id: DeviceId,
    ) -> Result<DeviceTransferBundleMaterial, ServerApiError> {
        let response: DeviceTransferBundleResponse = self
            .send_json(self.request(
                Method::GET,
                &format!("v0/devices/{}/transfer-bundle", device_id.0),
            )?)
            .await?;

        Ok(DeviceTransferBundleMaterial {
            account_id: response.account_id,
            device_id: response.device_id,
            transfer_bundle: decode_b64_field(
                "transfer_bundle_b64",
                &response.transfer_bundle_b64,
            )?,
            uploaded_at_unix: response.uploaded_at_unix,
        })
    }

    pub async fn revoke_device(
        &self,
        device_id: DeviceId,
        reason: impl Into<String>,
        account_root_signature: &[u8],
    ) -> Result<RevokeDeviceResponse, ServerApiError> {
        self.send_json(
            self.request(Method::POST, &format!("v0/devices/{}/revoke", device_id.0))?
                .json(&RevokeDeviceRequest {
                    reason: reason.into(),
                    account_root_signature_b64: encode_b64(account_root_signature),
                }),
        )
        .await
    }

    pub async fn publish_key_packages(
        &self,
        packages: Vec<PublishKeyPackageMaterial>,
    ) -> Result<PublishKeyPackagesResponse, ServerApiError> {
        self.send_json(
            self.request(Method::POST, "v0/key-packages:publish")?.json(
                &PublishKeyPackagesRequest {
                    packages: packages
                        .into_iter()
                        .map(|package| PublishKeyPackageItem {
                            cipher_suite: package.cipher_suite,
                            key_package_b64: encode_b64(&package.key_package),
                        })
                        .collect(),
                },
            ),
        )
        .await
    }

    pub async fn reserve_key_packages(
        &self,
        account_id: AccountId,
        device_ids: Vec<DeviceId>,
    ) -> Result<Vec<ReservedKeyPackageMaterial>, ServerApiError> {
        let response: AccountKeyPackagesResponse = self
            .send_json(self.request(Method::POST, "v0/key-packages:reserve")?.json(
                &ReserveKeyPackagesRequest {
                    account_id,
                    device_ids,
                },
            ))
            .await?;

        response
            .packages
            .into_iter()
            .map(|package| {
                Ok(ReservedKeyPackageMaterial {
                    key_package_id: package.key_package_id,
                    device_id: package.device_id,
                    cipher_suite: package.cipher_suite,
                    key_package: decode_b64_field("key_package_b64", &package.key_package_b64)?,
                })
            })
            .collect()
    }

    pub async fn get_account_key_packages(
        &self,
        account_id: AccountId,
    ) -> Result<Vec<ReservedKeyPackageMaterial>, ServerApiError> {
        let response: AccountKeyPackagesResponse = self
            .send_json(self.request(
                Method::GET,
                &format!("v0/accounts/{}/key-packages", account_id.0),
            )?)
            .await?;

        response
            .packages
            .into_iter()
            .map(|package| {
                Ok(ReservedKeyPackageMaterial {
                    key_package_id: package.key_package_id,
                    device_id: package.device_id,
                    cipher_suite: package.cipher_suite,
                    key_package: decode_b64_field("key_package_b64", &package.key_package_b64)?,
                })
            })
            .collect()
    }

    pub async fn list_history_sync_jobs(
        &self,
        role: Option<HistorySyncJobRole>,
        status: Option<HistorySyncJobStatus>,
        limit: Option<usize>,
    ) -> Result<HistorySyncJobListResponse, ServerApiError> {
        self.send_json(self.request(Method::GET, "v0/history-sync/jobs")?.query(
            &ListHistorySyncJobsQuery {
                role,
                status,
                limit,
            },
        ))
        .await
    }

    pub async fn append_history_sync_chunk(
        &self,
        job_id: impl AsRef<str>,
        sequence_no: u64,
        payload: &[u8],
        cursor_json: Option<Value>,
        is_final: bool,
    ) -> Result<AppendHistorySyncChunkResponse, ServerApiError> {
        self.send_json(
            self.request(
                Method::POST,
                &format!("v0/history-sync/jobs/{}/chunks", job_id.as_ref()),
            )?
            .json(&AppendHistorySyncChunkRequest {
                sequence_no,
                payload_b64: encode_b64(payload),
                cursor_json,
                is_final,
            }),
        )
        .await
    }

    pub async fn get_history_sync_chunks(
        &self,
        job_id: impl AsRef<str>,
    ) -> Result<Vec<HistorySyncChunkMaterial>, ServerApiError> {
        let response: HistorySyncChunkListResponse = self
            .send_json(self.request(
                Method::GET,
                &format!("v0/history-sync/jobs/{}/chunks", job_id.as_ref()),
            )?)
            .await?;

        response
            .chunks
            .into_iter()
            .map(decode_history_sync_chunk)
            .collect()
    }

    pub async fn complete_history_sync_job(
        &self,
        job_id: impl AsRef<str>,
        cursor_json: Option<Value>,
    ) -> Result<CompleteHistorySyncJobResponse, ServerApiError> {
        self.send_json(
            self.request(
                Method::POST,
                &format!("v0/history-sync/jobs/{}/complete", job_id.as_ref()),
            )?
            .json(&CompleteHistorySyncJobRequest { cursor_json }),
        )
        .await
    }

    pub async fn list_chats(&self) -> Result<ChatListResponse, ServerApiError> {
        self.send_json(self.request(Method::GET, "v0/chats")?).await
    }

    pub async fn get_chat(&self, chat_id: ChatId) -> Result<ChatDetailResponse, ServerApiError> {
        self.send_json(self.request(Method::GET, &format!("v0/chats/{}", chat_id.0))?)
            .await
    }

    pub async fn create_chat(
        &self,
        request: CreateChatRequest,
    ) -> Result<CreateChatResponse, ServerApiError> {
        self.send_json(self.request(Method::POST, "v0/chats")?.json(&request))
            .await
    }

    pub async fn create_message(
        &self,
        chat_id: ChatId,
        request: CreateMessageRequest,
    ) -> Result<CreateMessageResponse, ServerApiError> {
        self.send_json(
            self.request(Method::POST, &format!("v0/chats/{}/messages", chat_id.0))?
                .json(&request),
        )
        .await
    }

    pub async fn add_chat_members(
        &self,
        chat_id: ChatId,
        request: ModifyChatMembersRequest,
    ) -> Result<ModifyChatMembersResponse, ServerApiError> {
        self.send_json(
            self.request(Method::POST, &format!("v0/chats/{}/members:add", chat_id.0))?
                .json(&request),
        )
        .await
    }

    pub async fn remove_chat_members(
        &self,
        chat_id: ChatId,
        request: ModifyChatMembersRequest,
    ) -> Result<ModifyChatMembersResponse, ServerApiError> {
        self.send_json(
            self.request(
                Method::POST,
                &format!("v0/chats/{}/members:remove", chat_id.0),
            )?
            .json(&request),
        )
        .await
    }

    pub async fn add_chat_devices(
        &self,
        chat_id: ChatId,
        request: ModifyChatDevicesRequest,
    ) -> Result<ModifyChatDevicesResponse, ServerApiError> {
        self.send_json(
            self.request(Method::POST, &format!("v0/chats/{}/devices:add", chat_id.0))?
                .json(&request),
        )
        .await
    }

    pub async fn remove_chat_devices(
        &self,
        chat_id: ChatId,
        request: ModifyChatDevicesRequest,
    ) -> Result<ModifyChatDevicesResponse, ServerApiError> {
        self.send_json(
            self.request(
                Method::POST,
                &format!("v0/chats/{}/devices:remove", chat_id.0),
            )?
            .json(&request),
        )
        .await
    }

    pub async fn get_chat_history(
        &self,
        chat_id: ChatId,
        after_server_seq: Option<u64>,
        limit: Option<usize>,
    ) -> Result<ChatHistoryResponse, ServerApiError> {
        self.send_json(
            self.request(Method::GET, &format!("v0/chats/{}/history", chat_id.0))?
                .query(&HistoryQuery {
                    after_server_seq,
                    limit,
                }),
        )
        .await
    }

    pub async fn get_inbox(
        &self,
        after_inbox_id: Option<u64>,
        limit: Option<usize>,
    ) -> Result<trix_types::InboxResponse, ServerApiError> {
        self.send_json(self.request(Method::GET, "v0/inbox")?.query(&InboxQuery {
            after_inbox_id,
            limit,
        }))
        .await
    }

    pub async fn lease_inbox(
        &self,
        request: LeaseInboxRequest,
    ) -> Result<LeaseInboxResponse, ServerApiError> {
        self.send_json(self.request(Method::POST, "v0/inbox/lease")?.json(&request))
            .await
    }

    pub async fn ack_inbox(&self, inbox_ids: Vec<u64>) -> Result<AckInboxResponse, ServerApiError> {
        self.send_json(
            self.request(Method::POST, "v0/inbox/ack")?
                .json(&AckInboxRequest { inbox_ids }),
        )
        .await
    }

    pub async fn create_blob_upload(
        &self,
        chat_id: ChatId,
        mime_type: impl Into<String>,
        size_bytes: u64,
        sha256: &[u8],
    ) -> Result<CreateBlobUploadResponse, ServerApiError> {
        self.send_json(self.request(Method::POST, "v0/blobs/uploads")?.json(
            &CreateBlobUploadRequest {
                chat_id,
                mime_type: mime_type.into(),
                size_bytes,
                sha256_b64: encode_b64(sha256),
            },
        ))
        .await
    }

    pub async fn upload_blob(
        &self,
        blob_id: impl AsRef<str>,
        payload: &[u8],
    ) -> Result<BlobMetadataMaterial, ServerApiError> {
        let response: BlobMetadataResponse = self
            .send_json(
                self.request(Method::PUT, &format!("v0/blobs/{}", blob_id.as_ref()))?
                    .body(payload.to_vec()),
            )
            .await?;
        decode_blob_metadata(response)
    }

    pub async fn head_blob(
        &self,
        blob_id: impl AsRef<str>,
    ) -> Result<BlobHeadMaterial, ServerApiError> {
        let response = self
            .request(Method::HEAD, &format!("v0/blobs/{}", blob_id.as_ref()))?
            .send()
            .await?;
        let status = response.status();
        let headers = response.headers().clone();
        let body = response.bytes().await?;

        if !status.is_success() {
            return Err(api_error_from_response(status.as_u16(), &body));
        }

        Ok(BlobHeadMaterial {
            blob_id: header_string(&headers, "x-trix-blob-id")?,
            mime_type: header_string(&headers, "x-trix-blob-mime-type")?,
            size_bytes: header_u64(&headers, CONTENT_LENGTH, "content length")?,
            sha256: decode_b64_field(
                "x-trix-blob-sha256-b64",
                &header_string(&headers, "x-trix-blob-sha256-b64")?,
            )?,
            upload_status: parse_blob_upload_status(&header_string(
                &headers,
                "x-trix-blob-upload-status",
            )?)?,
            etag: headers
                .get(ETAG)
                .and_then(|value| value.to_str().ok())
                .map(ToOwned::to_owned),
        })
    }

    pub async fn download_blob(&self, blob_id: impl AsRef<str>) -> Result<Vec<u8>, ServerApiError> {
        let response = self
            .request(Method::GET, &format!("v0/blobs/{}", blob_id.as_ref()))?
            .send()
            .await?;
        let status = response.status();
        let body = response.bytes().await?;

        if status.is_success() {
            Ok(body.to_vec())
        } else {
            Err(api_error_from_response(status.as_u16(), &body))
        }
    }

    pub async fn connect_websocket(&self) -> Result<ServerWebSocketClient, ServerApiError> {
        let access_token = self.access_token.as_deref().ok_or_else(|| {
            ServerApiError::WebSocket("missing access token for websocket connection".to_owned())
        })?;
        let mut request = self
            .websocket_url()?
            .to_string()
            .into_client_request()
            .map_err(|err| {
                ServerApiError::WebSocket(format!("invalid websocket request: {err}"))
            })?;
        request.headers_mut().insert(
            AUTHORIZATION,
            HeaderValue::from_str(&format!("Bearer {access_token}")).map_err(|err| {
                ServerApiError::WebSocket(format!("invalid authorization header: {err}"))
            })?,
        );

        let (ws, _) = connect_async(request)
            .await
            .map_err(|err| ServerApiError::WebSocket(err.to_string()))?;
        Ok(ServerWebSocketClient { ws })
    }

    fn request(
        &self,
        method: Method,
        path: &str,
    ) -> Result<reqwest::RequestBuilder, ServerApiError> {
        let path = path.trim_start_matches('/');
        let url = self
            .base_url
            .join(path)
            .map_err(|err| ServerApiError::InvalidBaseUrl(err.to_string()))?;
        let builder = self.http.request(method, url);
        Ok(match &self.access_token {
            Some(token) => builder.bearer_auth(token),
            None => builder,
        })
    }

    fn websocket_url(&self) -> Result<Url, ServerApiError> {
        let mut url = self
            .base_url
            .join("v0/ws")
            .map_err(|err| ServerApiError::InvalidBaseUrl(err.to_string()))?;
        match url.scheme() {
            "http" => url.set_scheme("ws").map_err(|_| {
                ServerApiError::InvalidBaseUrl("failed to set ws scheme".to_owned())
            })?,
            "https" => url.set_scheme("wss").map_err(|_| {
                ServerApiError::InvalidBaseUrl("failed to set wss scheme".to_owned())
            })?,
            "ws" | "wss" => {}
            other => {
                return Err(ServerApiError::InvalidBaseUrl(format!(
                    "unsupported websocket base scheme `{other}`"
                )));
            }
        }
        Ok(url)
    }

    async fn send_json<T>(&self, request: reqwest::RequestBuilder) -> Result<T, ServerApiError>
    where
        T: DeserializeOwned,
    {
        let response = request.send().await?;
        let status = response.status();
        let body = response.bytes().await?;

        if status.is_success() {
            serde_json::from_slice(&body).map_err(|err| {
                ServerApiError::InvalidResponse(format!("failed to decode success payload: {err}"))
            })
        } else if let Ok(api_error) = serde_json::from_slice::<ErrorResponse>(&body) {
            Err(ServerApiError::Api {
                status: status.as_u16(),
                code: api_error.code,
                message: api_error.message,
            })
        } else {
            Err(ServerApiError::Api {
                status: status.as_u16(),
                code: "http_error".to_owned(),
                message: String::from_utf8_lossy(&body).trim().to_owned(),
            })
        }
    }
}

impl ServerWebSocketClient {
    pub async fn next_frame(&mut self) -> Result<Option<WebSocketServerFrame>, ServerApiError> {
        loop {
            match self.ws.next().await {
                Some(Ok(Message::Text(text))) => {
                    let frame = serde_json::from_str(text.as_ref()).map_err(|err| {
                        ServerApiError::InvalidResponse(format!(
                            "failed to decode websocket frame: {err}"
                        ))
                    })?;
                    return Ok(Some(frame));
                }
                Some(Ok(Message::Close(_))) | None => return Ok(None),
                Some(Ok(Message::Ping(_))) | Some(Ok(Message::Pong(_))) => continue,
                Some(Ok(Message::Binary(_))) => {
                    return Err(ServerApiError::InvalidResponse(
                        "unexpected binary websocket frame".to_owned(),
                    ));
                }
                Some(Ok(_)) => continue,
                Some(Err(err)) => return Err(ServerApiError::WebSocket(err.to_string())),
            }
        }
    }

    pub async fn send_frame(&mut self, frame: &WebSocketClientFrame) -> Result<(), ServerApiError> {
        let payload = serde_json::to_string(frame).map_err(|err| {
            ServerApiError::InvalidResponse(format!("failed to encode websocket frame: {err}"))
        })?;
        self.ws
            .send(Message::Text(payload.into()))
            .await
            .map_err(|err| ServerApiError::WebSocket(err.to_string()))
    }

    pub async fn send_ack(&mut self, inbox_ids: Vec<u64>) -> Result<(), ServerApiError> {
        self.send_frame(&WebSocketClientFrame::Ack { inbox_ids })
            .await
    }

    pub async fn send_presence_ping(
        &mut self,
        nonce: Option<String>,
    ) -> Result<(), ServerApiError> {
        self.send_frame(&WebSocketClientFrame::PresencePing { nonce })
            .await
    }

    pub async fn send_typing_update(
        &mut self,
        chat_id: ChatId,
        is_typing: bool,
    ) -> Result<(), ServerApiError> {
        self.send_frame(&WebSocketClientFrame::TypingUpdate { chat_id, is_typing })
            .await
    }

    pub async fn send_history_sync_progress(
        &mut self,
        job_id: impl Into<String>,
        cursor_json: Option<Value>,
        completed_chunks: Option<u64>,
    ) -> Result<(), ServerApiError> {
        self.send_frame(&WebSocketClientFrame::HistorySyncProgress {
            job_id: job_id.into(),
            cursor_json,
            completed_chunks,
        })
        .await
    }

    pub async fn close(&mut self) -> Result<(), ServerApiError> {
        self.ws
            .close(None)
            .await
            .map_err(|err| ServerApiError::WebSocket(err.to_string()))
    }
}

pub fn make_control_message_input(
    message_id: MessageId,
    ciphertext: &[u8],
    aad_json: Option<Value>,
) -> ControlMessageInput {
    make_control_message_input_with_ratchet_tree(message_id, ciphertext, aad_json, None)
}

pub fn make_control_message_input_with_ratchet_tree(
    message_id: MessageId,
    ciphertext: &[u8],
    aad_json: Option<Value>,
    ratchet_tree: Option<&[u8]>,
) -> ControlMessageInput {
    ControlMessageInput {
        message_id,
        ciphertext_b64: encode_b64(ciphertext),
        aad_json: merge_control_aad(aad_json, ratchet_tree),
    }
}

pub fn make_create_message_request(
    message_id: MessageId,
    epoch: u64,
    message_kind: trix_types::MessageKind,
    content_type: trix_types::ContentType,
    ciphertext: &[u8],
    aad_json: Option<Value>,
) -> CreateMessageRequest {
    CreateMessageRequest {
        message_id,
        epoch,
        message_kind,
        content_type,
        ciphertext_b64: encode_b64(ciphertext),
        aad_json,
    }
}

pub fn make_publish_key_package_item(
    cipher_suite: impl Into<String>,
    key_package: &[u8],
) -> PublishKeyPackageItem {
    PublishKeyPackageItem {
        cipher_suite: cipher_suite.into(),
        key_package_b64: encode_b64(key_package),
    }
}

pub fn encode_b64(bytes: &[u8]) -> String {
    general_purpose::STANDARD.encode(bytes)
}

pub fn control_message_ratchet_tree(aad_json: &Value) -> Result<Option<Vec<u8>>, ServerApiError> {
    let Some(meta) = aad_json
        .as_object()
        .and_then(|object| object.get(CONTROL_AAD_META_KEY))
        .and_then(Value::as_object)
    else {
        return Ok(None);
    };

    let Some(value) = meta
        .get(CONTROL_AAD_META_RATCHET_TREE_B64_KEY)
        .and_then(Value::as_str)
    else {
        return Ok(None);
    };

    Ok(Some(decode_b64_field(
        "aad_json._trix.ratchet_tree_b64",
        value,
    )?))
}

fn merge_control_aad(aad_json: Option<Value>, ratchet_tree: Option<&[u8]>) -> Option<Value> {
    let Some(ratchet_tree) = ratchet_tree else {
        return aad_json;
    };

    let mut root = match aad_json {
        Some(Value::Object(object)) => object,
        Some(other) => {
            let mut object = Map::new();
            object.insert(CONTROL_AAD_META_USER_KEY.to_owned(), other);
            object
        }
        None => Map::new(),
    };

    let mut meta = match root.remove(CONTROL_AAD_META_KEY) {
        Some(Value::Object(object)) => object,
        Some(other) => {
            let mut object = Map::new();
            object.insert("raw".to_owned(), other);
            object
        }
        None => Map::new(),
    };
    meta.insert(
        CONTROL_AAD_META_RATCHET_TREE_B64_KEY.to_owned(),
        Value::String(encode_b64(ratchet_tree)),
    );
    root.insert(CONTROL_AAD_META_KEY.to_owned(), Value::Object(meta));

    Some(Value::Object(root))
}

fn directory_account_from_response(value: DirectoryAccountSummary) -> DirectoryAccountMaterial {
    DirectoryAccountMaterial {
        account_id: value.account_id,
        handle: value.handle,
        profile_name: value.profile_name,
        profile_bio: value.profile_bio,
    }
}

pub fn decode_b64_field(field: &'static str, value: &str) -> Result<Vec<u8>, ServerApiError> {
    for engine in [
        &general_purpose::STANDARD,
        &general_purpose::STANDARD_NO_PAD,
        &general_purpose::URL_SAFE,
        &general_purpose::URL_SAFE_NO_PAD,
    ] {
        if let Ok(bytes) = engine.decode(value) {
            return Ok(bytes);
        }
    }

    Err(ServerApiError::InvalidBase64 {
        field,
        source: general_purpose::STANDARD
            .decode(value)
            .expect_err("base64 decode error must exist for invalid payload"),
    })
}

fn decode_history_sync_chunk(
    chunk: HistorySyncChunkSummary,
) -> Result<HistorySyncChunkMaterial, ServerApiError> {
    Ok(HistorySyncChunkMaterial {
        chunk_id: chunk.chunk_id,
        sequence_no: chunk.sequence_no,
        payload: decode_b64_field("payload_b64", &chunk.payload_b64)?,
        cursor_json: chunk.cursor_json,
        is_final: chunk.is_final,
        uploaded_at_unix: chunk.uploaded_at_unix,
    })
}

fn decode_blob_metadata(
    metadata: BlobMetadataResponse,
) -> Result<BlobMetadataMaterial, ServerApiError> {
    Ok(BlobMetadataMaterial {
        blob_id: metadata.blob_id,
        mime_type: metadata.mime_type,
        size_bytes: metadata.size_bytes,
        sha256: decode_b64_field("sha256_b64", &metadata.sha256_b64)?,
        upload_status: metadata.upload_status,
        created_by_device_id: metadata.created_by_device_id,
    })
}

fn parse_blob_upload_status(value: &str) -> Result<BlobUploadStatus, ServerApiError> {
    match value {
        "pending_upload" => Ok(BlobUploadStatus::PendingUpload),
        "available" => Ok(BlobUploadStatus::Available),
        other => Err(ServerApiError::InvalidResponse(format!(
            "unknown blob upload status `{other}`"
        ))),
    }
}

fn header_string(
    headers: &HeaderMap,
    name: impl reqwest::header::AsHeaderName,
) -> Result<String, ServerApiError> {
    headers
        .get(name)
        .ok_or_else(|| ServerApiError::InvalidResponse("missing response header".to_owned()))?
        .to_str()
        .map(ToOwned::to_owned)
        .map_err(|err| ServerApiError::InvalidResponse(format!("invalid header value: {err}")))
}

fn header_u64(
    headers: &HeaderMap,
    name: impl reqwest::header::AsHeaderName,
    field: &'static str,
) -> Result<u64, ServerApiError> {
    header_string(headers, name)?
        .parse::<u64>()
        .map_err(|err| ServerApiError::InvalidResponse(format!("invalid {field}: {err}")))
}

fn api_error_from_response(status: u16, body: &[u8]) -> ServerApiError {
    if let Ok(api_error) = serde_json::from_slice::<ErrorResponse>(body) {
        ServerApiError::Api {
            status,
            code: api_error.code,
            message: api_error.message,
        }
    } else {
        ServerApiError::Api {
            status,
            code: "http_error".to_owned(),
            message: String::from_utf8_lossy(body).trim().to_owned(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{decode_b64_field, encode_b64};

    #[test]
    fn base64_helpers_roundtrip() {
        let payload = b"trix-transport";
        let encoded = encode_b64(payload);
        let decoded = decode_b64_field("payload", &encoded).expect("decode succeeds");

        assert_eq!(decoded, payload);
    }
}
