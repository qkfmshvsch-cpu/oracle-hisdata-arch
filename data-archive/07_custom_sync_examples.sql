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
    history_archive_pkg.sync_full('ORDERS', 'ORDER_HEADERS');
END;
/

BEGIN
    history_archive_pkg.sync_incremental(
        'ORDERS', 'ORDER_HEADERS', DATE '2024-01-01', DATE '2024-02-01'
    );
END;
/

BEGIN
    history_archive_pkg.sync_incremental_where(
        'ORDERS', 'ORDER_HEADERS', DATE '2024-01-01', DATE '2024-02-01',
        q'[AND s.customer_id = 1001 AND s.status = 'CLOSED']'
    );
END;
/
