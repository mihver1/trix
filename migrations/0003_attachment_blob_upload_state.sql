CREATE TYPE blob_upload_status AS ENUM ('pending_upload', 'available');

ALTER TABLE attachment_blobs
    ADD COLUMN upload_status blob_upload_status NOT NULL DEFAULT 'pending_upload',
    ADD COLUMN upload_completed_at timestamptz;

CREATE TABLE attachment_blob_chat_refs (
    blob_id text NOT NULL REFERENCES attachment_blobs(blob_id) ON DELETE CASCADE,
    chat_id uuid NOT NULL REFERENCES chats(chat_id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (blob_id, chat_id)
);

CREATE INDEX attachment_blob_chat_refs_chat_id_idx
    ON attachment_blob_chat_refs(chat_id);

CREATE INDEX attachment_blobs_status_created_at_idx
    ON attachment_blobs(upload_status, created_at);
