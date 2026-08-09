-- ============================================================================
-- Daily Scheduler job template for ORDERS.ORDER_HEADERS retention-based sync
-- Run as archive_admin after installing the archive package and configuration.
-- ============================================================================

##历史归档数据库的定时归档job{一定要跟下面的生产库定时drop分区job配合，才能达到去重和增量效果}
BEGIN
  DBMS_SCHEDULER.CREATE_JOB(job_name        => 'ARC_COLLECT_LIST_EFM_WEEK_JOB',
                            job_type        => 'PLSQL_BLOCK',
                            job_action      => q'[
DECLARE
    c_retention_periods CONSTANT PLS_INTEGER := 12;
    c_batch_days        CONSTANT PLS_INTEGER := 1;
BEGIN
    history_archive_pkg.sync(
        p_source_schema      => 'JMEAPDB',
        p_source_table       => 'EQP_COLLECT_LIST_EFM',
        p_retention_periods  => c_retention_periods,
        p_batch_days         => c_batch_days
    );
END;
]',
                            start_date      => SYSTIMESTAMP AT TIME ZONE
                                               'Asia/Shanghai',
                            repeat_interval => 'FREQ=WEEKLY;BYDAY=MON;BYHOUR=1;BYMINUTE=0;BYSECOND=0',
                            enabled         => TRUE,
                            auto_drop       => FALSE,
                            comments        => 'Disabled daily template for JMEAPDB.EQP_COLLECT_LIST_EFM retention-based archive sync.');
END;
/
##生产数据库的定时drop分区的job，保留一年的数据。
BEGIN
  DBMS_SCHEDULER.CREATE_JOB(
        job_name        => 'DROP_COLLECT_LIST_EFM_PART_WEEK_JOB',
        job_type        => 'PLSQL_BLOCK',
        job_action      => q'[
BEGIN
    p_drop_user_table_PARTITIONS(
        'JMEAPDB',
        'EQP_COLLECT_LIST_EFM',
        12
    );
END;
]',
        start_date      => SYSTIMESTAMP AT TIME ZONE 'Asia/Shanghai',
        repeat_interval => 'FREQ=WEEKLY;BYDAY=MON;BYHOUR=8;BYMINUTE=0;BYSECOND=0',
        enabled         => TRUE,
        auto_drop       => FALSE,
        comments        => 'Weekly partition cleanup job for JMEAPDB.EQP_COLLECT_LIST_EFM retention 12 months.'
  );
END;
/

