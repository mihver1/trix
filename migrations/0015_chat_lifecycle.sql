-- Chat lifecycle: terminal DM closure and per-account DM history cutoff after re-open.
-- Open DM uniqueness is enforced only while closed_at IS NULL (see partial index below).

ALTER TABLE chats
    ADD COLUMN closed_at timestamptz;

COMMENT ON COLUMN chats.closed_at IS
    'When set, the chat is terminal (e.g. DM globally deleted). Excluded from listings; DM pair may open a new chat row.';

ALTER TABLE chat_account_members
    ADD COLUMN dm_history_cutoff_server_seq bigint;

COMMENT ON COLUMN chat_account_members.dm_history_cutoff_server_seq IS
    'For DM re-open: leaver only sees messages with server_seq strictly greater than this value (NULL = no cutoff).';

DROP INDEX IF EXISTS chats_dm_member_pair_key_idx;

-- At most one *open* (not closed) DM per dm_member_pair_key.
CREATE UNIQUE INDEX chats_dm_open_pair_key_idx
    ON chats (dm_member_pair_key)
    WHERE dm_member_pair_key IS NOT NULL
      AND closed_at IS NULL
      AND chat_type = 'dm'::chat_type;
