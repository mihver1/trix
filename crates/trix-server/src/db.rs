use std::time::Duration;

use anyhow::{Context, Result};
use sqlx::{PgPool, Row, postgres::PgPoolOptions};
use uuid::Uuid;

use crate::error::AppError;
use trix_types::DeviceStatus;

static MIGRATOR: sqlx::migrate::Migrator = sqlx::migrate!("./../../migrations");

const AUTH_CHALLENGE_TTL_SECONDS: i32 = 5 * 60;

#[derive(Debug, Clone)]
pub struct Database {
    pool: PgPool,
}

#[derive(Debug)]
pub struct CreateAccountInput {
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

#[derive(Debug)]
pub struct CreateAccountOutput {
    pub account_id: Uuid,
    pub device_id: Uuid,
    pub account_sync_chat_id: Uuid,
}

#[derive(Debug)]
pub struct AuthChallengeOutput {
    pub challenge_id: Uuid,
    pub challenge_bytes: Vec<u8>,
    pub expires_at_unix: u64,
}

#[derive(Debug)]
pub struct TakenAuthChallenge {
    pub account_id: Uuid,
    pub device_id: Uuid,
    pub device_status: DeviceStatus,
    pub transport_pubkey: Vec<u8>,
    pub challenge_bytes: Vec<u8>,
}

#[derive(Debug)]
pub struct AccountProfile {
    pub account_id: Uuid,
    pub handle: Option<String>,
    pub profile_name: String,
    pub profile_bio: Option<String>,
    pub device_id: Uuid,
    pub device_status: DeviceStatus,
}

#[derive(Debug)]
pub struct DeviceSummaryRow {
    pub device_id: Uuid,
    pub display_name: String,
    pub platform: String,
    pub device_status: DeviceStatus,
}

impl Database {
    pub async fn connect(database_url: &str) -> Result<Self> {
        let pool = PgPoolOptions::new()
            .max_connections(10)
            .acquire_timeout(Duration::from_secs(5))
            .connect(database_url)
            .await
            .with_context(|| "failed to connect to postgres")?;

        MIGRATOR.run(&pool).await?;

        Ok(Self { pool })
    }

    pub async fn ping(&self) -> Result<()> {
        sqlx::query("SELECT 1").execute(&self.pool).await?;
        Ok(())
    }

