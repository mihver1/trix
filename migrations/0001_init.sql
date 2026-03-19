CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TYPE device_status AS ENUM ('pending', 'active', 'revoked');
CREATE TYPE chat_type AS ENUM ('dm', 'group', 'account_sync');
CREATE TYPE membership_status AS ENUM ('active', 'left', 'removed');
CREATE TYPE device_membership_status AS ENUM ('pending_add', 'active', 'pending_remove', 'removed');
CREATE TYPE group_state_status AS ENUM ('active', 'rotating', 'blocked');
CREATE TYPE key_package_status AS ENUM ('available', 'reserved', 'consumed', 'expired');
CREATE TYPE message_kind AS ENUM ('application', 'commit', 'welcome_ref', 'system');
CREATE TYPE content_type AS ENUM ('text', 'reaction', 'receipt', 'attachment', 'chat_event');
CREATE TYPE delivery_state AS ENUM ('pending', 'leased', 'acked', 'failed');
CREATE TYPE storage_backend AS ENUM ('local_fs');
CREATE TYPE history_sync_job_type AS ENUM ('initial_sync', 'chat_backfill', 'device_rekey');
CREATE TYPE history_sync_job_status AS ENUM ('pending', 'running', 'completed', 'failed', 'canceled');
CREATE TYPE chat_role AS ENUM ('owner', 'member');
CREATE TYPE device_log_event_type AS ENUM ('device_added', 'device_activated', 'device_revoked');

CREATE TABLE accounts (
    account_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    handle text UNIQUE,
    profile_name text NOT NULL,
    profile_bio text,
    avatar_blob_id text,
    created_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz
);

CREATE TABLE devices (
    device_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id uuid NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
    display_name text NOT NULL,
    platform text NOT NULL,
    device_status device_status NOT NULL,
    credential_identity bytea NOT NULL,
    account_root_signature bytea NOT NULL,
    transport_pubkey bytea NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    activated_at timestamptz,
    revoked_at timestamptz
);

CREATE INDEX devices_account_id_idx ON devices(account_id);
CREATE INDEX devices_account_status_idx ON devices(account_id, device_status);

