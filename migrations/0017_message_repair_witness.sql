CREATE TYPE message_repair_request_status AS ENUM (
    'pending',
    'completed',
    'unavailable',
    'consumed',
    'expired'
);

CREATE TABLE message_repair_witness_requests (
    request_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    target_account_id uuid NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
    target_device_id uuid NOT NULL REFERENCES devices(device_id) ON DELETE CASCADE,
    chat_id uuid NOT NULL REFERENCES chats(chat_id) ON DELETE CASCADE,
    message_id uuid NOT NULL REFERENCES messages(message_id) ON DELETE CASCADE,
    server_seq bigint NOT NULL CHECK (server_seq > 0),
    epoch bigint NOT NULL CHECK (epoch >= 0),
    sender_account_id uuid NOT NULL REFERENCES accounts(account_id),
    sender_device_id uuid NOT NULL REFERENCES devices(device_id),
    message_kind message_kind NOT NULL,
    content_type content_type NOT NULL,
    ciphertext_sha256 bytea NOT NULL CHECK (octet_length(ciphertext_sha256) = 32),
    witness_account_id uuid NOT NULL REFERENCES accounts(account_id),
    witness_device_id uuid NOT NULL REFERENCES devices(device_id),
    target_transport_pubkey bytea NOT NULL CHECK (octet_length(target_transport_pubkey) = 32),
    status message_repair_request_status NOT NULL,
    result_payload bytea,
    submitted_by_device_id uuid REFERENCES devices(device_id),
    unavailable_reason text,
    rejection_reason text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL
);

CREATE UNIQUE INDEX message_repair_witness_requests_active_target_message_idx
    ON message_repair_witness_requests (target_device_id, chat_id, server_seq)
    WHERE status IN (
        'pending'::message_repair_request_status,
        'completed'::message_repair_request_status,
        'unavailable'::message_repair_request_status
    );

CREATE INDEX message_repair_witness_requests_witness_status_idx
    ON message_repair_witness_requests (witness_device_id, status, expires_at);

CREATE INDEX message_repair_witness_requests_target_status_idx
    ON message_repair_witness_requests (target_device_id, status, expires_at);