    pub async fn create_account(
        &self,
        input: CreateAccountInput,
    ) -> Result<CreateAccountOutput, AppError> {
        let mut tx = self
            .pool
            .begin()
            .await
            .map_err(|err| AppError::internal(format!("failed to begin transaction: {err}")))?;

        let account_row = sqlx::query(
            r#"
            INSERT INTO accounts (handle, profile_name, profile_bio, account_root_pubkey)
            VALUES ($1, $2, $3, $4)
            RETURNING account_id
            "#,
        )
        .bind(input.handle.as_deref())
        .bind(&input.profile_name)
        .bind(input.profile_bio.as_deref())
        .bind(&input.account_root_pubkey)
        .fetch_one(&mut *tx)
        .await
        .map_err(map_db_error)?;
        let account_id: Uuid = account_row
            .try_get("account_id")
            .map_err(|err| AppError::internal(format!("failed to read account id: {err}")))?;

        let device_row = sqlx::query(
            r#"
            INSERT INTO devices (
                account_id,
                display_name,
                platform,
                device_status,
                credential_identity,
                account_root_signature,
                transport_pubkey,
                activated_at
            )
            VALUES ($1, $2, $3, 'active'::device_status, $4, $5, $6, now())
            RETURNING device_id
            "#,
        )
        .bind(account_id)
        .bind(&input.device_display_name)
        .bind(&input.platform)
        .bind(&input.credential_identity)
        .bind(&input.account_root_signature)
        .bind(&input.transport_pubkey)
        .fetch_one(&mut *tx)
        .await
        .map_err(map_db_error)?;
        let device_id: Uuid = device_row
            .try_get("device_id")
            .map_err(|err| AppError::internal(format!("failed to read device id: {err}")))?;

        sqlx::query(
            r#"
            INSERT INTO device_log (account_id, event_type, subject_device_id, actor_device_id, payload_json)
            VALUES
                ($1, 'device_added'::device_log_event_type, $2, $2, '{}'::jsonb),
                ($1, 'device_activated'::device_log_event_type, $2, $2, '{}'::jsonb)
            "#,
        )
        .bind(account_id)
        .bind(device_id)
        .execute(&mut *tx)
        .await
        .map_err(map_db_error)?;

        let chat_row = sqlx::query(
            r#"
            INSERT INTO chats (chat_type, created_by_account_id)
            VALUES ('account_sync'::chat_type, $1)
            RETURNING chat_id
            "#,
        )
        .bind(account_id)
        .fetch_one(&mut *tx)
        .await
        .map_err(map_db_error)?;
        let chat_id: Uuid = chat_row
            .try_get("chat_id")
            .map_err(|err| AppError::internal(format!("failed to read chat id: {err}")))?;

        sqlx::query(
            r#"
            INSERT INTO chat_account_members (chat_id, account_id, role, membership_status)
            VALUES ($1, $2, 'owner'::chat_role, 'active'::membership_status)
            "#,
        )
        .bind(chat_id)
        .bind(account_id)
        .execute(&mut *tx)
        .await
        .map_err(map_db_error)?;

        sqlx::query(
            r#"
            INSERT INTO chat_device_members (chat_id, device_id, leaf_index, membership_status, added_in_epoch)
            VALUES ($1, $2, 0, 'active'::device_membership_status, 0)
            "#,
        )
        .bind(chat_id)
        .bind(device_id)
        .execute(&mut *tx)
        .await
        .map_err(map_db_error)?;

        let group_id_bytes = Uuid::new_v4().as_bytes().to_vec();
        sqlx::query(
            r#"
            INSERT INTO mls_group_states (chat_id, group_id_bytes, epoch, state_status)
            VALUES ($1, $2, 0, 'active'::group_state_status)
            "#,
        )
        .bind(chat_id)
        .bind(group_id_bytes)
        .execute(&mut *tx)
        .await
        .map_err(map_db_error)?;

        tx.commit()
            .await
            .map_err(|err| AppError::internal(format!("failed to commit transaction: {err}")))?;

        Ok(CreateAccountOutput {
            account_id,
            device_id,
            account_sync_chat_id: chat_id,
        })
    }

    pub async fn create_auth_challenge(
        &self,
        device_id: Uuid,
        challenge_bytes: Vec<u8>,
    ) -> Result<AuthChallengeOutput, AppError> {
        let row = sqlx::query(
            r#"
            INSERT INTO auth_challenges (device_id, challenge_bytes, expires_at)
            SELECT d.device_id, $2, now() + make_interval(secs => $3)
            FROM devices d
            WHERE d.device_id = $1 AND d.device_status = 'active'::device_status
            RETURNING challenge_id, extract(epoch from expires_at)::bigint AS expires_at_unix
            "#,
        )
        .bind(device_id)
        .bind(&challenge_bytes)
        .bind(AUTH_CHALLENGE_TTL_SECONDS)
        .fetch_optional(&self.pool)
        .await
        .map_err(map_db_error)?;

        let Some(row) = row else {
            return Err(AppError::not_found("active device not found"));
        };

        let challenge_id: Uuid = row
            .try_get("challenge_id")
            .map_err(|err| AppError::internal(format!("failed to read challenge id: {err}")))?;
        let expires_at_unix: i64 = row
            .try_get("expires_at_unix")
            .map_err(|err| AppError::internal(format!("failed to read challenge expiry: {err}")))?;

        Ok(AuthChallengeOutput {
            challenge_id,
            challenge_bytes,
            expires_at_unix: expires_at_unix as u64,
        })
    }

