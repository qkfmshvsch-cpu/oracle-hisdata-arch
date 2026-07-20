-- ============================================================================
-- Daily Scheduler job template for ORDERS.ORDER_HEADERS retention-based sync
-- Run as archive_admin after installing the archive package and configuration.
-- ============================================================================

BEGIN
    DBMS_SCHEDULER.CREATE_JOB(
        job_name        => 'ARCHIVE_ORDER_HEADERS_DAILY_JOB',
        job_type        => 'PLSQL_BLOCK',
        job_action      => q'[
DECLARE
    c_retention_periods CONSTANT PLS_INTEGER := 1;
    c_batch_days        CONSTANT PLS_INTEGER := 1;
BEGIN
    history_archive_pkg.sync(
        p_source_schema      => 'ORDERS',
        p_source_table       => 'ORDER_HEADERS',
        p_retention_periods  => c_retention_periods,
        p_batch_days         => c_batch_days
    );
END;
]',
        start_date      => SYSTIMESTAMP AT TIME ZONE 'Asia/Shanghai',
        repeat_interval => 'FREQ=DAILY;BYHOUR=3;BYMINUTE=0;BYSECOND=0',
        enabled => FALSE,
        auto_drop => FALSE,
        comments        => 'Disabled daily template for ORDERS.ORDER_HEADERS retention-based archive sync.'
    );
END;
/
