use axum::{
    Json,
    http::{HeaderValue, StatusCode, header::RETRY_AFTER},
    response::{IntoResponse, Response},
};
use thiserror::Error;
use trix_types::ErrorResponse;

#[derive(Debug, Error)]
pub enum AppError {
    #[error("{0}")]
    BadRequest(String),
    #[error("{0}")]
    Unauthorized(String),
    #[error("{0}")]
    NotFound(String),
    #[error("{0}")]
    Conflict(String),
    #[error("{0}")]
    Internal(String),
    #[error("{0}")]
    NotImplemented(String),
    #[error("{message}")]
    TooManyRequests {
        message: String,
        retry_after_seconds: u64,
    },
}

impl AppError {
    pub fn bad_request(message: impl Into<String>) -> Self {
        Self::BadRequest(message.into())
    }

    pub fn unauthorized(message: impl Into<String>) -> Self {
        Self::Unauthorized(message.into())
    }

    pub fn not_found(message: impl Into<String>) -> Self {
        Self::NotFound(message.into())
    }

    pub fn conflict(message: impl Into<String>) -> Self {
        Self::Conflict(message.into())
    }

    pub fn internal(message: impl Into<String>) -> Self {
        Self::Internal(message.into())
    }

    pub fn not_implemented(message: impl Into<String>) -> Self {
        Self::NotImplemented(message.into())
    }

    pub fn too_many_requests(message: impl Into<String>, retry_after_seconds: u64) -> Self {
        Self::TooManyRequests {
            message: message.into(),
            retry_after_seconds,
        }
    }
}

impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        let (status, code, message, retry_after_seconds) = match self {
            Self::BadRequest(message) => (StatusCode::BAD_REQUEST, "bad_request", message, None),
            Self::Unauthorized(message) => {
                (StatusCode::UNAUTHORIZED, "unauthorized", message, None)
            }
            Self::NotFound(message) => (StatusCode::NOT_FOUND, "not_found", message, None),
            Self::Conflict(message) => (StatusCode::CONFLICT, "conflict", message, None),
            Self::Internal(message) => (
                StatusCode::INTERNAL_SERVER_ERROR,
                "internal_error",
                message,
                None,
            ),
            Self::NotImplemented(message) => (
                StatusCode::NOT_IMPLEMENTED,
                "not_implemented",
                message,
                None,
            ),
            Self::TooManyRequests {
                message,
                retry_after_seconds,
            } => (
                StatusCode::TOO_MANY_REQUESTS,
                "too_many_requests",
                message,
                Some(retry_after_seconds),
            ),
        };

        let mut response = (
            status,
            Json(ErrorResponse {
                code: code.to_owned(),
                message,
            }),
        )
            .into_response();

        if let Some(retry_after_seconds) = retry_after_seconds {
            if let Ok(value) = HeaderValue::from_str(&retry_after_seconds.to_string()) {
                response.headers_mut().insert(RETRY_AFTER, value);
            }
        }

        response
    }
}
