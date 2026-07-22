-- Minimal history archive configuration and calls.
--重要前提注意:历史数据归档和数据同步的最大的区别在于，不需要考虑增量同步的情况。
--因为它是在数据表的后边切香肠(比如：你需要保留一年的生产数据，那就传入keep 12个月的参数{分区表是按月分区的话}，
--在下一次归档程序要跑的时候，生产库有个定时的job，都把一年前的数据删除了。所以归档程序不会归档重复的数据，
--并且也相当于增量的归档数据，因为生产库把前面一次归档的数据都删了。


INSERT INTO archive_table_config (
    source_schema,
    source_table,
    archive_table_name,
    date_column,
    dblink_name
) VALUES (
    'ORDERS',
    'ORDER_HEADERS',
    'ARC_ORDER_HEADERS',
    'ORDER_DATE',
    'PROD_RO_LINK'
);
COMMIT;

BEGIN
    history_archive_pkg.sync(
        p_source_schema      => 'ORDERS',
        p_source_table       => 'ORDER_HEADERS',
        p_retention_periods  => 6,
        p_batch_days         => 1
    );
END;
/

BEGIN
    history_archive_pkg.sync_where(
        p_source_schema      => 'ORDERS',
        p_source_table       => 'ORDER_HEADERS',
        p_retention_periods  => 6,
        p_extra_where        => q'[AND s.customer_id = 1001 AND s.status = 'CLOSED']',
        p_batch_days         => 1
    );
END;
/
