use std::{collections::BTreeSet, time::Duration};

use anyhow::{Context, Result};
use serde_json::Value;
use sqlx::{PgPool, Row, postgres::PgPoolOptions};
use uuid::Uuid;

use crate::error::AppError;
use trix_types::{BlobUploadStatus, ChatType, ContentType, DeviceStatus, MessageKind};

static MIGRATOR: sqlx::migrate::Migrator = sqlx::migrate!("./../../migrations");

const AUTH_CHALLENGE_TTL_SECONDS: i32 = 5 * 60;
const KEY_PACKAGE_RESERVATION_TTL_SECONDS: i32 = 15 * 60;
const LINK_INTENT_TTL_SECONDS: i32 = 10 * 60;
const DEFAULT_HISTORY_LIMIT: usize = 100;
const MAX_HISTORY_LIMIT: usize = 500;
const DEFAULT_INBOX_LIMIT: usize = 100;
const MAX_INBOX_LIMIT: usize = 500;

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

#[derive(Debug)]
pub struct CreateLinkIntentOutput {
    pub link_intent_id: Uuid,
    pub link_token: Uuid,
    pub account_id: Uuid,
    pub expires_at_unix: u64,
}

#[derive(Debug)]
pub struct CompleteLinkIntentInput {
    pub link_intent_id: Uuid,
    pub link_token: Uuid,
    pub device_display_name: String,
    pub platform: String,
    pub credential_identity: Vec<u8>,
    pub transport_pubkey: Vec<u8>,
    pub key_packages: Vec<KeyPackageBytesInput>,
}

#[derive(Debug)]
pub struct CompleteLinkIntentOutput {
    pub account_id: Uuid,
    pub pending_device_id: Uuid,
    pub device_status: DeviceStatus,
}

#[derive(Debug)]
pub struct ApprovePendingDeviceInput {
    pub actor_account_id: Uuid,
    pub actor_device_id: Uuid,
    pub target_device_id: Uuid,
    pub account_root_signature: Vec<u8>,
}

#[derive(Debug)]
pub struct ApprovePendingDeviceOutput {
    pub account_id: Uuid,
    pub device_id: Uuid,
    pub device_status: DeviceStatus,
}

#[derive(Debug)]
pub struct PendingDeviceBootstrapRow {
    pub account_id: Uuid,
    pub credential_identity: Vec<u8>,
    pub transport_pubkey: Vec<u8>,
    pub account_root_pubkey: Vec<u8>,
    pub device_status: DeviceStatus,
}

#[derive(Debug)]
pub struct DeviceRevokeContextRow {
    pub account_id: Uuid,
    pub account_root_pubkey: Vec<u8>,
    pub device_status: DeviceStatus,
}

#[derive(Debug)]
pub struct RevokeDeviceInput {
    pub actor_account_id: Uuid,
    pub actor_device_id: Uuid,
    pub target_device_id: Uuid,
    pub reason: String,
}

#[derive(Debug)]
pub struct RevokeDeviceOutput {
    pub account_id: Uuid,
    pub device_id: Uuid,
    pub device_status: DeviceStatus,
}

#[derive(Debug)]
pub struct PublishKeyPackageInput {
    pub device_id: Uuid,
    pub cipher_suite: String,
    pub key_package_bytes: Vec<u8>,
}

#[derive(Debug)]
pub struct KeyPackageBytesInput {
    pub cipher_suite: String,
    pub key_package_bytes: Vec<u8>,
}

#[derive(Debug)]
pub struct PublishedKeyPackageRow {
    pub key_package_id: Uuid,
    pub cipher_suite: String,
}

#[derive(Debug)]
pub struct ReservedKeyPackageRow {
    pub key_package_id: Uuid,
    pub device_id: Uuid,
    pub cipher_suite: String,
    pub key_package_bytes: Vec<u8>,
}

#[derive(Debug)]
pub struct ChatSummaryRow {
    pub chat_id: Uuid,
    pub chat_type: ChatType,
    pub title: Option<String>,
    pub last_server_seq: u64,
}

#[derive(Debug)]
pub struct ChatMemberRow {
    pub account_id: Uuid,
    pub role: String,
    pub membership_status: String,
}

#[derive(Debug)]
pub struct ChatDetail {
    pub chat_id: Uuid,
    pub chat_type: ChatType,
    pub title: Option<String>,
    pub last_server_seq: u64,
    pub epoch: u64,
    pub last_commit_message_id: Option<Uuid>,
    pub members: Vec<ChatMemberRow>,
}

#[derive(Debug)]
pub struct PendingControlMessage {
    pub message_id: Uuid,
    pub ciphertext: Vec<u8>,
    pub aad_json: Value,
}

#[derive(Debug)]
pub struct CreateChatInput {
    pub creator_account_id: Uuid,
    pub creator_device_id: Uuid,
    pub chat_type: ChatType,
    pub title: Option<String>,
    pub participant_account_ids: Vec<Uuid>,
    pub reserved_key_package_ids: Vec<Uuid>,
    pub initial_commit: Option<PendingControlMessage>,
    pub welcome_message: Option<PendingControlMessage>,
}

#[derive(Debug)]
pub struct CreateChatOutput {
    pub chat_id: Uuid,
    pub chat_type: ChatType,
    pub epoch: u64,
}

#[derive(Debug)]
pub struct ModifyChatMembersInput {
    pub chat_id: Uuid,
    pub actor_account_id: Uuid,
    pub actor_device_id: Uuid,
    pub epoch: u64,
    pub participant_account_ids: Vec<Uuid>,
    pub reserved_key_package_ids: Vec<Uuid>,
    pub commit_message: Option<PendingControlMessage>,
    pub welcome_message: Option<PendingControlMessage>,
}

#[derive(Debug)]
pub struct ModifyChatMembersOutput {
    pub chat_id: Uuid,
    pub epoch: u64,
    pub changed_account_ids: Vec<Uuid>,
}

#[derive(Debug)]
pub struct CreateMessageInput {
    pub chat_id: Uuid,
    pub sender_account_id: Uuid,
    pub sender_device_id: Uuid,
    pub message_id: Uuid,
    pub epoch: u64,
    pub message_kind: MessageKind,
    pub content_type: ContentType,
    pub ciphertext: Vec<u8>,
    pub aad_json: Value,
}

#[derive(Debug)]
pub struct CreateMessageOutput {
    pub message_id: Uuid,
    pub server_seq: u64,
}

#[derive(Debug)]
pub struct MessageEnvelopeRow {
    pub message_id: Uuid,
    pub chat_id: Uuid,
    pub server_seq: u64,
    pub sender_account_id: Uuid,
    pub sender_device_id: Uuid,
    pub epoch: u64,
    pub message_kind: MessageKind,
    pub content_type: ContentType,
    pub ciphertext: Vec<u8>,
    pub aad_json: Value,
    pub created_at_unix: u64,
}

#[derive(Debug)]
pub struct InboxItemRow {
    pub inbox_id: u64,
    pub message: MessageEnvelopeRow,
}

#[derive(Debug)]
pub struct CreateBlobUploadInput {
    pub chat_id: Uuid,
    pub creator_account_id: Uuid,
    pub creator_device_id: Uuid,
    pub blob_id: String,
    pub relative_path: String,
    pub size_bytes: u64,
    pub sha256: Vec<u8>,
    pub mime_type: String,
}

#[derive(Debug)]
pub struct CreateBlobUploadOutput {
    pub blob_id: String,
    pub upload_status: BlobUploadStatus,
}

#[derive(Debug)]
pub struct BlobMetadataRow {
    pub blob_id: String,
    pub mime_type: String,
    pub size_bytes: u64,
    pub sha256: Vec<u8>,
    pub upload_status: BlobUploadStatus,
    pub created_by_device_id: Uuid,
    pub relative_path: String,
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
        let account_id: Uuid = row_uuid(&account_row, "account_id")?;

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
        let device_id: Uuid = row_uuid(&device_row, "device_id")?;

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
        let chat_id: Uuid = row_uuid(&chat_row, "chat_id")?;

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

        let challenge_id: Uuid = row_uuid(&row, "challenge_id")?;
        let expires_at_unix = row_u64_from_i64(&row, "expires_at_unix")?;

