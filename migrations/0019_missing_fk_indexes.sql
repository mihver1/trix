-- Add indexes on foreign key columns that lack them.
-- These columns are referenced in JOINs and WHERE clauses but had no supporting index,
-- causing sequential scans on the referenced tables.

CREATE INDEX IF NOT EXISTS messages_sender_account_id_idx
    ON messages (sender_account_id);

CREATE INDEX IF NOT EXISTS device_log_actor_device_id_idx
    ON device_log (actor_device_id);

CREATE INDEX IF NOT EXISTS device_log_subject_device_id_idx
    ON device_log (subject_device_id);

CREATE INDEX IF NOT EXISTS chats_created_by_account_id_idx
    ON chats (created_by_account_id);

CREATE INDEX IF NOT EXISTS attachment_blobs_created_by_device_id_idx
    ON attachment_blobs (created_by_device_id);

CREATE INDEX IF NOT EXISTS history_sync_jobs_source_device_id_idx
    ON history_sync_jobs (source_device_id);
