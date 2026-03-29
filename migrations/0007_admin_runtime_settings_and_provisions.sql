ALTER TABLE accounts
    ADD COLUMN disabled_at timestamptz,
    ADD COLUMN disabled_reason text;

CREATE TABLE admin_runtime_settings (
    singleton boolean PRIMARY KEY DEFAULT TRUE CHECK (singleton),
    allow_public_account_registration boolean NOT NULL DEFAULT TRUE,
    brand_display_name text,
    support_contact text,
    policy_text text,
    updated_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO admin_runtime_settings (singleton) VALUES (TRUE)
ON CONFLICT (singleton) DO NOTHING;

CREATE TABLE admin_user_provisions (
    provision_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    provision_token_hash bytea NOT NULL UNIQUE,
    handle text,
    profile_name text NOT NULL,
    profile_bio text,
    expires_at timestamptz NOT NULL,
    claimed_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now()
);
