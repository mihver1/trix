CREATE TYPE link_intent_status AS ENUM (
    'open',
    'pending_approval',
    'completed',
    'expired',
    'canceled'
);

CREATE TABLE device_link_intents (
    link_intent_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id uuid NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
    created_by_device_id uuid NOT NULL REFERENCES devices(device_id) ON DELETE CASCADE,
    link_token uuid NOT NULL UNIQUE,
    pending_device_id uuid REFERENCES devices(device_id) ON DELETE SET NULL,
    status link_intent_status NOT NULL,
    expires_at timestamptz NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    completed_at timestamptz,
    approved_by_device_id uuid REFERENCES devices(device_id) ON DELETE SET NULL,
    approved_at timestamptz
);

CREATE INDEX device_link_intents_account_status_idx
    ON device_link_intents(account_id, status);

CREATE INDEX device_link_intents_expires_at_idx
    ON device_link_intents(expires_at);

CREATE UNIQUE INDEX device_link_intents_pending_device_id_idx
    ON device_link_intents(pending_device_id)
    WHERE pending_device_id IS NOT NULL;
