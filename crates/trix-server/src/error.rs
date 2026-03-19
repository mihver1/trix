use axum::{
    Json,
    http::StatusCode,
    response::{IntoResponse, Response},
};
use thiserror::Error;
use trix_types::ErrorResponse;

#[derive(Debug, Error)]
pub enum AppError {
    #[error("{0}")]
    Internal(String),
    #[error("{0}")]
    NotImplemented(String),
}

impl AppError {
    pub fn internal(message: impl Into<String>) -> Self {
        Self::Internal(message.into())
    }

    pub fn not_implemented(message: impl Into<String>) -> Self {
        Self::NotImplemented(message.into())
    }
}

impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        let (status, code, message) = match self {
            Self::Internal(message) => {
                (StatusCode::INTERNAL_SERVER_ERROR, "internal_error", message)
            }
            Self::NotImplemented(message) => {
                (StatusCode::NOT_IMPLEMENTED, "not_implemented", message)
            }
        };

        (
            status,
            Json(ErrorResponse {
                code: code.to_owned(),
                message,
            }),
        )
            .into_response()
    }
}
