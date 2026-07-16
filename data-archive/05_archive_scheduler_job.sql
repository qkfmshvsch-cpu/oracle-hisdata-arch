-- ============================================================================
-- Daily Scheduler job template for ORDERS.ORDER_HEADERS incremental sync
-- Run as archive_admin after installing the archive package and configuration.
-- ============================================================================

BEGIN
    DBMS_SCHEDULER.CREATE_JOB(
        job_name        => 'ARCHIVE_ORDER_HEADERS_DAILY_JOB',
        job_type        => 'PLSQL_BLOCK',
        job_action      => q'[
DECLARE
    c_archive_lag_days CONSTANT PLS_INTEGER := 1;
    v_today DATE := TRUNC(CAST(SYSTIMESTAMP AT TIME ZONE 'Asia/Shanghai' AS DATE));
    v_end_date DATE := v_today - c_archive_lag_days;
    v_start_date DATE := v_end_date - 1;
BEGIN
    history_archive_pkg.sync_incremental(
        'ORDERS',
        'ORDER_HEADERS',
        v_start_date,
        v_end_date
    );
END;
]',
        start_date      => SYSTIMESTAMP AT TIME ZONE 'Asia/Shanghai',
        repeat_interval => 'FREQ=DAILY;BYHOUR=3;BYMINUTE=0;BYSECOND=0',
        enabled => FALSE,
        auto_drop => FALSE,
        comments        => 'Disabled daily template for ORDERS.ORDER_HEADERS incremental archive sync.'
    );
END;
/
