ALTER TABLE chats
    ADD COLUMN dm_member_pair_key text;

WITH dm_pairs AS (
    SELECT
        c.chat_id,
        string_agg(cam.account_id::text, ':' ORDER BY cam.account_id::text) AS pair_key,
        count(*)::integer AS member_count
    FROM chats c
    JOIN chat_account_members cam
      ON cam.chat_id = c.chat_id
    WHERE c.chat_type = 'dm'::chat_type
      AND cam.membership_status = 'active'::membership_status
    GROUP BY c.chat_id
),
ranked_dm_chats AS (
    SELECT
        c.chat_id,
        row_number() OVER (
            PARTITION BY dm_pairs.pair_key
            ORDER BY
                CASE WHEN c.archived_at IS NULL THEN 0 ELSE 1 END ASC,
                c.last_server_seq DESC,
                c.created_at DESC,
                c.chat_id DESC
        ) AS chat_rank
    FROM chats c
    JOIN dm_pairs
      ON dm_pairs.chat_id = c.chat_id
    WHERE dm_pairs.member_count = 2
)
DELETE FROM chats c
USING ranked_dm_chats ranked
WHERE c.chat_id = ranked.chat_id
  AND ranked.chat_rank > 1;

WITH dm_pairs AS (
    SELECT
        c.chat_id,
        string_agg(cam.account_id::text, ':' ORDER BY cam.account_id::text) AS pair_key,
        count(*)::integer AS member_count
    FROM chats c
    JOIN chat_account_members cam
      ON cam.chat_id = c.chat_id
    WHERE c.chat_type = 'dm'::chat_type
      AND cam.membership_status = 'active'::membership_status
    GROUP BY c.chat_id
)
UPDATE chats c
SET dm_member_pair_key = dm_pairs.pair_key
FROM dm_pairs
WHERE c.chat_id = dm_pairs.chat_id
  AND dm_pairs.member_count = 2;

CREATE UNIQUE INDEX chats_dm_member_pair_key_idx
    ON chats(dm_member_pair_key)
    WHERE dm_member_pair_key IS NOT NULL;