CREATE TABLE device_log (
    device_log_seq bigserial PRIMARY KEY,
    account_id uuid NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
    event_type device_log_event_type NOT NULL,
    subject_device_id uuid NOT NULL REFERENCES devices(device_id) ON DELETE CASCADE,
    actor_device_id uuid REFERENCES devices(device_id) ON DELETE SET NULL,
    payload_json jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX device_log_account_seq_idx ON device_log(account_id, device_log_seq);

CREATE TABLE chats (
    chat_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    chat_type chat_type NOT NULL,
    title text,
    avatar_blob_id text,
    created_by_account_id uuid NOT NULL REFERENCES accounts(account_id),
    created_at timestamptz NOT NULL DEFAULT now(),
    archived_at timestamptz,
    last_server_seq bigint NOT NULL DEFAULT 0
);

CREATE INDEX chats_type_created_at_idx ON chats(chat_type, created_at);

CREATE TABLE chat_account_members (
    chat_id uuid NOT NULL REFERENCES chats(chat_id) ON DELETE CASCADE,
    account_id uuid NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
    role chat_role NOT NULL,
    membership_status membership_status NOT NULL,
    joined_at timestamptz NOT NULL DEFAULT now(),
    left_at timestamptz,
    PRIMARY KEY (chat_id, account_id)
);

CREATE INDEX chat_account_members_account_status_idx
    ON chat_account_members(account_id, membership_status);

CREATE TABLE chat_device_members (
    chat_id uuid NOT NULL REFERENCES chats(chat_id) ON DELETE CASCADE,
    device_id uuid NOT NULL REFERENCES devices(device_id) ON DELETE CASCADE,
    leaf_index integer,
    membership_status device_membership_status NOT NULL,
    added_in_epoch bigint NOT NULL,
    removed_in_epoch bigint,
    joined_at timestamptz NOT NULL DEFAULT now(),
    removed_at timestamptz,
    PRIMARY KEY (chat_id, device_id)
);

CREATE INDEX chat_device_members_device_status_idx
    ON chat_device_members(device_id, membership_status);
CREATE INDEX chat_device_members_chat_status_idx
    ON chat_device_members(chat_id, membership_status);

CREATE TABLE mls_group_states (
    chat_id uuid PRIMARY KEY REFERENCES chats(chat_id) ON DELETE CASCADE,
    group_id_bytes bytea NOT NULL,
    epoch bigint NOT NULL,
    state_status group_state_status NOT NULL,
    last_commit_message_id uuid,
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE device_key_packages (
    key_package_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    device_id uuid NOT NULL REFERENCES devices(device_id) ON DELETE CASCADE,
    cipher_suite text NOT NULL,
    key_package_bytes bytea NOT NULL,
    status key_package_status NOT NULL,
    published_at timestamptz NOT NULL DEFAULT now(),
    reserved_at timestamptz,
    consumed_at timestamptz
);

CREATE INDEX device_key_packages_device_status_idx
    ON device_key_packages(device_id, status);
CREATE INDEX device_key_packages_status_published_at_idx
    ON device_key_packages(status, published_at);

CREATE TABLE messages (
    message_id uuid PRIMARY KEY,
    chat_id uuid NOT NULL REFERENCES chats(chat_id) ON DELETE CASCADE,
    server_seq bigint NOT NULL,
    sender_account_id uuid NOT NULL REFERENCES accounts(account_id),
    sender_device_id uuid NOT NULL REFERENCES devices(device_id),
    epoch bigint NOT NULL,
    message_kind message_kind NOT NULL,
    content_type content_type NOT NULL,
    ciphertext bytea NOT NULL,
    aad_json jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (chat_id, server_seq)
);

CREATE INDEX messages_chat_created_at_idx ON messages(chat_id, created_at);
CREATE INDEX messages_sender_created_at_idx ON messages(sender_device_id, created_at);

CREATE TABLE device_inbox (
    inbox_id bigserial PRIMARY KEY,
    device_id uuid NOT NULL REFERENCES devices(device_id) ON DELETE CASCADE,
    chat_id uuid NOT NULL REFERENCES chats(chat_id) ON DELETE CASCADE,
    message_id uuid NOT NULL REFERENCES messages(message_id) ON DELETE CASCADE,
    delivery_state delivery_state NOT NULL,
    lease_owner text,
    lease_expires_at timestamptz,
    acked_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX device_inbox_device_state_id_idx
    ON device_inbox(device_id, delivery_state, inbox_id);
CREATE INDEX device_inbox_message_id_idx ON device_inbox(message_id);

CREATE TABLE attachment_blobs (
    blob_id text PRIMARY KEY,
    storage_backend storage_backend NOT NULL,
    relative_path text NOT NULL,
    size_bytes bigint NOT NULL,
    sha256 bytea NOT NULL,
    mime_type text NOT NULL,
    created_by_device_id uuid NOT NULL REFERENCES devices(device_id),
    created_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz
);

CREATE TABLE history_sync_jobs (
    job_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id uuid NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
    source_device_id uuid NOT NULL REFERENCES devices(device_id) ON DELETE CASCADE,
    target_device_id uuid NOT NULL REFERENCES devices(device_id) ON DELETE CASCADE,
    chat_id uuid REFERENCES chats(chat_id) ON DELETE CASCADE,
    job_type history_sync_job_type NOT NULL,
    job_status history_sync_job_status NOT NULL,
    cursor_json jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX history_sync_jobs_target_status_idx
    ON history_sync_jobs(target_device_id, job_status);
CREATE INDEX history_sync_jobs_account_status_idx
    ON history_sync_jobs(account_id, job_status);

CREATE TABLE idempotency_keys (
    scope text NOT NULL,
    key text NOT NULL,
    response_json jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (scope, key)
);

