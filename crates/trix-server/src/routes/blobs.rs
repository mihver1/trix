use axum::{
    Json, Router,
    body::{Body, Bytes},
    extract::{Path, State},
    http::{
        HeaderMap, HeaderValue, StatusCode,
        header::{CONTENT_LENGTH, CONTENT_TYPE, ETAG},
    },
    response::{IntoResponse, Response},
    routing::{post, put},
};
use base64::{Engine as _, engine::general_purpose};

use crate::{blobs::LocalBlobStore, db::CreateBlobUploadInput, error::AppError, state::AppState};
use trix_types::{
    BlobMetadataResponse, BlobUploadStatus, CreateBlobUploadRequest, CreateBlobUploadResponse,
};

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/uploads", post(create_upload))
        .route("/{blob_id}", put(put_blob).get(get_blob).head(head_blob))
}

async fn create_upload(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<CreateBlobUploadRequest>,
) -> Result<Json<CreateBlobUploadResponse>, AppError> {
    let principal = state.authenticate_active_headers(&headers).await?;
    state
        .enforce_rate_limit(
            "blob_upload",
            principal.account_id.to_string(),
            state.config.rate_limit_blob_upload_limit,
        )
        .await?;
    let mime_type = request.mime_type.trim().to_owned();
    if mime_type.is_empty() {
        return Err(AppError::bad_request("mime_type must not be empty"));
    }
    if request.size_bytes > state.config.blob_max_upload_bytes {
        return Err(AppError::bad_request(
            "blob exceeds configured upload limit",
        ));
    }

    let sha256 = decode_b64(&request.sha256_b64)?;
    let blob_id = LocalBlobStore::blob_id_from_sha256(&sha256)
        .map_err(|err| AppError::bad_request(format!("invalid blob sha256: {err}")))?;
    let relative_path = LocalBlobStore::relative_path_for_blob_id(&blob_id)
        .map_err(|err| AppError::bad_request(format!("invalid blob id: {err}")))?;

    let created = state
        .db
        .create_blob_upload(CreateBlobUploadInput {
            chat_id: request.chat_id.0,
            creator_account_id: principal.account_id,
            creator_device_id: principal.device_id,
            blob_id: blob_id.clone(),
            relative_path,
            size_bytes: request.size_bytes,
            sha256,
            mime_type,
        })
        .await?;

    let upload_url = format!(
        "{}/v0/blobs/{}",
        state.config.public_base_url.trim_end_matches('/'),
        created.blob_id
    );

    Ok(Json(CreateBlobUploadResponse {
        blob_id: created.blob_id,
        upload_url,
        upload_status: created.upload_status,
        needs_upload: created.upload_status == BlobUploadStatus::PendingUpload,
        max_upload_bytes: state.config.blob_max_upload_bytes,
    }))
}

async fn put_blob(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(blob_id): Path<String>,
    body: Bytes,
) -> Result<Json<BlobMetadataResponse>, AppError> {
    let principal = state.authenticate_active_headers(&headers).await?;
    if body.len() as u64 > state.config.blob_max_upload_bytes {
        return Err(AppError::bad_request(
            "blob exceeds configured upload limit",
        ));
    }

    let metadata = state
        .db
        .get_blob_upload_for_writer(&blob_id, principal.account_id, principal.device_id)
        .await?
        .ok_or_else(|| AppError::not_found("blob upload slot not found"))?;

    if body.len() as u64 != metadata.size_bytes {
        return Err(AppError::bad_request(
            "blob payload size does not match declared size_bytes",
        ));
    }

    if metadata.upload_status == BlobUploadStatus::PendingUpload {
        let stored = state
            .blob_store
            .put_bytes(&blob_id, body.as_ref())
            .await
            .map_err(|err| AppError::bad_request(format!("failed to store blob: {err}")))?;
        if stored.relative_path != metadata.relative_path {
            return Err(AppError::internal(
                "blob storage path did not match reserved metadata path",
            ));
        }
        if stored.size_bytes != metadata.size_bytes {
            return Err(AppError::internal(
                "blob storage size did not match reserved metadata size",
            ));
        }
    } else if !state
        .blob_store
        .exists(&blob_id)
        .await
        .map_err(|err| AppError::internal(format!("failed to stat blob storage: {err}")))?
    {
        return Err(AppError::internal(
            "blob metadata says upload is complete, but blob data is missing",
        ));
    }

    let metadata = state
        .db
        .mark_blob_upload_available(&blob_id, principal.account_id, principal.device_id)
        .await?
        .ok_or_else(|| AppError::not_found("blob upload slot not found"))?;

    Ok(Json(blob_metadata_to_api(metadata)))
}

