use axum::{Json, Router, extract::State, routing::post};
use base64::{Engine as _, engine::general_purpose};
use ed25519_dalek::{Signature, Verifier, VerifyingKey};
use uuid::Uuid;

use crate::{error::AppError, state::AppState};
use trix_types::{
    AuthChallengeRequest, AuthChallengeResponse, AuthSessionRequest, AuthSessionResponse,
    DeviceStatus,
};

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/challenge", post(challenge))
        .route("/session", post(session))
}

async fn challenge(
    State(state): State<AppState>,
    Json(request): Json<AuthChallengeRequest>,
) -> Result<Json<AuthChallengeResponse>, AppError> {
    let challenge_bytes: [u8; 32] = rand::random();
    let challenge = state
        .db
        .create_auth_challenge(request.device_id.0, challenge_bytes.to_vec())
        .await?;

    Ok(Json(AuthChallengeResponse {
        challenge_id: challenge.challenge_id.to_string(),
        challenge_b64: general_purpose::STANDARD.encode(challenge.challenge_bytes),
        expires_at_unix: challenge.expires_at_unix,
    }))
}

async fn session(
    State(state): State<AppState>,
    Json(request): Json<AuthSessionRequest>,
) -> Result<Json<AuthSessionResponse>, AppError> {
    let challenge_id = Uuid::parse_str(&request.challenge_id)
        .map_err(|_| AppError::bad_request("invalid challenge id"))?;

    let taken = state
        .db
        .take_auth_challenge(challenge_id, request.device_id.0)
        .await?
        .ok_or_else(|| AppError::unauthorized("invalid or expired challenge"))?;

    if taken.device_status != DeviceStatus::Active {
        return Err(AppError::unauthorized("device is not active"));
    }

    let signature_bytes = decode_b64(&request.signature_b64)?;
    verify_transport_signature(
        &taken.transport_pubkey,
        &taken.challenge_bytes,
        &signature_bytes,
    )?;

    let (access_token, expires_at_unix) =
        state.auth.issue_token(taken.account_id, taken.device_id)?;

    Ok(Json(AuthSessionResponse {
        access_token,
        expires_at_unix,
        account_id: trix_types::AccountId(taken.account_id),
        device_status: taken.device_status,
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

fn verify_transport_signature(
    transport_pubkey: &[u8],
    challenge_bytes: &[u8],
    signature_bytes: &[u8],
) -> Result<(), AppError> {
    let transport_pubkey: [u8; 32] = transport_pubkey
        .try_into()
        .map_err(|_| AppError::bad_request("transport public key must be 32 bytes"))?;
    let verifying_key = VerifyingKey::from_bytes(&transport_pubkey)
        .map_err(|_| AppError::bad_request("invalid transport public key"))?;
    let signature = Signature::from_slice(signature_bytes)
        .map_err(|_| AppError::bad_request("invalid signature length"))?;

    verifying_key
        .verify(challenge_bytes, &signature)
        .map_err(|_| AppError::unauthorized("signature verification failed"))
}

#[cfg(test)]
mod tests {
    use ed25519_dalek::{Signer, SigningKey};

    use super::verify_transport_signature;

    #[test]
    fn verify_transport_signature_accepts_valid_signature() {
        let signing_key = SigningKey::from_bytes(&[11; 32]);
        let challenge = b"test-challenge";
        let signature = signing_key.sign(challenge);

        let result = verify_transport_signature(
            signing_key.verifying_key().as_bytes(),
            challenge,
            &signature.to_bytes(),
        );

        assert!(result.is_ok());
    }
}
