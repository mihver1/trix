ALTER TABLE device_key_packages
    ADD COLUMN reserved_by_account_id uuid REFERENCES accounts(account_id),
    ADD COLUMN consumed_by_chat_id uuid REFERENCES chats(chat_id);

CREATE INDEX device_key_packages_reserved_by_status_idx
    ON device_key_packages(reserved_by_account_id, status);

CREATE INDEX device_key_packages_consumed_by_chat_idx
    ON device_key_packages(consumed_by_chat_id);
