CREATE TABLE device_push_registrations (
    device_id uuid NOT NULL REFERENCES devices(device_id) ON DELETE CASCADE,
    provider text NOT NULL CHECK (provider IN ('apns')),
    token_hex text NOT NULL,
    environment text NOT NULL CHECK (environment IN ('sandbox', 'production')),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    last_success_at timestamptz,
    last_failure_at timestamptz,
    failure_reason text,
    disabled_at timestamptz,
    PRIMARY KEY (device_id, provider)
);

CREATE INDEX device_push_registrations_provider_idx
    ON device_push_registrations(provider, disabled_at, updated_at DESC);
