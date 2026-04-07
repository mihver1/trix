-- The leaf_index column in chat_device_members should be NOT NULL per MLS semantics.
-- Backfill any NULLs with 0 (valid MLS leaf index) before adding the constraint.
UPDATE chat_device_members SET leaf_index = 0 WHERE leaf_index IS NULL;
ALTER TABLE chat_device_members ALTER COLUMN leaf_index SET NOT NULL;
ALTER TABLE chat_device_members ALTER COLUMN leaf_index SET DEFAULT 0;
