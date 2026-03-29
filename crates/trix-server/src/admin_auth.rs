use std::time::{Duration, SystemTime, UNIX_EPOCH};

use axum::http::{HeaderMap, header};
use jsonwebtoken::{Algorithm, DecodingKey, EncodingKey, Header, Validation, decode, encode};
use serde::{Deserialize, Serialize};

use crate::error::AppError;

#[derive(Debug, Clone, Serialize, Deserialize)]
struct AdminJwtClaims {
    sub: String,
    username: String,
    exp: usize,
}

#[derive(Debug, Clone)]
pub struct AdminPrincipal {
    pub username: String,
    pub expires_at_unix: u64,
}

#[derive(Clone)]
pub struct AdminAuthManager {
    encoding_key: EncodingKey,
    decoding_key: DecodingKey,
    session_ttl: Duration,
}

impl AdminAuthManager {
    pub fn new(signing_key: impl AsRef<[u8]>, session_ttl: Duration) -> Self {
        let signing_key = signing_key.as_ref();
        Self {
            encoding_key: EncodingKey::from_secret(signing_key),
            decoding_key: DecodingKey::from_secret(signing_key),
            session_ttl,
        }
    }

    pub fn issue_token(&self, username: String) -> Result<(String, u64), AppError> {
        let expires_at = unix_now() + self.session_ttl.as_secs();
        let claims = AdminJwtClaims {
            sub: username.clone(),
            username,
            exp: expires_at as usize,
        };

        let token = encode(&Header::new(Algorithm::HS256), &claims, &self.encoding_key)
            .map_err(|err| AppError::internal(format!("failed to encode admin jwt: {err}")))?;

        Ok((token, expires_at))
    }

    pub fn authenticate_headers(&self, headers: &HeaderMap) -> Result<AdminPrincipal, AppError> {
        let token = bearer_token(headers)?;
        let data = decode::<AdminJwtClaims>(
            token,
            &self.decoding_key,
            &Validation::new(Algorithm::HS256),
        )
        .map_err(|_| AppError::unauthorized("invalid admin access token"))?;

        Ok(AdminPrincipal {
            username: data.claims.username,
            expires_at_unix: data.claims.exp as u64,
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
    use std::time::Duration;

    use axum::http::{HeaderMap, HeaderValue, header};

    use super::*;

    #[test]
    fn admin_token_round_trip_authenticates() {
        let manager = AdminAuthManager::new("admin-signing-key", Duration::from_secs(900));
        let (token, _) = manager.issue_token("ops".to_owned()).expect("token");

        let mut headers = HeaderMap::new();
        headers.insert(
            header::AUTHORIZATION,
            HeaderValue::from_str(&format!("Bearer {token}")).unwrap(),
        );

        let principal = manager.authenticate_headers(&headers).expect("principal");
        assert_eq!(principal.username, "ops");
        assert!(principal.expires_at_unix > 0);
    }
}
