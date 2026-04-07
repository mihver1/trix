-- Replace the UNIQUE constraint on accounts.handle with a partial unique index
-- that only enforces uniqueness for non-deleted accounts. This allows soft-deleted
-- accounts to release their handle for reuse.
ALTER TABLE accounts DROP CONSTRAINT IF EXISTS accounts_handle_key;
DROP INDEX IF EXISTS accounts_handle_active_unique;
CREATE UNIQUE INDEX accounts_handle_active_unique ON accounts (handle) WHERE deleted_at IS NULL;