    pub async fn take_auth_challenge(
        &self,
        challenge_id: Uuid,
        device_id: Uuid,
    ) -> Result<Option<TakenAuthChallenge>, AppError> {
        let row = sqlx::query(
            r#"
            WITH taken AS (
                UPDATE auth_challenges
                SET consumed_at = now()
                WHERE challenge_id = $1
                  AND device_id = $2
                  AND consumed_at IS NULL
                  AND expires_at > now()
                RETURNING device_id, challenge_bytes
            )
            SELECT
                d.account_id,
                d.device_id,
                d.device_status::text AS device_status,
                d.transport_pubkey,
                t.challenge_bytes
            FROM taken t
            JOIN devices d ON d.device_id = t.device_id
            "#,
        )
        .bind(challenge_id)
        .bind(device_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(map_db_error)?;

        let Some(row) = row else {
            return Ok(None);
        };

        let device_status: String = row
            .try_get("device_status")
            .map_err(|err| AppError::internal(format!("failed to read device status: {err}")))?;

        Ok(Some(TakenAuthChallenge {
            account_id: row
                .try_get("account_id")
                .map_err(|err| AppError::internal(format!("failed to read account id: {err}")))?,
            device_id: row
                .try_get("device_id")
                .map_err(|err| AppError::internal(format!("failed to read device id: {err}")))?,
            device_status: parse_device_status(&device_status)?,
            transport_pubkey: row.try_get("transport_pubkey").map_err(|err| {
                AppError::internal(format!("failed to read transport pubkey: {err}"))
            })?,
            challenge_bytes: row.try_get("challenge_bytes").map_err(|err| {
                AppError::internal(format!("failed to read challenge bytes: {err}"))
            })?,
        }))
    }

    pub async fn get_account_profile(
        &self,
        account_id: Uuid,
        device_id: Uuid,
    ) -> Result<Option<AccountProfile>, AppError> {
        let row = sqlx::query(
            r#"
            SELECT
                a.account_id,
                a.handle,
                a.profile_name,
                a.profile_bio,
                d.device_id,
                d.device_status::text AS device_status
            FROM accounts a
            JOIN devices d ON d.account_id = a.account_id
            WHERE a.account_id = $1 AND d.device_id = $2
            "#,
        )
        .bind(account_id)
        .bind(device_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(map_db_error)?;

        let Some(row) = row else {
            return Ok(None);
        };

        let device_status: String = row
            .try_get("device_status")
            .map_err(|err| AppError::internal(format!("failed to read device status: {err}")))?;

        Ok(Some(AccountProfile {
            account_id: row
                .try_get("account_id")
                .map_err(|err| AppError::internal(format!("failed to read account id: {err}")))?,
            handle: row
                .try_get("handle")
                .map_err(|err| AppError::internal(format!("failed to read handle: {err}")))?,
            profile_name: row
                .try_get("profile_name")
                .map_err(|err| AppError::internal(format!("failed to read profile name: {err}")))?,
            profile_bio: row
                .try_get("profile_bio")
                .map_err(|err| AppError::internal(format!("failed to read profile bio: {err}")))?,
            device_id: row
                .try_get("device_id")
                .map_err(|err| AppError::internal(format!("failed to read device id: {err}")))?,
            device_status: parse_device_status(&device_status)?,
        }))
    }

    pub async fn list_devices_for_account(
        &self,
        account_id: Uuid,
    ) -> Result<Vec<DeviceSummaryRow>, AppError> {
        let rows = sqlx::query(
            r#"
            SELECT
                device_id,
                display_name,
                platform,
                device_status::text AS device_status
            FROM devices
            WHERE account_id = $1
            ORDER BY created_at ASC
            "#,
        )
        .bind(account_id)
        .fetch_all(&self.pool)
        .await
        .map_err(map_db_error)?;

        rows.into_iter()
            .map(|row| {
                let device_status: String = row.try_get("device_status").map_err(|err| {
                    AppError::internal(format!("failed to read device status: {err}"))
                })?;

                Ok(DeviceSummaryRow {
                    device_id: row.try_get("device_id").map_err(|err| {
                        AppError::internal(format!("failed to read device id: {err}"))
                    })?,
                    display_name: row.try_get("display_name").map_err(|err| {
                        AppError::internal(format!("failed to read display name: {err}"))
                    })?,
                    platform: row.try_get("platform").map_err(|err| {
                        AppError::internal(format!("failed to read platform: {err}"))
                    })?,
                    device_status: parse_device_status(&device_status)?,
                })
            })
            .collect()
    }
}

fn parse_device_status(value: &str) -> Result<DeviceStatus, AppError> {
    match value {
        "pending" => Ok(DeviceStatus::Pending),
        "active" => Ok(DeviceStatus::Active),
        "revoked" => Ok(DeviceStatus::Revoked),
        other => Err(AppError::internal(format!(
            "unknown device status from database: {other}"
        ))),
    }
}

fn map_db_error(err: sqlx::Error) -> AppError {
    if let sqlx::Error::Database(db_err) = &err {
        if db_err.constraint() == Some("accounts_handle_key") {
            return AppError::conflict("handle is already taken");
        }
    }

    AppError::internal(format!("database error: {err}"))
}
