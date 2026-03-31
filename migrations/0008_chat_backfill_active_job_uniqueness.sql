CREATE UNIQUE INDEX history_sync_jobs_active_chat_backfill_unique_idx
    ON history_sync_jobs (account_id, target_device_id, chat_id, job_type)
    WHERE job_type = 'chat_backfill'::history_sync_job_type
      AND job_status IN ('pending'::history_sync_job_status, 'running'::history_sync_job_status);
