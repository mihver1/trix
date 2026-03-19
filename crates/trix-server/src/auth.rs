use std::time::{Duration, SystemTime, UNIX_EPOCH};

use axum::http::{HeaderMap, header};
use jsonwebtoken::{Algorithm, DecodingKey, EncodingKey, Header, Validation, decode, encode};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::error::AppError;

const DEFAULT_SESSION_TTL: Duration = Duration::from_secs(60 * 60);

#[derive(Clone)]
pub struct AuthManager {
    encoding_key: EncodingKey,
    decoding_key: DecodingKey,
    session_ttl: Duration,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct JwtClaims {
    sub: String,
    account_id: String,
    device_id: String,
    exp: usize,
}

#[derive(Debug, Clone, Copy)]
pub struct SessionPrincipal {
    pub account_id: Uuid,
    pub device_id: Uuid,
}

impl AuthManager {
    pub fn new(signing_key: impl AsRef<[u8]>) -> Self {
        let signing_key = signing_key.as_ref();

        Self {
            encoding_key: EncodingKey::from_secret(signing_key),
            decoding_key: DecodingKey::from_secret(signing_key),
            session_ttl: DEFAULT_SESSION_TTL,
        }
    }

    pub fn issue_token(
        &self,
        account_id: Uuid,
        device_id: Uuid,
    ) -> Result<(String, u64), AppError> {
        let expires_at = unix_now() + self.session_ttl.as_secs();
        let claims = JwtClaims {
            sub: device_id.to_string(),
            account_id: account_id.to_string(),
            device_id: device_id.to_string(),
            exp: expires_at as usize,
        };

        let token = encode(&Header::new(Algorithm::HS256), &claims, &self.encoding_key)
            .map_err(|err| AppError::internal(format!("failed to encode jwt: {err}")))?;

        Ok((token, expires_at))
    }

    pub fn authenticate_headers(&self, headers: &HeaderMap) -> Result<SessionPrincipal, AppError> {
        let token = bearer_token(headers)?;
        let data = decode::<JwtClaims>(
            token,
            &self.decoding_key,
            &Validation::new(Algorithm::HS256),
        )
        .map_err(|_| AppError::unauthorized("invalid access token"))?;

        let account_id = Uuid::parse_str(&data.claims.account_id)
            .map_err(|_| AppError::unauthorized("invalid access token account"))?;
        let device_id = Uuid::parse_str(&data.claims.device_id)
            .map_err(|_| AppError::unauthorized("invalid access token device"))?;

        Ok(SessionPrincipal {
            account_id,
            device_id,
        })
    }
}

fn bearer_token(headers: &HeaderMap) -> Result<&str, AppError> {
    let value = headers
        .get(header::AUTHORIZATION)
        .ok_or_else(|| AppError::unauthorized("missing authorization header"))?;
    let value = value
        .to_str()
        .map_err(|_| AppError::unauthorized("invalid authorization header"))?;

    value
        .strip_prefix("Bearer ")
        .ok_or_else(|| AppError::unauthorized("expected bearer token"))
}

fn unix_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

#[cfg(test)]
mod tests {
    use axum::http::{HeaderMap, HeaderValue, header};

    use super::*;

    #[test]
    fn jwt_round_trip_authenticates() {
        let manager = AuthManager::new("test-signing-key");
        let account_id = Uuid::new_v4();
        let device_id = Uuid::new_v4();
        let (token, _) = manager.issue_token(account_id, device_id).expect("token");

        let mut headers = HeaderMap::new();
        headers.insert(
            header::AUTHORIZATION,
            HeaderValue::from_str(&format!("Bearer {token}")).expect("header value"),
        );

        let principal = manager
            .authenticate_headers(&headers)
            .expect("principal");

        assert_eq!(principal.account_id, account_id);
        assert_eq!(principal.device_id, device_id);
    }
}
