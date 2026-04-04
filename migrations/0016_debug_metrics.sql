CREATE TABLE debug_metric_sessions (
    session_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id uuid NOT NULL REFERENCES accounts (account_id) ON DELETE CASCADE,
    device_id uuid REFERENCES devices (device_id) ON DELETE SET NULL,
    user_visible_message text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    revoked_at timestamptz,
    created_by_admin text NOT NULL DEFAULT ''
);

CREATE INDEX debug_metric_sessions_account_created_idx
    ON debug_metric_sessions (account_id, created_at DESC);

CREATE INDEX debug_metric_sessions_active_idx
    ON debug_metric_sessions (account_id, expires_at)
    WHERE revoked_at IS NULL;

CREATE TABLE debug_metric_batches (
    batch_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id uuid NOT NULL REFERENCES debug_metric_sessions (session_id) ON DELETE CASCADE,
    device_id uuid NOT NULL REFERENCES devices (device_id) ON DELETE CASCADE,
    received_at timestamptz NOT NULL DEFAULT now(),
    payload_json jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE INDEX debug_metric_batches_session_received_idx
    ON debug_metric_batches (session_id, received_at DESC);
