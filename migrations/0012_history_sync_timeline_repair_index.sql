CREATE UNIQUE INDEX history_sync_jobs_active_timeline_repair_idx
    ON history_sync_jobs (
        account_id,
        source_device_id,
        target_device_id,
        chat_id,
        job_type
    )
    WHERE job_type = 'timeline_repair'::history_sync_job_type
      AND job_status IN (
          'pending'::history_sync_job_status,
          'running'::history_sync_job_status
      );
