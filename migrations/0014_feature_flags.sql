CREATE TYPE feature_flag_scope AS ENUM ('global', 'platform', 'account', 'device');

CREATE TABLE feature_flag_definitions (
    flag_key TEXT PRIMARY KEY,
    description TEXT NOT NULL DEFAULT '',
    default_enabled BOOLEAN NOT NULL DEFAULT FALSE,
    deleted_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE feature_flag_overrides (
    override_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    flag_key TEXT NOT NULL REFERENCES feature_flag_definitions (flag_key) ON DELETE CASCADE,
    scope feature_flag_scope NOT NULL,
    platform TEXT,
    account_id UUID REFERENCES accounts (account_id) ON DELETE CASCADE,
    device_id UUID REFERENCES devices (device_id) ON DELETE CASCADE,
    enabled BOOLEAN NOT NULL,
    expires_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT feature_flag_overrides_scope_global_chk CHECK (
        scope <> 'global'
        OR (
            platform IS NULL
            AND account_id IS NULL
            AND device_id IS NULL
        )
    ),
    CONSTRAINT feature_flag_overrides_scope_platform_chk CHECK (
        scope <> 'platform'
        OR (
            platform IS NOT NULL
            AND account_id IS NULL
            AND device_id IS NULL
        )
    ),
    CONSTRAINT feature_flag_overrides_scope_account_chk CHECK (
        scope <> 'account'
        OR (
            platform IS NULL
            AND account_id IS NOT NULL
            AND device_id IS NULL
        )
    ),
    CONSTRAINT feature_flag_overrides_scope_device_chk CHECK (
        scope <> 'device'
        OR (
            platform IS NULL
            AND account_id IS NOT NULL
            AND device_id IS NOT NULL
        )
    )
);

CREATE UNIQUE INDEX feature_flag_overrides_global_uniq
    ON feature_flag_overrides (flag_key)
    WHERE scope = 'global'::feature_flag_scope;

CREATE UNIQUE INDEX feature_flag_overrides_platform_uniq
    ON feature_flag_overrides (flag_key, platform)
    WHERE scope = 'platform'::feature_flag_scope;

CREATE UNIQUE INDEX feature_flag_overrides_account_uniq
    ON feature_flag_overrides (flag_key, account_id)
    WHERE scope = 'account'::feature_flag_scope;

CREATE UNIQUE INDEX feature_flag_overrides_device_uniq
    ON feature_flag_overrides (flag_key, device_id)
    WHERE scope = 'device'::feature_flag_scope;

CREATE INDEX feature_flag_overrides_flag_key_idx ON feature_flag_overrides (flag_key);
CREATE INDEX feature_flag_overrides_lookup_idx
    ON feature_flag_overrides (flag_key, scope, account_id, device_id, platform);

CREATE TABLE feature_flags_revision (
    singleton BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (singleton),
    revision BIGINT NOT NULL DEFAULT 0
);

INSERT INTO feature_flags_revision (singleton, revision)
VALUES (TRUE, 0);

CREATE OR REPLACE FUNCTION bump_feature_flags_revision()
RETURNS TRIGGER AS $$
BEGIN
    UPDATE feature_flags_revision SET revision = revision + 1 WHERE singleton = TRUE;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER feature_flag_definitions_bump_revision
    AFTER INSERT OR UPDATE OR DELETE ON feature_flag_definitions
    FOR EACH STATEMENT
    EXECUTE FUNCTION bump_feature_flags_revision();

CREATE TRIGGER feature_flag_overrides_bump_revision
    AFTER INSERT OR UPDATE OR DELETE ON feature_flag_overrides
    FOR EACH STATEMENT
    EXECUTE FUNCTION bump_feature_flags_revision();

CREATE OR REPLACE FUNCTION feature_flag_device_account_matches()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.scope = 'device'::feature_flag_scope THEN
        IF NOT EXISTS (
            SELECT 1
            FROM devices d
            WHERE d.device_id = NEW.device_id
              AND d.account_id = NEW.account_id
        ) THEN
            RAISE EXCEPTION 'device_id must belong to account_id for device-scoped overrides';
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER feature_flag_overrides_device_account_chk_trg
    BEFORE INSERT OR UPDATE ON feature_flag_overrides
    FOR EACH ROW
    EXECUTE FUNCTION feature_flag_device_account_matches();
