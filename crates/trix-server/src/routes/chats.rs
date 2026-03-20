use axum::{
    Json, Router,
    extract::{Path, Query, State},
    http::HeaderMap,
    routing::{get, post},
};
use base64::{Engine as _, engine::general_purpose};
use serde::Deserialize;

use crate::{
    db::{
        CreateChatInput, CreateMessageInput, MessageEnvelopeRow, ModifyChatDevicesInput,
        ModifyChatMembersInput, PendingControlMessage,
    },
    error::AppError,
    state::AppState,
};
use trix_types::{
    ChatDetailResponse, ChatDeviceSummary, ChatHistoryResponse, ChatListResponse,
    ChatMemberSummary, ChatParticipantProfileSummary, ChatSummary, ControlMessageInput,
    CreateChatRequest, CreateChatResponse, CreateMessageRequest, CreateMessageResponse,
    MessageEnvelope, ModifyChatDevicesRequest, ModifyChatDevicesResponse, ModifyChatMembersRequest,
    ModifyChatMembersResponse,
};

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/", get(list_chats).post(create_chat))
        .route("/{chat_id}", get(get_chat))
        .route("/{chat_id}/messages", post(create_message))
        .route("/{chat_id}/history", get(get_history))
        .route("/{chat_id}/members:add", post(add_members))
        .route("/{chat_id}/members:remove", post(remove_members))
        .route("/{chat_id}/devices:add", post(add_devices))
        .route("/{chat_id}/devices:remove", post(remove_devices))
}

#[derive(Debug, Deserialize)]
struct HistoryQuery {
    after_server_seq: Option<u64>,
    limit: Option<usize>,
}

