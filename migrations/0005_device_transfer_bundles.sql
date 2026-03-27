ALTER TABLE device_link_intents
    ADD COLUMN transfer_bundle_ciphertext bytea,
    ADD COLUMN transfer_bundle_uploaded_at timestamptz,
    ADD COLUMN transfer_bundle_fetched_at timestamptz;