        Ok(AuthChallengeOutput {
            challenge_id,
            challenge_bytes,
            expires_at_unix,
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

        Ok(Some(TakenAuthChallenge {
            account_id: row_uuid(&row, "account_id")?,
            device_id: row_uuid(&row, "device_id")?,
            device_status: parse_device_status(&row_text(&row, "device_status")?)?,
            transport_pubkey: row_bytes(&row, "transport_pubkey")?,
            challenge_bytes: row_bytes(&row, "challenge_bytes")?,
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

        Ok(Some(AccountProfile {
            account_id: row_uuid(&row, "account_id")?,
            handle: row_optional_text(&row, "handle")?,
            profile_name: row_text(&row, "profile_name")?,
            profile_bio: row_optional_text(&row, "profile_bio")?,
            device_id: row_uuid(&row, "device_id")?,
            device_status: parse_device_status(&row_text(&row, "device_status")?)?,
        }))
    }

    pub async fn ensure_active_device_session(
        &self,
        account_id: Uuid,
        device_id: Uuid,
    ) -> Result<(), AppError> {
        let row = sqlx::query(
            r#"
            SELECT 1
            FROM devices d
            JOIN accounts a
              ON a.account_id = d.account_id
            WHERE d.account_id = $1
              AND d.device_id = $2
              AND d.device_status = 'active'::device_status
              AND a.deleted_at IS NULL
            "#,
        )
        .bind(account_id)
        .bind(device_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(map_db_error)?;

        if row.is_none() {
            return Err(AppError::unauthorized("device session is no longer active"));
        }

        Ok(())
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
                Ok(DeviceSummaryRow {
                    device_id: row_uuid(&row, "device_id")?,
                    display_name: row_text(&row, "display_name")?,
                    platform: row_text(&row, "platform")?,
                    device_status: parse_device_status(&row_text(&row, "device_status")?)?,
                })
            })
            .collect()
    }

    pub async fn create_link_intent(
        &self,
        account_id: Uuid,
        device_id: Uuid,
    ) -> Result<CreateLinkIntentOutput, AppError> {
        let link_token = Uuid::new_v4();
        let row = sqlx::query(
            r#"
            INSERT INTO device_link_intents (
                account_id,
                created_by_device_id,
                link_token,
                status,
                expires_at
            )
            SELECT
                d.account_id,
                d.device_id,
                $3,
                'open'::link_intent_status,
                now() + make_interval(secs => $4)
            FROM devices d
            WHERE d.account_id = $1
              AND d.device_id = $2
              AND d.device_status = 'active'::device_status
            RETURNING
                link_intent_id,
                account_id,
                link_token,
                extract(epoch from expires_at)::bigint AS expires_at_unix
            "#,
        )
        .bind(account_id)
        .bind(device_id)
        .bind(link_token)
        .bind(LINK_INTENT_TTL_SECONDS)
        .fetch_optional(&self.pool)
        .await
        .map_err(map_db_error)?;

        let Some(row) = row else {
            return Err(AppError::not_found("active device not found"));
        };

        Ok(CreateLinkIntentOutput {
            link_intent_id: row_uuid(&row, "link_intent_id")?,
            account_id: row_uuid(&row, "account_id")?,
            link_token: row_uuid(&row, "link_token")?,
            expires_at_unix: row_u64_from_i64(&row, "expires_at_unix")?,
        })
    }

    pub async fn complete_link_intent(
        &self,
        input: CompleteLinkIntentInput,
    ) -> Result<CompleteLinkIntentOutput, AppError> {
        let mut tx = self
            .pool
            .begin()
            .await
            .map_err(|err| AppError::internal(format!("failed to begin transaction: {err}")))?;

        let intent_row = sqlx::query(
            r#"
            SELECT
                account_id,
                status::text AS status,
                pending_device_id
            FROM device_link_intents
            WHERE link_intent_id = $1
              AND link_token = $2
              AND expires_at > now()
            FOR UPDATE
            "#,
        )
        .bind(input.link_intent_id)
        .bind(input.link_token)
        .fetch_optional(&mut *tx)
        .await
        .map_err(map_db_error)?;
        let Some(intent_row) = intent_row else {
            return Err(AppError::not_found("active link intent not found"));
        };

        let status = row_text(&intent_row, "status")?;
        if status != "open" {
            return Err(AppError::conflict(
                "link intent is no longer accepting a new device",
            ));
        }
        if row_optional_uuid(&intent_row, "pending_device_id")?.is_some() {
            return Err(AppError::conflict(
                "link intent already has a pending device",
            ));
        }
        let account_id = row_uuid(&intent_row, "account_id")?;

        let device_row = sqlx::query(
            r#"
            INSERT INTO devices (
                account_id,
                display_name,
                platform,
                device_status,
                credential_identity,
                account_root_signature,
                transport_pubkey
            )
            VALUES (
                $1,
                $2,
                $3,
                'pending'::device_status,
                $4,
                $5,
                $6
            )
            RETURNING device_id
            "#,
        )
        .bind(account_id)
        .bind(&input.device_display_name)
        .bind(&input.platform)
        .bind(&input.credential_identity)
        .bind(Vec::<u8>::new())
        .bind(&input.transport_pubkey)
        .fetch_one(&mut *tx)
        .await
        .map_err(map_db_error)?;
        let pending_device_id = row_uuid(&device_row, "device_id")?;

        sqlx::query(
            r#"
            INSERT INTO device_log (account_id, event_type, subject_device_id, actor_device_id, payload_json)
            VALUES ($1, 'device_added'::device_log_event_type, $2, NULL, '{}'::jsonb)
            "#,
        )
        .bind(account_id)
        .bind(pending_device_id)
        .execute(&mut *tx)
        .await
        .map_err(map_db_error)?;

        insert_device_key_packages_tx(&mut tx, pending_device_id, &input.key_packages).await?;

        sqlx::query(
            r#"
            UPDATE device_link_intents
            SET pending_device_id = $2,
                status = 'pending_approval'::link_intent_status,
                completed_at = now()
            WHERE link_intent_id = $1
            "#,
        )
        .bind(input.link_intent_id)
        .bind(pending_device_id)
        .execute(&mut *tx)
        .await
        .map_err(map_db_error)?;

        tx.commit()
            .await
            .map_err(|err| AppError::internal(format!("failed to commit transaction: {err}")))?;

        Ok(CompleteLinkIntentOutput {
            account_id,
            pending_device_id,
            device_status: DeviceStatus::Pending,
        })
    }

    pub async fn get_pending_device_bootstrap(
        &self,
        target_device_id: Uuid,
    ) -> Result<Option<PendingDeviceBootstrapRow>, AppError> {
        let row = sqlx::query(
            r#"
            SELECT
                d.account_id,
                d.credential_identity,
                d.transport_pubkey,
                d.device_status::text AS device_status,
                a.account_root_pubkey
            FROM devices d
            JOIN accounts a
              ON a.account_id = d.account_id
            WHERE d.device_id = $1
            "#,
        )
        .bind(target_device_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(map_db_error)?;

        let Some(row) = row else {
            return Ok(None);
        };

        Ok(Some(PendingDeviceBootstrapRow {
            account_id: row_uuid(&row, "account_id")?,
            credential_identity: row_bytes(&row, "credential_identity")?,
            transport_pubkey: row_bytes(&row, "transport_pubkey")?,
            account_root_pubkey: row_bytes(&row, "account_root_pubkey")?,
            device_status: parse_device_status(&row_text(&row, "device_status")?)?,
        }))
    }

    pub async fn get_device_revoke_context(
        &self,
        target_device_id: Uuid,
    ) -> Result<Option<DeviceRevokeContextRow>, AppError> {
        let row = sqlx::query(
            r#"
            SELECT
                d.account_id,
                d.device_status::text AS device_status,
                a.account_root_pubkey
            FROM devices d
            JOIN accounts a
              ON a.account_id = d.account_id
            WHERE d.device_id = $1
            "#,
        )
        .bind(target_device_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(map_db_error)?;

        let Some(row) = row else {
            return Ok(None);
        };

        Ok(Some(DeviceRevokeContextRow {
            account_id: row_uuid(&row, "account_id")?,
            account_root_pubkey: row_bytes(&row, "account_root_pubkey")?,
            device_status: parse_device_status(&row_text(&row, "device_status")?)?,
        }))
    }

    pub async fn approve_pending_device(
        &self,
        input: ApprovePendingDeviceInput,
    ) -> Result<ApprovePendingDeviceOutput, AppError> {
        let mut tx = self
            .pool
            .begin()
            .await
            .map_err(|err| AppError::internal(format!("failed to begin transaction: {err}")))?;

        let target_row = sqlx::query(
            r#"
            SELECT
                d.account_id,
                d.device_status::text AS device_status
            FROM devices d
            WHERE d.device_id = $1
            FOR UPDATE
            "#,
        )
        .bind(input.target_device_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(map_db_error)?;
        let Some(target_row) = target_row else {
            return Err(AppError::not_found("target device not found"));
        };

        let target_account_id = row_uuid(&target_row, "account_id")?;
        if target_account_id != input.actor_account_id {
            return Err(AppError::unauthorized(
                "target device does not belong to the authenticated account",
            ));
        }

        if parse_device_status(&row_text(&target_row, "device_status")?)? != DeviceStatus::Pending {
            return Err(AppError::conflict("device is not pending approval"));
        }

        let actor_row = sqlx::query(
            r#"
            SELECT 1
            FROM devices
            WHERE device_id = $1
              AND account_id = $2
              AND device_status = 'active'::device_status
            "#,
        )
        .bind(input.actor_device_id)
        .bind(input.actor_account_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(map_db_error)?;
        if actor_row.is_none() {
            return Err(AppError::unauthorized("active approving device not found"));
        }

        let intent_row = sqlx::query(
            r#"
            UPDATE device_link_intents
            SET status = 'completed'::link_intent_status,
                approved_by_device_id = $2,
                approved_at = now()
            WHERE pending_device_id = $1
              AND status = 'pending_approval'::link_intent_status
            RETURNING account_id
            "#,
        )
        .bind(input.target_device_id)
        .bind(input.actor_device_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(map_db_error)?;
        let Some(intent_row) = intent_row else {
            return Err(AppError::conflict(
                "device does not have a pending link approval",
            ));
        };

        let intent_account_id = row_uuid(&intent_row, "account_id")?;
        if intent_account_id != input.actor_account_id {
            return Err(AppError::unauthorized(
                "link intent does not belong to the authenticated account",
            ));
        }

        sqlx::query(
            r#"
            UPDATE devices
            SET device_status = 'active'::device_status,
                account_root_signature = $2,
                activated_at = now()
            WHERE device_id = $1
            "#,
        )
        .bind(input.target_device_id)
        .bind(&input.account_root_signature)
        .execute(&mut *tx)
        .await
        .map_err(map_db_error)?;

        sqlx::query(
            r#"
            INSERT INTO device_log (account_id, event_type, subject_device_id, actor_device_id, payload_json)
            VALUES ($1, 'device_activated'::device_log_event_type, $2, $3, '{}'::jsonb)
            "#,
        )
        .bind(input.actor_account_id)
        .bind(input.target_device_id)
        .bind(input.actor_device_id)
        .execute(&mut *tx)
        .await
        .map_err(map_db_error)?;

        tx.commit()
            .await
            .map_err(|err| AppError::internal(format!("failed to commit transaction: {err}")))?;

        Ok(ApprovePendingDeviceOutput {
            account_id: input.actor_account_id,
            device_id: input.target_device_id,
            device_status: DeviceStatus::Active,
        })
    }

    pub async fn revoke_device(
        &self,
        input: RevokeDeviceInput,
    ) -> Result<RevokeDeviceOutput, AppError> {
        let mut tx = self
            .pool
            .begin()
            .await
            .map_err(|err| AppError::internal(format!("failed to begin transaction: {err}")))?;

        let actor_row = sqlx::query(
            r#"
            SELECT 1
            FROM devices
            WHERE device_id = $1
              AND account_id = $2
              AND device_status = 'active'::device_status
            "#,
        )
        .bind(input.actor_device_id)
        .bind(input.actor_account_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(map_db_error)?;
        if actor_row.is_none() {
            return Err(AppError::unauthorized("active revoking device not found"));
        }

        if input.target_device_id == input.actor_device_id {
            return Err(AppError::bad_request(
                "self-revocation is not supported through this endpoint",
            ));
        }

        let target_row = sqlx::query(
            r#"
            SELECT account_id, device_status::text AS device_status
            FROM devices
            WHERE device_id = $1
            FOR UPDATE
            "#,
        )
        .bind(input.target_device_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(map_db_error)?;
        let Some(target_row) = target_row else {
            return Err(AppError::not_found("target device not found"));
        };

        let target_account_id = row_uuid(&target_row, "account_id")?;
        if target_account_id != input.actor_account_id {
            return Err(AppError::unauthorized(
                "target device does not belong to the authenticated account",
            ));
        }

        let target_status = parse_device_status(&row_text(&target_row, "device_status")?)?;
        if target_status == DeviceStatus::Revoked {
            return Err(AppError::conflict("device is already revoked"));
        }

        sqlx::query(
            r#"
            UPDATE devices
            SET device_status = 'revoked'::device_status,
                revoked_at = COALESCE(revoked_at, now())
            WHERE device_id = $1
            "#,
        )
        .bind(input.target_device_id)
        .execute(&mut *tx)
        .await
        .map_err(map_db_error)?;

        sqlx::query(
            r#"
            UPDATE device_key_packages
            SET status = 'expired'::key_package_status
            WHERE device_id = $1
              AND status IN ('available'::key_package_status, 'reserved'::key_package_status)
            "#,
        )
        .bind(input.target_device_id)
        .execute(&mut *tx)
        .await
        .map_err(map_db_error)?;

        sqlx::query(
            r#"
            UPDATE device_inbox
            SET delivery_state = 'failed'::delivery_state,
                lease_owner = NULL,
                lease_expires_at = NULL
            WHERE device_id = $1
              AND delivery_state IN ('pending'::delivery_state, 'leased'::delivery_state)
            "#,
        )
        .bind(input.target_device_id)
        .execute(&mut *tx)
        .await
        .map_err(map_db_error)?;

        sqlx::query(
            r#"
            UPDATE chat_device_members cdm
            SET membership_status = 'removed'::device_membership_status,
                removed_in_epoch = COALESCE(cdm.removed_in_epoch, mgs.epoch),
                removed_at = COALESCE(cdm.removed_at, now())
            FROM mls_group_states mgs
            WHERE cdm.chat_id = mgs.chat_id
              AND cdm.device_id = $1
              AND cdm.membership_status <> 'removed'::device_membership_status
            "#,
        )
        .bind(input.target_device_id)
        .execute(&mut *tx)
        .await
        .map_err(map_db_error)?;

        sqlx::query(
            r#"
            UPDATE device_link_intents
            SET status = 'canceled'::link_intent_status
            WHERE status IN ('open'::link_intent_status, 'pending_approval'::link_intent_status)
              AND (created_by_device_id = $1 OR pending_device_id = $1)
            "#,
        )
        .bind(input.target_device_id)
        .execute(&mut *tx)
        .await
        .map_err(map_db_error)?;

        sqlx::query(
            r#"
            INSERT INTO device_log (account_id, event_type, subject_device_id, actor_device_id, payload_json)
            VALUES ($1, 'device_revoked'::device_log_event_type, $2, $3, $4)
            "#,
        )
        .bind(input.actor_account_id)
        .bind(input.target_device_id)
        .bind(input.actor_device_id)
        .bind(serde_json::json!({ "reason": input.reason }))
        .execute(&mut *tx)
        .await
        .map_err(map_db_error)?;

        tx.commit()
            .await
            .map_err(|err| AppError::internal(format!("failed to commit transaction: {err}")))?;

        Ok(RevokeDeviceOutput {
            account_id: input.actor_account_id,
            device_id: input.target_device_id,
            device_status: DeviceStatus::Revoked,
        })
    }

    pub async fn publish_key_packages(
        &self,
        device_id: Uuid,
        packages: Vec<PublishKeyPackageInput>,
    ) -> Result<Vec<PublishedKeyPackageRow>, AppError> {
        if packages.is_empty() {
            return Err(AppError::bad_request(
                "at least one key package is required",
            ));
        }

        let mut tx = self
            .pool
            .begin()
            .await
            .map_err(|err| AppError::internal(format!("failed to begin transaction: {err}")))?;

        let device_row = sqlx::query(
            r#"
            SELECT 1
            FROM devices
            WHERE device_id = $1
              AND device_status = 'active'::device_status
            "#,
        )
        .bind(device_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(map_db_error)?;
        if device_row.is_none() {
            return Err(AppError::not_found("active device not found"));
        }

        let mut published = Vec::with_capacity(packages.len());
        for package in packages {
            let row = sqlx::query(
                r#"
                INSERT INTO device_key_packages (device_id, cipher_suite, key_package_bytes, status)
                VALUES ($1, $2, $3, 'available'::key_package_status)
                RETURNING key_package_id
                "#,
            )
            .bind(device_id)
            .bind(&package.cipher_suite)
            .bind(&package.key_package_bytes)
            .fetch_one(&mut *tx)
            .await
            .map_err(map_db_error)?;

            published.push(PublishedKeyPackageRow {
                key_package_id: row_uuid(&row, "key_package_id")?,
                cipher_suite: package.cipher_suite,
            });
        }

        tx.commit()
            .await
            .map_err(|err| AppError::internal(format!("failed to commit transaction: {err}")))?;

        Ok(published)
    }

    pub async fn reserve_key_packages_for_account(
        &self,
        reserved_by_account_id: Uuid,
        account_id: Uuid,
    ) -> Result<Vec<ReservedKeyPackageRow>, AppError> {
        let mut tx = self
            .pool
            .begin()
            .await
            .map_err(|err| AppError::internal(format!("failed to begin transaction: {err}")))?;

        let account_row = sqlx::query(
            r#"
            SELECT 1
            FROM accounts
            WHERE account_id = $1
              AND deleted_at IS NULL
            "#,
        )
        .bind(account_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(map_db_error)?;
        if account_row.is_none() {
            return Err(AppError::not_found("account not found"));
        }

        let device_rows = sqlx::query(
            r#"
            SELECT device_id
            FROM devices
            WHERE account_id = $1
              AND device_status = 'active'::device_status
            ORDER BY created_at ASC, device_id ASC
            "#,
        )
        .bind(account_id)
        .fetch_all(&mut *tx)
        .await
        .map_err(map_db_error)?;

        if device_rows.is_empty() {
            return Err(AppError::conflict("account has no active devices"));
        }

        let mut reserved = Vec::with_capacity(device_rows.len());
        for device_row in device_rows {
            let device_id = row_uuid(&device_row, "device_id")?;
            let reserved_row = sqlx::query(
                r#"
                WITH candidate AS (
                    SELECT key_package_id
                    FROM device_key_packages
                    WHERE device_id = $1
                      AND (
                        status = 'available'::key_package_status
                        OR (
                            status = 'reserved'::key_package_status
                            AND reserved_at < now() - make_interval(secs => $2)
                        )
                      )
                    ORDER BY
                        CASE
                            WHEN status = 'available'::key_package_status THEN 0
                            ELSE 1
                        END,
                        published_at ASC,
                        key_package_id ASC
                    LIMIT 1
                    FOR UPDATE SKIP LOCKED
                )
                UPDATE device_key_packages kp
                SET status = 'reserved'::key_package_status,
                    reserved_at = now(),
                    reserved_by_account_id = $3
                FROM candidate
                WHERE kp.key_package_id = candidate.key_package_id
                RETURNING kp.key_package_id, kp.device_id, kp.cipher_suite, kp.key_package_bytes
                "#,
            )
            .bind(device_id)
            .bind(KEY_PACKAGE_RESERVATION_TTL_SECONDS)
            .bind(reserved_by_account_id)
            .fetch_optional(&mut *tx)
            .await
            .map_err(map_db_error)?;

            let Some(reserved_row) = reserved_row else {
                return Err(AppError::conflict(
                    "one or more active devices have no available key packages",
                ));
            };

            reserved.push(ReservedKeyPackageRow {
                key_package_id: row_uuid(&reserved_row, "key_package_id")?,
                device_id: row_uuid(&reserved_row, "device_id")?,
                cipher_suite: row_text(&reserved_row, "cipher_suite")?,
                key_package_bytes: row_bytes(&reserved_row, "key_package_bytes")?,
            });
        }

        tx.commit()
            .await
            .map_err(|err| AppError::internal(format!("failed to commit transaction: {err}")))?;

        Ok(reserved)
    }

    pub async fn create_blob_upload(
        &self,
        input: CreateBlobUploadInput,
    ) -> Result<CreateBlobUploadOutput, AppError> {
        let mut tx = self
            .pool
            .begin()
            .await
            .map_err(|err| AppError::internal(format!("failed to begin transaction: {err}")))?;

        let membership_row = sqlx::query(
            r#"
            SELECT 1
            FROM chat_device_members cdm
            JOIN devices d
              ON d.device_id = cdm.device_id
            WHERE cdm.chat_id = $1
              AND cdm.device_id = $2
              AND cdm.membership_status = 'active'::device_membership_status
              AND d.account_id = $3
              AND d.device_status = 'active'::device_status
            "#,
        )
        .bind(input.chat_id)
        .bind(input.creator_device_id)
        .bind(input.creator_account_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(map_db_error)?;
        if membership_row.is_none() {
            return Err(AppError::not_found("active chat membership not found"));
        }

        sqlx::query(
            r#"
            INSERT INTO attachment_blobs (
                blob_id,
                storage_backend,
                relative_path,
                size_bytes,
                sha256,
                mime_type,
                created_by_device_id,
                upload_status
            )
            VALUES (
                $1,
                'local_fs'::storage_backend,
                $2,
                $3,
                $4,
                $5,
                $6,
                'pending_upload'::blob_upload_status
            )
            ON CONFLICT (blob_id) DO NOTHING
            "#,
        )
        .bind(&input.blob_id)
        .bind(&input.relative_path)
        .bind(u64_to_i64(input.size_bytes, "size_bytes")?)
        .bind(&input.sha256)
        .bind(&input.mime_type)
        .bind(input.creator_device_id)
        .execute(&mut *tx)
        .await
        .map_err(map_db_error)?;

        let blob_row = sqlx::query(
            r#"
            SELECT
                blob_id,
                relative_path,
                size_bytes,
                sha256,
                mime_type,
                created_by_device_id,
                upload_status::text AS upload_status
            FROM attachment_blobs
            WHERE blob_id = $1
              AND deleted_at IS NULL
            FOR UPDATE
            "#,
        )
        .bind(&input.blob_id)
        .fetch_one(&mut *tx)
        .await
        .map_err(map_db_error)?;

        let existing_size_bytes = row_u64_from_i64(&blob_row, "size_bytes")?;
        let existing_sha256 = row_bytes(&blob_row, "sha256")?;
        let existing_mime_type = row_text(&blob_row, "mime_type")?;
        let existing_creator_device_id = row_uuid(&blob_row, "created_by_device_id")?;
        let upload_status = parse_blob_upload_status(&row_text(&blob_row, "upload_status")?)?;
        let existing_relative_path = row_text(&blob_row, "relative_path")?;

        if existing_size_bytes != input.size_bytes
            || existing_sha256 != input.sha256
            || existing_mime_type != input.mime_type
        {
            return Err(AppError::conflict(
                "blob already exists with different metadata",
            ));
        }

        if existing_relative_path != input.relative_path {
            return Err(AppError::conflict(
                "blob already exists with different storage layout",
            ));
        }

        if upload_status == BlobUploadStatus::PendingUpload
            && existing_creator_device_id != input.creator_device_id
        {
            return Err(AppError::conflict(
                "blob upload is already owned by another device",
            ));
        }

        sqlx::query(
            r#"
            INSERT INTO attachment_blob_chat_refs (blob_id, chat_id)
            VALUES ($1, $2)
            ON CONFLICT (blob_id, chat_id) DO NOTHING
            "#,
        )
        .bind(&input.blob_id)
        .bind(input.chat_id)
        .execute(&mut *tx)
        .await
        .map_err(map_db_error)?;

        tx.commit()
            .await
            .map_err(|err| AppError::internal(format!("failed to commit transaction: {err}")))?;

        Ok(CreateBlobUploadOutput {
            blob_id: input.blob_id,
            upload_status,
        })
    }

    pub async fn get_blob_upload_for_writer(
        &self,
        blob_id: &str,
        account_id: Uuid,
        device_id: Uuid,
    ) -> Result<Option<BlobMetadataRow>, AppError> {
        let row = sqlx::query(
            r#"
            SELECT
                ab.blob_id,
                ab.relative_path,
                ab.size_bytes,
                ab.sha256,
                ab.mime_type,
                ab.created_by_device_id,
                ab.upload_status::text AS upload_status
            FROM attachment_blobs ab
            JOIN devices d
              ON d.device_id = ab.created_by_device_id
            WHERE ab.blob_id = $1
              AND ab.deleted_at IS NULL
              AND ab.created_by_device_id = $2
              AND d.account_id = $3
              AND d.device_status = 'active'::device_status
              AND EXISTS (
                  SELECT 1
                  FROM attachment_blob_chat_refs ref
                  JOIN chat_device_members cdm
                    ON cdm.chat_id = ref.chat_id
                  WHERE ref.blob_id = ab.blob_id
                    AND cdm.device_id = $2
                    AND cdm.membership_status = 'active'::device_membership_status
              )
            LIMIT 1
            "#,
        )
        .bind(blob_id)
        .bind(device_id)
        .bind(account_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(map_db_error)?;

        row.map(blob_metadata_row_from_db).transpose()
    }

    pub async fn mark_blob_upload_available(
        &self,
        blob_id: &str,
        account_id: Uuid,
        device_id: Uuid,
    ) -> Result<Option<BlobMetadataRow>, AppError> {
        let row = sqlx::query(
            r#"
            UPDATE attachment_blobs ab
            SET upload_status = 'available'::blob_upload_status,
                upload_completed_at = COALESCE(ab.upload_completed_at, now())
            WHERE ab.blob_id = $1
              AND ab.deleted_at IS NULL
              AND ab.created_by_device_id = $2
              AND EXISTS (
                  SELECT 1
                  FROM devices d
                  WHERE d.device_id = ab.created_by_device_id
                    AND d.account_id = $3
                    AND d.device_status = 'active'::device_status
              )
              AND EXISTS (
                  SELECT 1
                  FROM attachment_blob_chat_refs ref
                  JOIN chat_device_members cdm
                    ON cdm.chat_id = ref.chat_id
                  WHERE ref.blob_id = ab.blob_id
                    AND cdm.device_id = $2
                    AND cdm.membership_status = 'active'::device_membership_status
              )
            RETURNING
                ab.blob_id,
                ab.relative_path,
                ab.size_bytes,
                ab.sha256,
                ab.mime_type,
                ab.created_by_device_id,
                ab.upload_status::text AS upload_status
            "#,
        )
        .bind(blob_id)
        .bind(device_id)
        .bind(account_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(map_db_error)?;

        row.map(blob_metadata_row_from_db).transpose()
    }

    pub async fn get_blob_metadata_for_device(
        &self,
        blob_id: &str,
        account_id: Uuid,
        device_id: Uuid,
    ) -> Result<Option<BlobMetadataRow>, AppError> {
        let row = sqlx::query(
            r#"
            SELECT DISTINCT ON (ab.blob_id)
                ab.blob_id,
                ab.relative_path,
                ab.size_bytes,
                ab.sha256,
                ab.mime_type,
                ab.created_by_device_id,
                ab.upload_status::text AS upload_status
            FROM attachment_blobs ab
            JOIN attachment_blob_chat_refs ref
              ON ref.blob_id = ab.blob_id
            JOIN chat_device_members cdm
              ON cdm.chat_id = ref.chat_id
            JOIN devices d
              ON d.device_id = cdm.device_id
            WHERE ab.blob_id = $1
              AND ab.deleted_at IS NULL
              AND ab.upload_status = 'available'::blob_upload_status
              AND cdm.device_id = $2
              AND cdm.membership_status = 'active'::device_membership_status
              AND d.account_id = $3
              AND d.device_status = 'active'::device_status
            "#,
        )
        .bind(blob_id)
        .bind(device_id)
        .bind(account_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(map_db_error)?;

        row.map(blob_metadata_row_from_db).transpose()
    }

    pub async fn list_chats_for_device(
        &self,
        account_id: Uuid,
        device_id: Uuid,
    ) -> Result<Vec<ChatSummaryRow>, AppError> {
        let rows = sqlx::query(
            r#"
            SELECT
                c.chat_id,
                c.chat_type::text AS chat_type,
                c.title,
                c.last_server_seq
            FROM chats c
            JOIN chat_account_members cam
              ON cam.chat_id = c.chat_id
            JOIN chat_device_members cdm
              ON cdm.chat_id = c.chat_id
            WHERE cam.account_id = $1
              AND cam.membership_status = 'active'::membership_status
              AND cdm.device_id = $2
              AND cdm.membership_status = 'active'::device_membership_status
              AND c.archived_at IS NULL
              AND c.chat_type <> 'account_sync'::chat_type
            ORDER BY c.last_server_seq DESC, c.created_at DESC
            "#,
        )
        .bind(account_id)
        .bind(device_id)
        .fetch_all(&self.pool)
        .await
        .map_err(map_db_error)?;

        rows.into_iter()
            .map(|row| {
                Ok(ChatSummaryRow {
                    chat_id: row_uuid(&row, "chat_id")?,
                    chat_type: parse_chat_type(&row_text(&row, "chat_type")?)?,
                    title: row_optional_text(&row, "title")?,
                    last_server_seq: row_u64_from_i64(&row, "last_server_seq")?,
                })
            })
            .collect()
    }

    pub async fn create_chat(&self, input: CreateChatInput) -> Result<CreateChatOutput, AppError> {
        if input.chat_type == ChatType::AccountSync {
            return Err(AppError::bad_request(
                "account sync chats are created internally",
            ));
        }

        let mut target_account_ids = BTreeSet::new();
        target_account_ids.extend(
            input
                .participant_account_ids
                .into_iter()
                .filter(|account_id| *account_id != input.creator_account_id),
        );
        let target_account_ids: Vec<Uuid> = target_account_ids.into_iter().collect();

        let mut participant_account_ids = BTreeSet::new();
        participant_account_ids.insert(input.creator_account_id);
        participant_account_ids.extend(target_account_ids.iter().copied());
        let participant_account_ids: Vec<Uuid> = participant_account_ids.into_iter().collect();

        match input.chat_type {
            ChatType::Dm if participant_account_ids.len() != 2 => {
                return Err(AppError::bad_request(
                    "dm chats require exactly two unique accounts",
                ));
            }
            ChatType::Group if participant_account_ids.len() < 2 => {
                return Err(AppError::bad_request(
                    "group chats require at least two unique accounts",
                ));
            }
            ChatType::AccountSync => unreachable!(),
            ChatType::Dm | ChatType::Group => {}
        }

        let mut tx = self
            .pool
            .begin()
            .await
            .map_err(|err| AppError::internal(format!("failed to begin transaction: {err}")))?;

        let creator_row = sqlx::query(
            r#"
            SELECT 1
            FROM devices
            WHERE device_id = $1
              AND account_id = $2
              AND device_status = 'active'::device_status
            "#,
        )
        .bind(input.creator_device_id)
        .bind(input.creator_account_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(map_db_error)?;
        if creator_row.is_none() {
            return Err(AppError::unauthorized("active creator device not found"));
        }

        let account_rows = sqlx::query(
            r#"
            SELECT account_id
            FROM accounts
            WHERE deleted_at IS NULL
              AND account_id = ANY($1)
            "#,
        )
        .bind(&participant_account_ids)
        .fetch_all(&mut *tx)
        .await
        .map_err(map_db_error)?;
        let existing_accounts: BTreeSet<Uuid> = account_rows
            .into_iter()
            .map(|row| row_uuid(&row, "account_id"))
            .collect::<Result<_, _>>()?;

        if existing_accounts.len() != participant_account_ids.len() {
            return Err(AppError::not_found(
                "one or more participant accounts were not found",
            ));
        }

        let active_device_rows = sqlx::query(
            r#"
            SELECT device_id, account_id
            FROM devices
            WHERE account_id = ANY($1)
              AND device_status = 'active'::device_status
            ORDER BY account_id ASC, created_at ASC, device_id ASC
            "#,
        )
        .bind(&participant_account_ids)
        .fetch_all(&mut *tx)
        .await
        .map_err(map_db_error)?;

        let active_device_accounts: BTreeSet<Uuid> = active_device_rows
            .iter()
            .map(|row| row_uuid(row, "account_id"))
            .collect::<Result<_, _>>()?;

        if active_device_accounts.len() != participant_account_ids.len() {
            return Err(AppError::conflict(
                "one or more participant accounts have no active devices",
            ));
        }

        let chat_row = sqlx::query(
            r#"
            INSERT INTO chats (chat_type, title, created_by_account_id)
            VALUES ($1::chat_type, $2, $3)
            RETURNING chat_id
            "#,
        )
        .bind(chat_type_db(input.chat_type))
        .bind(input.title.as_deref())
        .bind(input.creator_account_id)
        .fetch_one(&mut *tx)
        .await
        .map_err(map_db_error)?;
        let chat_id = row_uuid(&chat_row, "chat_id")?;

        for account_id in &participant_account_ids {
            sqlx::query(
                r#"
                INSERT INTO chat_account_members (chat_id, account_id, role, membership_status)
                VALUES ($1, $2, $3::chat_role, 'active'::membership_status)
                "#,
            )
            .bind(chat_id)
            .bind(*account_id)
            .bind(if *account_id == input.creator_account_id {
                "owner"
            } else {
                "member"
            })
            .execute(&mut *tx)
            .await
            .map_err(map_db_error)?;
        }

        for (leaf_index, row) in active_device_rows.into_iter().enumerate() {
            sqlx::query(
                r#"
                INSERT INTO chat_device_members (chat_id, device_id, leaf_index, membership_status, added_in_epoch)
                VALUES ($1, $2, $3, 'active'::device_membership_status, 0)
                "#,
            )
            .bind(chat_id)
            .bind(row_uuid(&row, "device_id")?)
            .bind(leaf_index as i32)
            .execute(&mut *tx)
            .await
            .map_err(map_db_error)?;
        }

        sqlx::query(
            r#"
            INSERT INTO mls_group_states (chat_id, group_id_bytes, epoch, state_status)
            VALUES ($1, $2, 0, 'active'::group_state_status)
            "#,
        )
        .bind(chat_id)
        .bind(Uuid::new_v4().as_bytes().to_vec())
        .execute(&mut *tx)
        .await
        .map_err(map_db_error)?;

        consume_reserved_key_packages_tx(
            &mut tx,
            input.creator_account_id,
            chat_id,
            &target_account_ids,
            &input.reserved_key_package_ids,
        )
        .await?;

        if let Some(commit) = input.initial_commit {
            let commit_message_id = commit.message_id;
            let recipients =
                active_chat_device_ids_tx(&mut tx, chat_id, input.creator_device_id, None).await?;
            insert_control_message_tx(
                &mut tx,
                chat_id,
                input.creator_account_id,
                input.creator_device_id,
                0,
                MessageKind::Commit,
                commit,
                &recipients,
            )
            .await?;
            set_last_commit_message_id_tx(&mut tx, chat_id, commit_message_id).await?;
        }

        if let Some(welcome) = input.welcome_message {
            let recipients =
                active_chat_device_ids_tx(&mut tx, chat_id, input.creator_device_id, None).await?;
            insert_control_message_tx(
                &mut tx,
                chat_id,
                input.creator_account_id,
                input.creator_device_id,
                0,
                MessageKind::WelcomeRef,
                welcome,
                &recipients,
            )
            .await?;
        }

        tx.commit()
            .await
            .map_err(|err| AppError::internal(format!("failed to commit transaction: {err}")))?;

        Ok(CreateChatOutput {
            chat_id,
            chat_type: input.chat_type,
            epoch: 0,
        })
    }

    pub async fn add_chat_members(
        &self,
        input: ModifyChatMembersInput,
    ) -> Result<ModifyChatMembersOutput, AppError> {
        let mut target_account_ids = BTreeSet::new();
        target_account_ids.extend(input.participant_account_ids);
        if target_account_ids.is_empty() {
            return Err(AppError::bad_request(
                "at least one participant account is required",
            ));
        }

        if target_account_ids.contains(&input.actor_account_id) {
            return Err(AppError::bad_request("cannot add the acting account"));
        }

        let target_account_ids: Vec<Uuid> = target_account_ids.into_iter().collect();
        let mut tx = self
            .pool
            .begin()
            .await
            .map_err(|err| AppError::internal(format!("failed to begin transaction: {err}")))?;

        let actor_row = sqlx::query(
            r#"
            SELECT
                c.chat_type::text AS chat_type,
                mgs.epoch,
                cam.role::text AS role
            FROM chats c
            JOIN mls_group_states mgs
              ON mgs.chat_id = c.chat_id
            JOIN chat_account_members cam
              ON cam.chat_id = c.chat_id
            JOIN chat_device_members cdm
              ON cdm.chat_id = c.chat_id
            JOIN devices d
              ON d.device_id = cdm.device_id
            WHERE c.chat_id = $1
              AND cam.account_id = $2
              AND cam.membership_status = 'active'::membership_status
              AND cdm.device_id = $3
              AND cdm.membership_status = 'active'::device_membership_status
              AND d.account_id = $2
              AND d.device_status = 'active'::device_status
            "#,
        )
        .bind(input.chat_id)
        .bind(input.actor_account_id)
        .bind(input.actor_device_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(map_db_error)?;

        let Some(actor_row) = actor_row else {
            return Err(AppError::not_found("active chat membership not found"));
        };

        let chat_type = parse_chat_type(&row_text(&actor_row, "chat_type")?)?;
        if chat_type != ChatType::Group {
            return Err(AppError::bad_request(
                "member changes are only supported for group chats",
            ));
        }

        if row_text(&actor_row, "role")? != "owner" {
            return Err(AppError::unauthorized(
                "only chat owners can change membership",
            ));
        }

        let current_epoch = row_u64_from_i64(&actor_row, "epoch")?;
        if current_epoch != input.epoch {
            return Err(AppError::conflict("chat epoch is out of date"));
        }

        let target_account_rows = sqlx::query(
            r#"
            SELECT account_id
            FROM accounts
            WHERE account_id = ANY($1)
              AND deleted_at IS NULL
            "#,
        )
        .bind(&target_account_ids)
        .fetch_all(&mut *tx)
        .await
        .map_err(map_db_error)?;
        let existing_accounts: BTreeSet<Uuid> = target_account_rows
            .into_iter()
            .map(|row| row_uuid(&row, "account_id"))
            .collect::<Result<_, _>>()?;
        if existing_accounts.len() != target_account_ids.len() {
            return Err(AppError::not_found(
                "one or more participant accounts were not found",
            ));
        }

        let existing_member_rows = sqlx::query(
            r#"
            SELECT account_id, membership_status::text AS membership_status
            FROM chat_account_members
            WHERE chat_id = $1
              AND account_id = ANY($2)
            "#,
        )
        .bind(input.chat_id)
        .bind(&target_account_ids)
        .fetch_all(&mut *tx)
        .await
        .map_err(map_db_error)?;
        for row in existing_member_rows {
            if row_text(&row, "membership_status")? == "active" {
                return Err(AppError::conflict(
                    "one or more participant accounts are already active members",
                ));
            }
        }

        let active_device_rows = sqlx::query(
            r#"
            SELECT device_id, account_id
            FROM devices
            WHERE account_id = ANY($1)
              AND device_status = 'active'::device_status
            ORDER BY account_id ASC, created_at ASC, device_id ASC
            "#,
        )
        .bind(&target_account_ids)
        .fetch_all(&mut *tx)
        .await
        .map_err(map_db_error)?;

        let active_device_accounts: BTreeSet<Uuid> = active_device_rows
            .iter()
            .map(|row| row_uuid(row, "account_id"))
            .collect::<Result<_, _>>()?;
        if active_device_accounts.len() != target_account_ids.len() {
            return Err(AppError::conflict(
                "one or more participant accounts have no active devices",
            ));
        }

        let next_epoch = current_epoch + 1;
        consume_reserved_key_packages_tx(
            &mut tx,
            input.actor_account_id,
            input.chat_id,
            &target_account_ids,
            &input.reserved_key_package_ids,
        )
        .await?;

        for account_id in &target_account_ids {
            sqlx::query(
                r#"
                INSERT INTO chat_account_members (chat_id, account_id, role, membership_status)
                VALUES ($1, $2, 'member'::chat_role, 'active'::membership_status)
                ON CONFLICT (chat_id, account_id) DO UPDATE
                SET role = 'member'::chat_role,
                    membership_status = 'active'::membership_status,
                    joined_at = now(),
                    left_at = NULL
                "#,
            )
            .bind(input.chat_id)
            .bind(*account_id)
            .execute(&mut *tx)
            .await
            .map_err(map_db_error)?;
        }

        let leaf_index_row = sqlx::query(
            r#"
            SELECT COALESCE(MAX(leaf_index), -1) AS max_leaf_index
            FROM chat_device_members
            WHERE chat_id = $1
            "#,
        )
        .bind(input.chat_id)
        .fetch_one(&mut *tx)
        .await
        .map_err(map_db_error)?;
        let mut next_leaf_index = row_i32(&leaf_index_row, "max_leaf_index")? + 1;

        for row in active_device_rows {
            let device_id = row_uuid(&row, "device_id")?;
            sqlx::query(
                r#"
                INSERT INTO chat_device_members (chat_id, device_id, leaf_index, membership_status, added_in_epoch, removed_in_epoch, joined_at, removed_at)
                VALUES ($1, $2, $3, 'active'::device_membership_status, $4, NULL, now(), NULL)
                ON CONFLICT (chat_id, device_id) DO UPDATE
                SET leaf_index = EXCLUDED.leaf_index,
                    membership_status = 'active'::device_membership_status,
                    added_in_epoch = EXCLUDED.added_in_epoch,
                    removed_in_epoch = NULL,
                    joined_at = now(),
                    removed_at = NULL
                "#,
            )
            .bind(input.chat_id)
            .bind(device_id)
            .bind(next_leaf_index)
            .bind(u64_to_i64(next_epoch, "next epoch")?)
            .execute(&mut *tx)
            .await
            .map_err(map_db_error)?;
            next_leaf_index += 1;
        }

        sqlx::query(
            r#"
            UPDATE mls_group_states
            SET epoch = $2,
                updated_at = now()
            WHERE chat_id = $1
            "#,
        )
        .bind(input.chat_id)
        .bind(u64_to_i64(next_epoch, "next epoch")?)
        .execute(&mut *tx)
        .await
        .map_err(map_db_error)?;

        if let Some(commit) = input.commit_message {
            let commit_message_id = commit.message_id;
            let recipients =
                active_chat_device_ids_tx(&mut tx, input.chat_id, input.actor_device_id, None)
                    .await?;
            insert_control_message_tx(
                &mut tx,
                input.chat_id,
                input.actor_account_id,
                input.actor_device_id,
                next_epoch,
                MessageKind::Commit,
                commit,
                &recipients,
            )
            .await?;
            set_last_commit_message_id_tx(&mut tx, input.chat_id, commit_message_id).await?;
        }

        if let Some(welcome) = input.welcome_message {
            let recipients = active_chat_device_ids_tx(
                &mut tx,
                input.chat_id,
                input.actor_device_id,
                Some(&target_account_ids),
            )
            .await?;
            insert_control_message_tx(
                &mut tx,
                input.chat_id,
                input.actor_account_id,
                input.actor_device_id,
                next_epoch,
                MessageKind::WelcomeRef,
                welcome,
                &recipients,
            )
            .await?;
        }

        tx.commit()
            .await
            .map_err(|err| AppError::internal(format!("failed to commit transaction: {err}")))?;

        Ok(ModifyChatMembersOutput {
            chat_id: input.chat_id,
            epoch: next_epoch,
            changed_account_ids: target_account_ids,
        })
    }

    pub async fn remove_chat_members(
        &self,
        input: ModifyChatMembersInput,
    ) -> Result<ModifyChatMembersOutput, AppError> {
        if input.welcome_message.is_some() {
            return Err(AppError::bad_request(
                "welcome message is not valid for member removal",
            ));
        }
        if !input.reserved_key_package_ids.is_empty() {
            return Err(AppError::bad_request(
                "reserved key package ids are not valid for member removal",
            ));
        }

        let mut target_account_ids = BTreeSet::new();
        target_account_ids.extend(input.participant_account_ids);
        if target_account_ids.is_empty() {
            return Err(AppError::bad_request(
                "at least one participant account is required",
            ));
        }

        if target_account_ids.contains(&input.actor_account_id) {
            return Err(AppError::bad_request(
                "cannot remove the acting account through this endpoint",
            ));
        }

        let target_account_ids: Vec<Uuid> = target_account_ids.into_iter().collect();
        let mut tx = self
            .pool
            .begin()
            .await
            .map_err(|err| AppError::internal(format!("failed to begin transaction: {err}")))?;

        let actor_row = sqlx::query(
            r#"
            SELECT
                c.chat_type::text AS chat_type,
                mgs.epoch,
                cam.role::text AS role
            FROM chats c
            JOIN mls_group_states mgs
              ON mgs.chat_id = c.chat_id
            JOIN chat_account_members cam
              ON cam.chat_id = c.chat_id
            JOIN chat_device_members cdm
              ON cdm.chat_id = c.chat_id
            JOIN devices d
              ON d.device_id = cdm.device_id
            WHERE c.chat_id = $1
              AND cam.account_id = $2
              AND cam.membership_status = 'active'::membership_status
              AND cdm.device_id = $3
              AND cdm.membership_status = 'active'::device_membership_status
              AND d.account_id = $2
              AND d.device_status = 'active'::device_status
            "#,
        )
        .bind(input.chat_id)
        .bind(input.actor_account_id)
        .bind(input.actor_device_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(map_db_error)?;

        let Some(actor_row) = actor_row else {
            return Err(AppError::not_found("active chat membership not found"));
        };

        let chat_type = parse_chat_type(&row_text(&actor_row, "chat_type")?)?;
        if chat_type != ChatType::Group {
            return Err(AppError::bad_request(
                "member changes are only supported for group chats",
            ));
        }

        if row_text(&actor_row, "role")? != "owner" {
            return Err(AppError::unauthorized(
                "only chat owners can change membership",
            ));
        }

        let current_epoch = row_u64_from_i64(&actor_row, "epoch")?;
        if current_epoch != input.epoch {
            return Err(AppError::conflict("chat epoch is out of date"));
        }

        let active_member_rows = sqlx::query(
            r#"
            SELECT account_id
            FROM chat_account_members
            WHERE chat_id = $1
              AND membership_status = 'active'::membership_status
            "#,
        )
        .bind(input.chat_id)
        .fetch_all(&mut *tx)
        .await
        .map_err(map_db_error)?;
        let active_member_ids: BTreeSet<Uuid> = active_member_rows
            .into_iter()
            .map(|row| row_uuid(&row, "account_id"))
            .collect::<Result<_, _>>()?;

        for target_account_id in &target_account_ids {
            if !active_member_ids.contains(target_account_id) {
                return Err(AppError::conflict(
                    "one or more participant accounts are not active members",
                ));
            }
        }

        let remaining_members = active_member_ids
            .len()
            .saturating_sub(target_account_ids.len());
        if remaining_members == 0 {
            return Err(AppError::conflict(
                "cannot remove all active members from the chat",
            ));
        }

        let next_epoch = current_epoch + 1;
        sqlx::query(
            r#"
            UPDATE chat_account_members
            SET membership_status = 'removed'::membership_status,
                left_at = now()
            WHERE chat_id = $1
              AND account_id = ANY($2)
              AND membership_status = 'active'::membership_status
            "#,
        )
        .bind(input.chat_id)
        .bind(&target_account_ids)
        .execute(&mut *tx)
        .await
        .map_err(map_db_error)?;

        sqlx::query(
            r#"
            UPDATE chat_device_members cdm
            SET membership_status = 'removed'::device_membership_status,
                removed_in_epoch = $3,
                removed_at = now()
            FROM devices d
            WHERE cdm.chat_id = $1
              AND d.account_id = ANY($2)
              AND cdm.device_id = d.device_id
              AND cdm.membership_status = 'active'::device_membership_status
            "#,
        )
        .bind(input.chat_id)
        .bind(&target_account_ids)
        .bind(u64_to_i64(next_epoch, "next epoch")?)
        .execute(&mut *tx)
        .await
        .map_err(map_db_error)?;

        sqlx::query(
            r#"
            UPDATE mls_group_states
            SET epoch = $2,
                updated_at = now()
            WHERE chat_id = $1
            "#,
        )
        .bind(input.chat_id)
        .bind(u64_to_i64(next_epoch, "next epoch")?)
        .execute(&mut *tx)
        .await
        .map_err(map_db_error)?;

        if let Some(commit) = input.commit_message {
            let commit_message_id = commit.message_id;
            let recipients =
                active_chat_device_ids_tx(&mut tx, input.chat_id, input.actor_device_id, None)
                    .await?;
            insert_control_message_tx(
                &mut tx,
                input.chat_id,
                input.actor_account_id,
                input.actor_device_id,
                next_epoch,
                MessageKind::Commit,
                commit,
                &recipients,
            )
            .await?;
            set_last_commit_message_id_tx(&mut tx, input.chat_id, commit_message_id).await?;
        }

        tx.commit()
            .await
            .map_err(|err| AppError::internal(format!("failed to commit transaction: {err}")))?;

        Ok(ModifyChatMembersOutput {
            chat_id: input.chat_id,
            epoch: next_epoch,
            changed_account_ids: target_account_ids,
        })
    }

    pub async fn get_chat_detail_for_device(
        &self,
        chat_id: Uuid,
        device_id: Uuid,
    ) -> Result<Option<ChatDetail>, AppError> {
        let row = sqlx::query(
            r#"
            SELECT
                c.chat_id,
                c.chat_type::text AS chat_type,
                c.title,
                c.last_server_seq,
                mgs.epoch,
                mgs.last_commit_message_id
            FROM chats c
            JOIN mls_group_states mgs
              ON mgs.chat_id = c.chat_id
            JOIN chat_device_members cdm
              ON cdm.chat_id = c.chat_id
            JOIN devices d
              ON d.device_id = cdm.device_id
            WHERE c.chat_id = $1
              AND cdm.device_id = $2
              AND cdm.membership_status = 'active'::device_membership_status
              AND d.device_status = 'active'::device_status
              AND c.archived_at IS NULL
            "#,
        )
        .bind(chat_id)
        .bind(device_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(map_db_error)?;

        let Some(row) = row else {
            return Ok(None);
        };

        let member_rows = sqlx::query(
            r#"
            SELECT
                account_id,
                role::text AS role,
                membership_status::text AS membership_status
            FROM chat_account_members
            WHERE chat_id = $1
              AND membership_status = 'active'::membership_status
            ORDER BY joined_at ASC, account_id ASC
            "#,
        )
        .bind(chat_id)
        .fetch_all(&self.pool)
        .await
        .map_err(map_db_error)?;

        let members = member_rows
            .into_iter()
            .map(|member_row| {
                Ok(ChatMemberRow {
                    account_id: row_uuid(&member_row, "account_id")?,
                    role: row_text(&member_row, "role")?,
                    membership_status: row_text(&member_row, "membership_status")?,
                })
            })
            .collect::<Result<Vec<_>, _>>()?;

        Ok(Some(ChatDetail {
            chat_id: row_uuid(&row, "chat_id")?,
            chat_type: parse_chat_type(&row_text(&row, "chat_type")?)?,
            title: row_optional_text(&row, "title")?,
            last_server_seq: row_u64_from_i64(&row, "last_server_seq")?,
            epoch: row_u64_from_i64(&row, "epoch")?,
            last_commit_message_id: row_optional_uuid(&row, "last_commit_message_id")?,
            members,
        }))
    }

    pub async fn append_message(
        &self,
        input: CreateMessageInput,
    ) -> Result<CreateMessageOutput, AppError> {
        let mut tx = self
            .pool
            .begin()
            .await
            .map_err(|err| AppError::internal(format!("failed to begin transaction: {err}")))?;

        let membership_row = sqlx::query(
            r#"
            SELECT mgs.epoch
            FROM chat_device_members cdm
            JOIN devices d
              ON d.device_id = cdm.device_id
            JOIN mls_group_states mgs
              ON mgs.chat_id = cdm.chat_id
            WHERE cdm.chat_id = $1
              AND cdm.device_id = $2
              AND d.account_id = $3
              AND d.device_status = 'active'::device_status
              AND cdm.membership_status = 'active'::device_membership_status
            "#,
        )
        .bind(input.chat_id)
        .bind(input.sender_device_id)
        .bind(input.sender_account_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(map_db_error)?;

        let Some(membership_row) = membership_row else {
            return Err(AppError::not_found("active chat membership not found"));
        };

        let current_epoch = row_u64_from_i64(&membership_row, "epoch")?;
        if current_epoch != input.epoch {
            return Err(AppError::conflict("chat epoch is out of date"));
        }

        let seq_row = sqlx::query(
            r#"
            UPDATE chats
            SET last_server_seq = last_server_seq + 1
            WHERE chat_id = $1
            RETURNING last_server_seq
            "#,
        )
        .bind(input.chat_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(map_db_error)?;
        let Some(seq_row) = seq_row else {
            return Err(AppError::not_found("chat not found"));
        };
        let server_seq = row_u64_from_i64(&seq_row, "last_server_seq")?;

        sqlx::query(
            r#"
            INSERT INTO messages (
                message_id,
                chat_id,
                server_seq,
                sender_account_id,
                sender_device_id,
                epoch,
                message_kind,
                content_type,
                ciphertext,
                aad_json
            )
            VALUES ($1, $2, $3, $4, $5, $6, $7::message_kind, $8::content_type, $9, $10)
            "#,
        )
        .bind(input.message_id)
        .bind(input.chat_id)
        .bind(u64_to_i64(server_seq, "server sequence")?)
        .bind(input.sender_account_id)
        .bind(input.sender_device_id)
        .bind(u64_to_i64(input.epoch, "message epoch")?)
        .bind(message_kind_db(input.message_kind))
        .bind(content_type_db(input.content_type))
        .bind(&input.ciphertext)
        .bind(sqlx::types::Json(input.aad_json))
        .execute(&mut *tx)
        .await
        .map_err(map_db_error)?;

        sqlx::query(
            r#"
            INSERT INTO device_inbox (device_id, chat_id, message_id, delivery_state)
            SELECT
                cdm.device_id,
                $1,
                $2,
                'pending'::delivery_state
            FROM chat_device_members cdm
            JOIN devices d
              ON d.device_id = cdm.device_id
            WHERE cdm.chat_id = $1
              AND cdm.membership_status = 'active'::device_membership_status
              AND d.device_status = 'active'::device_status
              AND cdm.device_id <> $3
            "#,
        )
        .bind(input.chat_id)
        .bind(input.message_id)
        .bind(input.sender_device_id)
        .execute(&mut *tx)
        .await
        .map_err(map_db_error)?;

        tx.commit()
            .await
            .map_err(|err| AppError::internal(format!("failed to commit transaction: {err}")))?;

        Ok(CreateMessageOutput {
            message_id: input.message_id,
            server_seq,
        })
    }

    pub async fn get_chat_history_for_device(
        &self,
        chat_id: Uuid,
        device_id: Uuid,
        after_server_seq: Option<u64>,
        limit: Option<usize>,
    ) -> Result<Option<Vec<MessageEnvelopeRow>>, AppError> {
        let membership_row = sqlx::query(
            r#"
            SELECT 1
            FROM chat_device_members cdm
            JOIN devices d
              ON d.device_id = cdm.device_id
            WHERE cdm.chat_id = $1
              AND cdm.device_id = $2
              AND cdm.membership_status = 'active'::device_membership_status
              AND d.device_status = 'active'::device_status
            "#,
        )
        .bind(chat_id)
        .bind(device_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(map_db_error)?;

        if membership_row.is_none() {
            return Ok(None);
        }

        let after_server_seq = u64_to_i64(after_server_seq.unwrap_or(0), "history cursor")?;
        let limit = clamp_limit(limit, DEFAULT_HISTORY_LIMIT, MAX_HISTORY_LIMIT);

        let rows = sqlx::query(
            r#"
            SELECT
                message_id,
                chat_id,
                server_seq,
                sender_account_id,
                sender_device_id,
                epoch,
                message_kind::text AS message_kind,
                content_type::text AS content_type,
                ciphertext,
                aad_json,
                extract(epoch from created_at)::bigint AS created_at_unix
            FROM messages
            WHERE chat_id = $1
              AND server_seq > $2
            ORDER BY server_seq ASC
            LIMIT $3
            "#,
        )
        .bind(chat_id)
        .bind(after_server_seq)
        .bind(limit as i64)
        .fetch_all(&self.pool)
        .await
        .map_err(map_db_error)?;

        rows.into_iter()
            .map(message_row_from_db)
            .collect::<Result<Vec<_>, _>>()
            .map(Some)
    }

    pub async fn get_inbox_for_device(
        &self,
        device_id: Uuid,
        limit: Option<usize>,
    ) -> Result<Vec<InboxItemRow>, AppError> {
        let limit = clamp_limit(limit, DEFAULT_INBOX_LIMIT, MAX_INBOX_LIMIT);

        let rows = sqlx::query(
            r#"
            SELECT
                di.inbox_id,
                m.message_id,
                m.chat_id,
                m.server_seq,
                m.sender_account_id,
                m.sender_device_id,
                m.epoch,
                m.message_kind::text AS message_kind,
                m.content_type::text AS content_type,
                m.ciphertext,
                m.aad_json,
                extract(epoch from m.created_at)::bigint AS created_at_unix
            FROM device_inbox di
            JOIN messages m
              ON m.message_id = di.message_id
            JOIN devices d
              ON d.device_id = di.device_id
            WHERE di.device_id = $1
              AND di.delivery_state = 'pending'::delivery_state
              AND d.device_status = 'active'::device_status
            ORDER BY di.inbox_id ASC
            LIMIT $2
            "#,
        )
        .bind(device_id)
        .bind(limit as i64)
        .fetch_all(&self.pool)
        .await
        .map_err(map_db_error)?;

        rows.into_iter()
            .map(|row| {
                Ok(InboxItemRow {
                    inbox_id: row_u64_from_i64(&row, "inbox_id")?,
                    message: message_row_from_db(row)?,
                })
            })
            .collect()
    }

    pub async fn ack_inbox_items(
        &self,
        device_id: Uuid,
        inbox_ids: Vec<i64>,
    ) -> Result<Vec<u64>, AppError> {
        if inbox_ids.is_empty() {
            return Ok(Vec::new());
        }

        let rows = sqlx::query(
            r#"
            UPDATE device_inbox
            SET delivery_state = 'acked'::delivery_state,
                acked_at = COALESCE(acked_at, now())
            WHERE device_id = $1
              AND inbox_id = ANY($2)
              AND delivery_state <> 'acked'::delivery_state
            RETURNING inbox_id
            "#,
        )
        .bind(device_id)
        .bind(&inbox_ids)
        .fetch_all(&self.pool)
        .await
        .map_err(map_db_error)?;

        let mut acked = rows
            .into_iter()
            .map(|row| row_u64_from_i64(&row, "inbox_id"))
            .collect::<Result<Vec<_>, _>>()?;
        acked.sort_unstable();
        Ok(acked)
    }
}

async fn insert_device_key_packages_tx(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    device_id: Uuid,
    packages: &[KeyPackageBytesInput],
) -> Result<(), AppError> {
    for package in packages {
        sqlx::query(
            r#"
            INSERT INTO device_key_packages (device_id, cipher_suite, key_package_bytes, status)
            VALUES ($1, $2, $3, 'available'::key_package_status)
            "#,
        )
        .bind(device_id)
        .bind(&package.cipher_suite)
        .bind(&package.key_package_bytes)
        .execute(&mut **tx)
        .await
        .map_err(map_db_error)?;
    }

    Ok(())
}

async fn active_chat_device_ids_tx(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    chat_id: Uuid,
    exclude_device_id: Uuid,
    account_filter: Option<&[Uuid]>,
) -> Result<Vec<Uuid>, AppError> {
    let rows = if let Some(account_ids) = account_filter {
        sqlx::query(
            r#"
            SELECT cdm.device_id
            FROM chat_device_members cdm
            JOIN devices d
              ON d.device_id = cdm.device_id
            WHERE cdm.chat_id = $1
              AND cdm.device_id <> $2
              AND cdm.membership_status = 'active'::device_membership_status
              AND d.device_status = 'active'::device_status
              AND d.account_id = ANY($3)
            ORDER BY cdm.joined_at ASC, cdm.device_id ASC
            "#,
        )
        .bind(chat_id)
        .bind(exclude_device_id)
        .bind(account_ids)
        .fetch_all(&mut **tx)
        .await
    } else {
        sqlx::query(
            r#"
            SELECT cdm.device_id
            FROM chat_device_members cdm
            JOIN devices d
              ON d.device_id = cdm.device_id
            WHERE cdm.chat_id = $1
              AND cdm.device_id <> $2
              AND cdm.membership_status = 'active'::device_membership_status
              AND d.device_status = 'active'::device_status
            ORDER BY cdm.joined_at ASC, cdm.device_id ASC
            "#,
        )
        .bind(chat_id)
        .bind(exclude_device_id)
        .fetch_all(&mut **tx)
        .await
    }
    .map_err(map_db_error)?;

    rows.into_iter()
        .map(|row| row_uuid(&row, "device_id"))
        .collect()
}

async fn insert_control_message_tx(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    chat_id: Uuid,
    sender_account_id: Uuid,
    sender_device_id: Uuid,
    epoch: u64,
    message_kind: MessageKind,
    message: PendingControlMessage,
    recipient_device_ids: &[Uuid],
) -> Result<u64, AppError> {
    let seq_row = sqlx::query(
        r#"
        UPDATE chats
        SET last_server_seq = last_server_seq + 1
        WHERE chat_id = $1
        RETURNING last_server_seq
        "#,
    )
    .bind(chat_id)
    .fetch_optional(&mut **tx)
    .await
    .map_err(map_db_error)?;
    let Some(seq_row) = seq_row else {
        return Err(AppError::not_found("chat not found"));
    };
    let server_seq = row_u64_from_i64(&seq_row, "last_server_seq")?;

    sqlx::query(
        r#"
        INSERT INTO messages (
            message_id,
            chat_id,
            server_seq,
            sender_account_id,
            sender_device_id,
            epoch,
            message_kind,
            content_type,
            ciphertext,
            aad_json
        )
        VALUES ($1, $2, $3, $4, $5, $6, $7::message_kind, 'chat_event'::content_type, $8, $9)
        "#,
    )
    .bind(message.message_id)
    .bind(chat_id)
    .bind(u64_to_i64(server_seq, "server sequence")?)
    .bind(sender_account_id)
    .bind(sender_device_id)
    .bind(u64_to_i64(epoch, "message epoch")?)
    .bind(message_kind_db(message_kind))
    .bind(message.ciphertext)
    .bind(sqlx::types::Json(message.aad_json))
    .execute(&mut **tx)
    .await
    .map_err(map_db_error)?;

    if !recipient_device_ids.is_empty() {
        sqlx::query(
            r#"
            INSERT INTO device_inbox (device_id, chat_id, message_id, delivery_state)
            SELECT d.device_id, $1, $2, 'pending'::delivery_state
            FROM unnest($3::uuid[]) AS d(device_id)
            "#,
        )
        .bind(chat_id)
        .bind(message.message_id)
        .bind(recipient_device_ids)
        .execute(&mut **tx)
        .await
        .map_err(map_db_error)?;
    }

    Ok(server_seq)
}

async fn set_last_commit_message_id_tx(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    chat_id: Uuid,
    message_id: Uuid,
) -> Result<(), AppError> {
    sqlx::query(
        r#"
        UPDATE mls_group_states
        SET last_commit_message_id = $2,
            updated_at = now()
        WHERE chat_id = $1
        "#,
    )
    .bind(chat_id)
    .bind(message_id)
    .execute(&mut **tx)
    .await
    .map_err(map_db_error)?;

    Ok(())
}

async fn consume_reserved_key_packages_tx(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    reserved_by_account_id: Uuid,
    consumed_by_chat_id: Uuid,
    target_account_ids: &[Uuid],
    reserved_key_package_ids: &[Uuid],
) -> Result<(), AppError> {
    if target_account_ids.is_empty() {
        if reserved_key_package_ids.is_empty() {
            return Ok(());
        }
        return Err(AppError::bad_request(
            "reserved key packages were provided without target accounts",
        ));
    }

    if reserved_key_package_ids.is_empty() {
        return Err(AppError::bad_request(
            "reserved key package ids are required for target accounts",
        ));
    }

    let unique_key_package_ids: BTreeSet<Uuid> = reserved_key_package_ids.iter().copied().collect();
    if unique_key_package_ids.len() != reserved_key_package_ids.len() {
        return Err(AppError::bad_request(
            "reserved key package ids must be unique",
        ));
    }
    let unique_key_package_ids: Vec<Uuid> = unique_key_package_ids.into_iter().collect();

    let active_device_rows = sqlx::query(
        r#"
        SELECT device_id
        FROM devices
        WHERE account_id = ANY($1)
          AND device_status = 'active'::device_status
        ORDER BY device_id ASC
        "#,
    )
    .bind(target_account_ids)
    .fetch_all(&mut **tx)
    .await
    .map_err(map_db_error)?;
    let active_device_ids: BTreeSet<Uuid> = active_device_rows
        .into_iter()
        .map(|row| row_uuid(&row, "device_id"))
        .collect::<Result<_, _>>()?;

    let reserved_rows = sqlx::query(
        r#"
        SELECT
            kp.key_package_id,
            kp.device_id,
            kp.status::text AS status,
            kp.reserved_by_account_id,
            d.account_id
        FROM device_key_packages kp
        JOIN devices d
          ON d.device_id = kp.device_id
        WHERE kp.key_package_id = ANY($1)
        FOR UPDATE
        "#,
    )
    .bind(&unique_key_package_ids)
    .fetch_all(&mut **tx)
    .await
    .map_err(map_db_error)?;

    if reserved_rows.len() != unique_key_package_ids.len() {
        return Err(AppError::conflict(
            "one or more reserved key packages were not found",
        ));
    }

    let target_account_ids: BTreeSet<Uuid> = target_account_ids.iter().copied().collect();
    let mut reserved_device_ids = BTreeSet::new();
    for row in reserved_rows {
        let status = row_text(&row, "status")?;
        if status != "reserved" {
            return Err(AppError::conflict(
                "one or more key packages are no longer reserved",
            ));
        }

        let reserved_owner = row_optional_uuid(&row, "reserved_by_account_id")?;
        if reserved_owner != Some(reserved_by_account_id) {
            return Err(AppError::conflict(
                "one or more key packages are reserved by another account",
            ));
        }

        let account_id = row_uuid(&row, "account_id")?;
        if !target_account_ids.contains(&account_id) {
            return Err(AppError::conflict(
                "one or more key packages do not belong to the target accounts",
            ));
        }

        reserved_device_ids.insert(row_uuid(&row, "device_id")?);
    }

    if reserved_device_ids != active_device_ids {
        return Err(AppError::conflict(
            "reserved key packages do not cover all active target devices",
        ));
    }

    sqlx::query(
        r#"
        UPDATE device_key_packages
        SET status = 'consumed'::key_package_status,
            consumed_at = now(),
            consumed_by_chat_id = $2
        WHERE key_package_id = ANY($1)
        "#,
    )
    .bind(&unique_key_package_ids)
    .bind(consumed_by_chat_id)
    .execute(&mut **tx)
    .await
    .map_err(map_db_error)?;

    Ok(())
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

fn parse_chat_type(value: &str) -> Result<ChatType, AppError> {
    match value {
        "dm" => Ok(ChatType::Dm),
        "group" => Ok(ChatType::Group),
        "account_sync" => Ok(ChatType::AccountSync),
        other => Err(AppError::internal(format!(
            "unknown chat type from database: {other}"
        ))),
    }
}

fn parse_message_kind(value: &str) -> Result<MessageKind, AppError> {
    match value {
        "application" => Ok(MessageKind::Application),
        "commit" => Ok(MessageKind::Commit),
        "welcome_ref" => Ok(MessageKind::WelcomeRef),
        "system" => Ok(MessageKind::System),
        other => Err(AppError::internal(format!(
            "unknown message kind from database: {other}"
        ))),
    }
}

fn parse_blob_upload_status(value: &str) -> Result<BlobUploadStatus, AppError> {
    match value {
        "pending_upload" => Ok(BlobUploadStatus::PendingUpload),
        "available" => Ok(BlobUploadStatus::Available),
        other => Err(AppError::internal(format!(
            "unknown blob upload status from database: {other}"
        ))),
    }
}

fn parse_content_type(value: &str) -> Result<ContentType, AppError> {
    match value {
        "text" => Ok(ContentType::Text),
        "reaction" => Ok(ContentType::Reaction),
        "receipt" => Ok(ContentType::Receipt),
        "attachment" => Ok(ContentType::Attachment),
        "chat_event" => Ok(ContentType::ChatEvent),
        other => Err(AppError::internal(format!(
            "unknown content type from database: {other}"
        ))),
    }
}

fn chat_type_db(value: ChatType) -> &'static str {
    match value {
        ChatType::Dm => "dm",
        ChatType::Group => "group",
        ChatType::AccountSync => "account_sync",
    }
}

fn message_kind_db(value: MessageKind) -> &'static str {
    match value {
        MessageKind::Application => "application",
        MessageKind::Commit => "commit",
        MessageKind::WelcomeRef => "welcome_ref",
        MessageKind::System => "system",
    }
}

fn content_type_db(value: ContentType) -> &'static str {
    match value {
        ContentType::Text => "text",
        ContentType::Reaction => "reaction",
        ContentType::Receipt => "receipt",
        ContentType::Attachment => "attachment",
        ContentType::ChatEvent => "chat_event",
    }
}

fn clamp_limit(requested: Option<usize>, default_limit: usize, max_limit: usize) -> usize {
    let limit = requested.unwrap_or(default_limit);
    limit.clamp(1, max_limit)
}

fn u64_to_i64(value: u64, field: &str) -> Result<i64, AppError> {
    i64::try_from(value)
        .map_err(|_| AppError::bad_request(format!("{field} exceeds supported range")))
}

fn row_uuid(row: &sqlx::postgres::PgRow, column: &str) -> Result<Uuid, AppError> {
    row.try_get(column)
        .map_err(|err| AppError::internal(format!("failed to read {column}: {err}")))
}

fn row_optional_uuid(row: &sqlx::postgres::PgRow, column: &str) -> Result<Option<Uuid>, AppError> {
    row.try_get(column)
        .map_err(|err| AppError::internal(format!("failed to read {column}: {err}")))
}

fn row_text(row: &sqlx::postgres::PgRow, column: &str) -> Result<String, AppError> {
    row.try_get(column)
        .map_err(|err| AppError::internal(format!("failed to read {column}: {err}")))
}

fn row_optional_text(
    row: &sqlx::postgres::PgRow,
    column: &str,
) -> Result<Option<String>, AppError> {
    row.try_get(column)
        .map_err(|err| AppError::internal(format!("failed to read {column}: {err}")))
}

fn row_bytes(row: &sqlx::postgres::PgRow, column: &str) -> Result<Vec<u8>, AppError> {
    row.try_get(column)
        .map_err(|err| AppError::internal(format!("failed to read {column}: {err}")))
}

fn row_value(row: &sqlx::postgres::PgRow, column: &str) -> Result<Value, AppError> {
    row.try_get(column)
        .map_err(|err| AppError::internal(format!("failed to read {column}: {err}")))
}

fn row_u64_from_i64(row: &sqlx::postgres::PgRow, column: &str) -> Result<u64, AppError> {
    let value: i64 = row
        .try_get(column)
        .map_err(|err| AppError::internal(format!("failed to read {column}: {err}")))?;
    u64::try_from(value)
        .map_err(|_| AppError::internal(format!("negative value encountered for {column}")))
}

fn row_i32(row: &sqlx::postgres::PgRow, column: &str) -> Result<i32, AppError> {
    row.try_get(column)
        .map_err(|err| AppError::internal(format!("failed to read {column}: {err}")))
}

fn blob_metadata_row_from_db(row: sqlx::postgres::PgRow) -> Result<BlobMetadataRow, AppError> {
    Ok(BlobMetadataRow {
        blob_id: row_text(&row, "blob_id")?,
        mime_type: row_text(&row, "mime_type")?,
        size_bytes: row_u64_from_i64(&row, "size_bytes")?,
        sha256: row_bytes(&row, "sha256")?,
        upload_status: parse_blob_upload_status(&row_text(&row, "upload_status")?)?,
        created_by_device_id: row_uuid(&row, "created_by_device_id")?,
        relative_path: row_text(&row, "relative_path")?,
    })
}

fn message_row_from_db(row: sqlx::postgres::PgRow) -> Result<MessageEnvelopeRow, AppError> {
    Ok(MessageEnvelopeRow {
        message_id: row_uuid(&row, "message_id")?,
        chat_id: row_uuid(&row, "chat_id")?,
        server_seq: row_u64_from_i64(&row, "server_seq")?,
        sender_account_id: row_uuid(&row, "sender_account_id")?,
        sender_device_id: row_uuid(&row, "sender_device_id")?,
        epoch: row_u64_from_i64(&row, "epoch")?,
        message_kind: parse_message_kind(&row_text(&row, "message_kind")?)?,
        content_type: parse_content_type(&row_text(&row, "content_type")?)?,
        ciphertext: row_bytes(&row, "ciphertext")?,
        aad_json: row_value(&row, "aad_json")?,
        created_at_unix: row_u64_from_i64(&row, "created_at_unix")?,
    })
}

fn map_db_error(err: sqlx::Error) -> AppError {
    if let sqlx::Error::Database(db_err) = &err {
        if db_err.constraint() == Some("accounts_handle_key") {
            return AppError::conflict("handle is already taken");
        }

        if db_err.constraint() == Some("messages_pkey") {
            return AppError::conflict("message already exists");
        }
    }

    AppError::internal(format!("database error: {err}"))
}