async fn list_chats(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<ChatListResponse>, AppError> {
    let principal = state.authenticate_active_headers(&headers).await?;
    let chats = state
        .db
        .list_chats_for_device(principal.account_id, principal.device_id)
        .await?;

    Ok(Json(ChatListResponse {
        chats: chats
            .into_iter()
            .map(|chat| ChatSummary {
                chat_id: trix_types::ChatId(chat.chat_id),
                chat_type: chat.chat_type,
                title: chat.title,
                last_server_seq: chat.last_server_seq,
                pending_message_count: chat.pending_message_count,
                last_message: chat.last_message.map(message_to_api),
                participant_profiles: chat
                    .participant_profiles
                    .into_iter()
                    .map(|profile| ChatParticipantProfileSummary {
                        account_id: trix_types::AccountId(profile.account_id),
                        handle: profile.handle,
                        profile_name: profile.profile_name,
                        profile_bio: profile.profile_bio,
                    })
                    .collect(),
            })
            .collect(),
    }))
}

async fn create_chat(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<CreateChatRequest>,
) -> Result<Json<CreateChatResponse>, AppError> {
    let principal = state.authenticate_active_headers(&headers).await?;
    let reserved_key_package_ids = parse_uuid_list(&request.reserved_key_package_ids)?;
    let created = state
        .db
        .create_chat(CreateChatInput {
            creator_account_id: principal.account_id,
            creator_device_id: principal.device_id,
            chat_type: request.chat_type,
            title: request.title,
            participant_account_ids: request
                .participant_account_ids
                .into_iter()
                .map(|account_id| account_id.0)
                .collect(),
            reserved_key_package_ids,
            initial_commit: request
                .initial_commit
                .map(decode_control_message)
                .transpose()?,
            welcome_message: request
                .welcome_message
                .map(decode_control_message)
                .transpose()?,
        })
        .await?;

    Ok(Json(CreateChatResponse {
        chat_id: trix_types::ChatId(created.chat_id),
        chat_type: created.chat_type,
        epoch: created.epoch,
    }))
}

async fn get_chat(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(chat_id): Path<trix_types::ChatId>,
) -> Result<Json<ChatDetailResponse>, AppError> {
    let principal = state.authenticate_active_headers(&headers).await?;
    let chat = state
        .db
        .get_chat_detail_for_device(chat_id.0, principal.device_id)
        .await?
        .ok_or_else(|| AppError::not_found("chat not found"))?;

    Ok(Json(ChatDetailResponse {
        chat_id: trix_types::ChatId(chat.chat_id),
        chat_type: chat.chat_type,
        title: chat.title,
        last_server_seq: chat.last_server_seq,
        pending_message_count: chat.pending_message_count,
        epoch: chat.epoch,
        last_commit_message_id: chat.last_commit_message_id.map(trix_types::MessageId),
        last_message: chat.last_message.map(message_to_api),
        participant_profiles: chat
            .participant_profiles
            .into_iter()
            .map(|profile| ChatParticipantProfileSummary {
                account_id: trix_types::AccountId(profile.account_id),
                handle: profile.handle,
                profile_name: profile.profile_name,
                profile_bio: profile.profile_bio,
            })
            .collect(),
        members: chat
            .members
            .into_iter()
            .map(|member| ChatMemberSummary {
                account_id: trix_types::AccountId(member.account_id),
                role: member.role,
                membership_status: member.membership_status,
            })
            .collect(),
        device_members: chat
            .device_members
            .into_iter()
            .map(|member| ChatDeviceSummary {
                device_id: trix_types::DeviceId(member.device_id),
                account_id: trix_types::AccountId(member.account_id),
                display_name: member.display_name,
                platform: member.platform,
                leaf_index: member.leaf_index,
                credential_identity_b64: general_purpose::STANDARD
                    .encode(member.credential_identity),
            })
            .collect(),
    }))
}

async fn create_message(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(chat_id): Path<trix_types::ChatId>,
    Json(request): Json<CreateMessageRequest>,
) -> Result<Json<CreateMessageResponse>, AppError> {
    let principal = state.authenticate_active_headers(&headers).await?;
    let ciphertext = decode_b64(&request.ciphertext_b64)?;
    let created = state
        .db
        .append_message(CreateMessageInput {
            chat_id: chat_id.0,
            sender_account_id: principal.account_id,
            sender_device_id: principal.device_id,
            message_id: request.message_id.0,
            epoch: request.epoch,
            message_kind: request.message_kind,
            content_type: request.content_type,
            ciphertext,
            aad_json: request.aad_json.unwrap_or_default(),
        })
        .await?;

    Ok(Json(CreateMessageResponse {
        message_id: trix_types::MessageId(created.message_id),
        server_seq: created.server_seq,
    }))
}

async fn get_history(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(chat_id): Path<trix_types::ChatId>,
    Query(query): Query<HistoryQuery>,
) -> Result<Json<ChatHistoryResponse>, AppError> {
    let principal = state.authenticate_active_headers(&headers).await?;
    let messages = state
        .db
        .get_chat_history_for_device(
            chat_id.0,
            principal.device_id,
            query.after_server_seq,
            query.limit,
        )
        .await?
        .ok_or_else(|| AppError::not_found("chat not found"))?;

    Ok(Json(ChatHistoryResponse {
        chat_id,
        messages: messages.into_iter().map(message_to_api).collect(),
    }))
}

async fn add_members(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(chat_id): Path<trix_types::ChatId>,
    Json(request): Json<ModifyChatMembersRequest>,
) -> Result<Json<ModifyChatMembersResponse>, AppError> {
    let principal = state.authenticate_active_headers(&headers).await?;
    let reserved_key_package_ids = parse_uuid_list(&request.reserved_key_package_ids)?;
    let updated = state
        .db
        .add_chat_members(ModifyChatMembersInput {
            chat_id: chat_id.0,
            actor_account_id: principal.account_id,
            actor_device_id: principal.device_id,
            epoch: request.epoch,
            participant_account_ids: request
                .participant_account_ids
                .into_iter()
                .map(|account_id| account_id.0)
                .collect(),
            reserved_key_package_ids,
            commit_message: request
                .commit_message
                .map(decode_control_message)
                .transpose()?,
            welcome_message: request
                .welcome_message
                .map(decode_control_message)
                .transpose()?,
        })
        .await?;

    Ok(Json(ModifyChatMembersResponse {
        chat_id: trix_types::ChatId(updated.chat_id),
        epoch: updated.epoch,
        changed_account_ids: updated
            .changed_account_ids
            .into_iter()
            .map(trix_types::AccountId)
            .collect(),
    }))
}

async fn remove_members(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(chat_id): Path<trix_types::ChatId>,
    Json(request): Json<ModifyChatMembersRequest>,
) -> Result<Json<ModifyChatMembersResponse>, AppError> {
    let principal = state.authenticate_active_headers(&headers).await?;
    let reserved_key_package_ids = parse_uuid_list(&request.reserved_key_package_ids)?;
    let updated = state
        .db
        .remove_chat_members(ModifyChatMembersInput {
            chat_id: chat_id.0,
            actor_account_id: principal.account_id,
            actor_device_id: principal.device_id,
            epoch: request.epoch,
            participant_account_ids: request
                .participant_account_ids
                .into_iter()
                .map(|account_id| account_id.0)
                .collect(),
            reserved_key_package_ids,
            commit_message: request
                .commit_message
                .map(decode_control_message)
                .transpose()?,
            welcome_message: request
                .welcome_message
                .map(decode_control_message)
                .transpose()?,
        })
        .await?;

    Ok(Json(ModifyChatMembersResponse {
        chat_id: trix_types::ChatId(updated.chat_id),
        epoch: updated.epoch,
        changed_account_ids: updated
            .changed_account_ids
            .into_iter()
            .map(trix_types::AccountId)
            .collect(),
    }))
}

async fn add_devices(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(chat_id): Path<trix_types::ChatId>,
    Json(request): Json<ModifyChatDevicesRequest>,
) -> Result<Json<ModifyChatDevicesResponse>, AppError> {
    let principal = state.authenticate_active_headers(&headers).await?;
    let reserved_key_package_ids = parse_uuid_list(&request.reserved_key_package_ids)?;
    let updated = state
        .db
        .add_chat_devices(ModifyChatDevicesInput {
            chat_id: chat_id.0,
            actor_account_id: principal.account_id,
            actor_device_id: principal.device_id,
            epoch: request.epoch,
            device_ids: request
                .device_ids
                .into_iter()
                .map(|device_id| device_id.0)
                .collect(),
            reserved_key_package_ids,
            commit_message: request
                .commit_message
                .map(decode_control_message)
                .transpose()?,
            welcome_message: request
                .welcome_message
                .map(decode_control_message)
                .transpose()?,
        })
        .await?;

    Ok(Json(ModifyChatDevicesResponse {
        chat_id: trix_types::ChatId(updated.chat_id),
        epoch: updated.epoch,
        changed_device_ids: updated
            .changed_device_ids
            .into_iter()
            .map(trix_types::DeviceId)
            .collect(),
    }))
}

async fn remove_devices(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(chat_id): Path<trix_types::ChatId>,
    Json(request): Json<ModifyChatDevicesRequest>,
) -> Result<Json<ModifyChatDevicesResponse>, AppError> {
    let principal = state.authenticate_active_headers(&headers).await?;
    let reserved_key_package_ids = parse_uuid_list(&request.reserved_key_package_ids)?;
    let updated = state
        .db
        .remove_chat_devices(ModifyChatDevicesInput {
            chat_id: chat_id.0,
            actor_account_id: principal.account_id,
            actor_device_id: principal.device_id,
            epoch: request.epoch,
            device_ids: request
                .device_ids
                .into_iter()
                .map(|device_id| device_id.0)
                .collect(),
            reserved_key_package_ids,
            commit_message: request
                .commit_message
                .map(decode_control_message)
                .transpose()?,
            welcome_message: request
                .welcome_message
                .map(decode_control_message)
                .transpose()?,
        })
        .await?;

    Ok(Json(ModifyChatDevicesResponse {
        chat_id: trix_types::ChatId(updated.chat_id),
        epoch: updated.epoch,
        changed_device_ids: updated
            .changed_device_ids
            .into_iter()
            .map(trix_types::DeviceId)
            .collect(),
    }))
}

fn decode_b64(value: &str) -> Result<Vec<u8>, AppError> {
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

    Err(AppError::bad_request("invalid base64 payload"))
}

fn decode_control_message(message: ControlMessageInput) -> Result<PendingControlMessage, AppError> {
    Ok(PendingControlMessage {
        message_id: message.message_id.0,
        ciphertext: decode_b64(&message.ciphertext_b64)?,
        aad_json: message.aad_json.unwrap_or_default(),
    })
}

fn parse_uuid_list(values: &[String]) -> Result<Vec<uuid::Uuid>, AppError> {
    values
        .iter()
        .map(|value| {
            uuid::Uuid::parse_str(value)
                .map_err(|_| AppError::bad_request("invalid reserved key package id"))
        })
        .collect()
}

pub(super) fn message_to_api(message: MessageEnvelopeRow) -> MessageEnvelope {
    MessageEnvelope {
        message_id: trix_types::MessageId(message.message_id),
        chat_id: trix_types::ChatId(message.chat_id),
        server_seq: message.server_seq,
        sender_account_id: trix_types::AccountId(message.sender_account_id),
        sender_device_id: trix_types::DeviceId(message.sender_device_id),
        epoch: message.epoch,
        message_kind: message.message_kind,
        content_type: message.content_type,
        ciphertext_b64: general_purpose::STANDARD.encode(message.ciphertext),
        aad_json: message.aad_json,
        created_at_unix: message.created_at_unix,
    }
}
