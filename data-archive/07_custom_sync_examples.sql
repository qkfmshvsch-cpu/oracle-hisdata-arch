-- Minimal history archive configuration and calls.


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