async fn get_blob(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(blob_id): Path<String>,
) -> Result<Response, AppError> {
    let principal = state.authenticate_active_headers(&headers).await?;
    let metadata = state
        .db
        .get_blob_metadata_for_device(&blob_id, principal.account_id, principal.device_id)
        .await?
        .ok_or_else(|| AppError::not_found("blob not found"))?;

    let bytes = state
        .blob_store
        .get_bytes(&blob_id)
        .await
        .map_err(|err| AppError::internal(format!("failed to read blob data: {err}")))?;

    let mut response = (StatusCode::OK, Body::from(bytes)).into_response();
    apply_blob_headers(response.headers_mut(), &metadata)?;
    Ok(response)
}

async fn head_blob(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(blob_id): Path<String>,
) -> Result<Response, AppError> {
    let principal = state.authenticate_active_headers(&headers).await?;
    let metadata = state
        .db
        .get_blob_metadata_for_device(&blob_id, principal.account_id, principal.device_id)
        .await?
        .ok_or_else(|| AppError::not_found("blob not found"))?;

    let mut response = StatusCode::OK.into_response();
    apply_blob_headers(response.headers_mut(), &metadata)?;
    Ok(response)
}

fn blob_metadata_to_api(metadata: crate::db::BlobMetadataRow) -> BlobMetadataResponse {
    BlobMetadataResponse {
        blob_id: metadata.blob_id,
        mime_type: metadata.mime_type,
        size_bytes: metadata.size_bytes,
        sha256_b64: general_purpose::STANDARD.encode(metadata.sha256),
        upload_status: metadata.upload_status,
        created_by_device_id: trix_types::DeviceId(metadata.created_by_device_id),
    }
}

fn apply_blob_headers(
    headers: &mut HeaderMap,
    metadata: &crate::db::BlobMetadataRow,
) -> Result<(), AppError> {
    headers.insert(
        CONTENT_TYPE,
        HeaderValue::from_static("application/octet-stream"),
    );
    headers.insert(
        CONTENT_LENGTH,
        header_value(&metadata.size_bytes.to_string(), "content length")?,
    );
    headers.insert(
        ETAG,
        header_value(&format!("\"{}\"", metadata.blob_id), "etag")?,
    );
    headers.insert(
        "x-trix-blob-id",
        header_value(&metadata.blob_id, "blob id header")?,
    );
    headers.insert(
        "x-trix-blob-mime-type",
        header_value(&metadata.mime_type, "blob mime header")?,
    );
    headers.insert(
        "x-trix-blob-sha256-b64",
        header_value(
            &general_purpose::STANDARD.encode(&metadata.sha256),
            "blob sha256 header",
        )?,
    );
    headers.insert(
        "x-trix-blob-upload-status",
        HeaderValue::from_static(match metadata.upload_status {
            BlobUploadStatus::PendingUpload => "pending_upload",
            BlobUploadStatus::Available => "available",
        }),
    );
    Ok(())
}

fn header_value(value: &str, field: &str) -> Result<HeaderValue, AppError> {
    HeaderValue::from_str(value)
        .map_err(|err| AppError::internal(format!("failed to build {field}: {err}")))
}

fn decode_b64(value: &str) -> Result<Vec<u8>, AppError> {
    general_purpose::STANDARD
        .decode(value)
        .map_err(|err| AppError::bad_request(format!("invalid base64 payload: {err}")))
}
