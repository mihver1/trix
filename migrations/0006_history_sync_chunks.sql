CREATE TABLE history_sync_chunks (
    chunk_id bigserial PRIMARY KEY,
    job_id uuid NOT NULL REFERENCES history_sync_jobs(job_id) ON DELETE CASCADE,
    sequence_no bigint NOT NULL,
    payload bytea NOT NULL,
    cursor_json jsonb,
    is_final boolean NOT NULL DEFAULT false,
    uploaded_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (job_id, sequence_no)
);

CREATE INDEX history_sync_chunks_job_sequence_idx
    ON history_sync_chunks(job_id, sequence_no);

CREATE INDEX history_sync_chunks_job_uploaded_at_idx
    ON history_sync_chunks(job_id, uploaded_at);
