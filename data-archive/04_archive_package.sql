-- ============================================================================
-- Oracle historical data archive - minimal copy package
-- Run on the archive database as archive_admin.
-- Oracle Database 19c compatible baseline.
-- ============================================================================


CREATE OR REPLACE PACKAGE history_archive_pkg AS
    PROCEDURE sync_full(
        p_source_schema   IN VARCHAR2,
        p_source_table    IN VARCHAR2,
        p_retention_days  IN PLS_INTEGER,
        p_batch_days      IN PLS_INTEGER DEFAULT 1
    );

    PROCEDURE sync_incremental(
        p_source_schema IN VARCHAR2,
        p_source_table  IN VARCHAR2,
        p_start_date    IN DATE,
        p_end_date      IN DATE
    );

    PROCEDURE sync_incremental_where(
        p_source_schema IN VARCHAR2,
        p_source_table  IN VARCHAR2,
        p_start_date    IN DATE,
        p_end_date      IN DATE,
        p_extra_where   IN VARCHAR2
    );
END history_archive_pkg;
/
CREATE OR REPLACE PACKAGE BODY history_archive_pkg AS
    FUNCTION clean_name(
        p_name  IN VARCHAR2,
        p_label IN VARCHAR2
    ) RETURN VARCHAR2 IS
        v_name VARCHAR2(128) := UPPER(TRIM(p_name));
    BEGIN
        IF v_name IS NULL
           OR NOT REGEXP_LIKE(v_name, '^[A-Z][A-Z0-9_$#]{0,127}$') THEN
            RAISE_APPLICATION_ERROR(
                -20000,
                'Invalid identifier ' || p_label || ': ' || p_name
            );
        END IF;

        RETURN v_name;
    END clean_name;

    PROCEDURE normalize_where(
        p_where    IN VARCHAR2,
        p_label    IN VARCHAR2,
        p_required IN BOOLEAN,
        p_result   OUT VARCHAR2
    ) IS
        v_where VARCHAR2(32767) := TRIM(p_where);
    BEGIN
        IF v_where IS NULL THEN
            IF p_required THEN
                RAISE_APPLICATION_ERROR(-20001, p_label || ' is required.');
            END IF;
            p_result := NULL;
            RETURN;
        END IF;

        IF LENGTHB(v_where) > 4000 THEN
            RAISE_APPLICATION_ERROR(-20002, p_label || ' exceeds 4000 bytes.');
        END IF;

        IF NOT REGEXP_LIKE(v_where, '^AND[[:space:]]+', 'i') THEN
            RAISE_APPLICATION_ERROR(-20003, p_label || ' must start with AND.');
        END IF;

        IF NOT REGEXP_LIKE(v_where, '(^|[^A-Z0-9_$#])S\.', 'i') THEN
            RAISE_APPLICATION_ERROR(-20004, p_label || ' must reference source alias s.');
        END IF;

        IF INSTR(v_where, ';') > 0
           OR INSTR(v_where, ':') > 0
           OR INSTR(v_where, '--') > 0
           OR INSTR(v_where, '/*') > 0
           OR INSTR(v_where, '*/') > 0
           OR REGEXP_LIKE(v_where, '[[:cntrl:]]') THEN
            RAISE_APPLICATION_ERROR(-20005, p_label || ' contains a forbidden delimiter or comment.');
        END IF;

        IF REGEXP_LIKE(
               v_where,
               '(^|[^A-Z0-9_$#])' ||
               '(INSERT|UPDATE|DELETE|MERGE|DROP|ALTER|CREATE|GRANT|REVOKE|' ||
               'COMMIT|ROLLBACK|EXECUTE|BEGIN|DECLARE|DBMS_[A-Z0-9_$#]*|' ||
               'UTL_[A-Z0-9_$#]*)' ||
               '([^A-Z0-9_$#]|$)',
               'i'
           ) THEN
            RAISE_APPLICATION_ERROR(-20006, p_label || ' contains a forbidden SQL token.');
        END IF;

        p_result := v_where;
    END normalize_where;

    PROCEDURE get_config(
        p_source_schema IN VARCHAR2,
        p_source_table  IN VARCHAR2,
        p_cfg           OUT archive_table_config%ROWTYPE
    ) IS
        v_schema VARCHAR2(128);
        v_table  VARCHAR2(128);
    BEGIN
        v_schema := clean_name(p_source_schema, 'source_schema');
        v_table := clean_name(p_source_table, 'source_table');

        SELECT *
        INTO   p_cfg
        FROM   archive_table_config
        WHERE  UPPER(source_schema) = v_schema
        AND    UPPER(source_table) = v_table
        AND    is_active = 'Y';
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(
                -20007,
                'No active archive config found: ' ||
                p_source_schema || '.' || p_source_table
            );
    END get_config;

    PROCEDURE build_source_ref(
        p_cfg        IN  archive_table_config%ROWTYPE,
        p_source_ref OUT VARCHAR2
    ) IS
    BEGIN
        p_source_ref := clean_name(p_cfg.source_schema, 'source_schema') || '.' ||
                        clean_name(p_cfg.source_table, 'source_table') || '@' ||
                        clean_name(p_cfg.dblink_name, 'dblink_name');
    END build_source_ref;

    PROCEDURE validate_partition_column(
        p_cfg IN archive_table_config%ROWTYPE
    ) IS
        v_sql   VARCHAR2(4000);
        v_count NUMBER;
    BEGIN
        v_sql :=
            'SELECT COUNT(*) FROM all_tab_cols@' ||
            clean_name(p_cfg.dblink_name, 'dblink_name') ||
            q'~ WHERE owner = :owner
                AND table_name = :table_name
                AND column_name = :column_name
                AND hidden_column = 'NO'
                AND nullable = 'N'
                AND (data_type = 'DATE'
                     OR REGEXP_LIKE(
                         data_type,
                         '^TIMESTAMP(\([0-9]+\))?$'
                     ))~';

        EXECUTE IMMEDIATE v_sql INTO v_count USING
            clean_name(p_cfg.source_schema, 'source_schema'),
            clean_name(p_cfg.source_table, 'source_table'),
            clean_name(p_cfg.date_column, 'date_column');

        IF v_count <> 1 THEN
            RAISE_APPLICATION_ERROR(
                -20008,
                'Partition column must be visible, NOT NULL, and DATE or TIMESTAMP: ' ||
                p_cfg.date_column
            );
        END IF;
    END validate_partition_column;

    PROCEDURE build_column_lists(
        p_cfg         IN  archive_table_config%ROWTYPE,
        p_insert_cols OUT VARCHAR2,
        p_select_cols OUT VARCHAR2
    ) IS
        v_sql       VARCHAR2(4000);
        v_cur       SYS_REFCURSOR;
        v_col       VARCHAR2(128);
        v_col_count PLS_INTEGER := 0;
    BEGIN
        p_insert_cols := NULL;
        p_select_cols := NULL;
        v_sql :=
            'SELECT column_name FROM all_tab_cols@' ||
            clean_name(p_cfg.dblink_name, 'dblink_name') ||
            ' WHERE owner = :owner AND table_name = :table_name' ||
            ' AND hidden_column = ''NO''' ||
            ' ORDER BY column_id';

        OPEN v_cur FOR v_sql USING
            clean_name(p_cfg.source_schema, 'source_schema'),
            clean_name(p_cfg.source_table, 'source_table');

        LOOP
            FETCH v_cur INTO v_col;
            EXIT WHEN v_cur%NOTFOUND;

            v_col := clean_name(v_col, 'column_name');
            IF p_insert_cols IS NOT NULL THEN
                p_insert_cols := p_insert_cols || ', ';
                p_select_cols := p_select_cols || ', ';
            END IF;
            p_insert_cols := p_insert_cols || v_col;
            p_select_cols := p_select_cols || 's.' || v_col;
            v_col_count := v_col_count + 1;
        END LOOP;

        CLOSE v_cur;

        IF v_col_count = 0 THEN
            RAISE_APPLICATION_ERROR(
                -20009,
                'Cannot read source columns. Check DB Link and SELECT grants.'
            );
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            IF v_cur%ISOPEN THEN
                CLOSE v_cur;
            END IF;
            RAISE;
    END build_column_lists;

    PROCEDURE create_archive_table(
        p_cfg IN archive_table_config%ROWTYPE
    ) IS
        v_archive_table VARCHAR2(128);
        v_source_ref    VARCHAR2(400);
        v_table_count   PLS_INTEGER;
        v_sql           VARCHAR2(32767);
    BEGIN
        v_archive_table := clean_name(
            p_cfg.archive_table_name,
            'archive_table_name'
        );

        SELECT COUNT(*)
        INTO   v_table_count
        FROM   user_tables
        WHERE  table_name = v_archive_table;

        IF v_table_count = 0 THEN
            validate_partition_column(p_cfg);
            build_source_ref(p_cfg, v_source_ref);
            v_sql :=
                'CREATE TABLE ' || v_archive_table ||
                ' TABLESPACE archive_data COMPRESS FOR OLTP ' ||
                'PARTITION BY RANGE (' ||
                clean_name(p_cfg.date_column, 'date_column') || ') ' ||
                'INTERVAL (NUMTOYMINTERVAL(1, ''MONTH'')) ' ||
                '(PARTITION P_BEFORE_2000 ' ||
                'VALUES LESS THAN (DATE ''2000-01-01'') ' ||
                'TABLESPACE archive_data) AS ' ||
                'SELECT s.* FROM ' || v_source_ref ||
                ' s WHERE 1 = 0';
            EXECUTE IMMEDIATE v_sql;
        END IF;
    END create_archive_table;

    PROCEDURE validate_request(
        p_mode          IN  VARCHAR2,
        p_start_date    IN  DATE,
        p_end_date      IN  DATE,
        p_extra_where   IN  VARCHAR2,
        p_runtime_where OUT VARCHAR2
    ) IS
        v_mode VARCHAR2(30) := UPPER(TRIM(p_mode));
    BEGIN
        IF v_mode NOT IN ('FULL', 'INCREMENTAL', 'INCREMENTAL_WHERE') THEN
            RAISE_APPLICATION_ERROR(-20010, 'Invalid sync mode: ' || p_mode);
        END IF;

        IF v_mode = 'FULL' THEN
            IF p_start_date IS NOT NULL THEN
                RAISE_APPLICATION_ERROR(-20011, 'FULL mode does not accept a start date.');
            END IF;
            IF p_extra_where IS NOT NULL THEN
                RAISE_APPLICATION_ERROR(-20012, 'FULL mode does not accept a runtime WHERE.');
            END IF;
            p_runtime_where := NULL;
            RETURN;
        END IF;

        IF p_start_date IS NULL OR p_end_date IS NULL THEN
            RAISE_APPLICATION_ERROR(-20013, v_mode || ' requires start and end dates.');
        END IF;

        IF p_start_date >= p_end_date THEN
            RAISE_APPLICATION_ERROR(-20014, 'start date must be earlier than end date.');
        END IF;

        IF v_mode = 'INCREMENTAL' THEN
            IF p_extra_where IS NOT NULL THEN
                RAISE_APPLICATION_ERROR(-20015, 'INCREMENTAL mode does not accept a runtime WHERE.');
            END IF;
            p_runtime_where := NULL;
        ELSE
            normalize_where(
                p_extra_where,
                'p_extra_where',
                TRUE,
                p_runtime_where
            );
        END IF;
    END validate_request;

    PROCEDURE execute_insert(
        p_sql        IN VARCHAR2,
        p_start_date IN DATE,
        p_end_date   IN DATE
    ) IS
        v_rows NUMBER;
    BEGIN
        IF p_start_date IS NOT NULL AND p_end_date IS NOT NULL THEN
            EXECUTE IMMEDIATE p_sql USING p_start_date, p_end_date;
        ELSIF p_end_date IS NOT NULL THEN
            EXECUTE IMMEDIATE p_sql USING p_end_date;
        ELSE
            EXECUTE IMMEDIATE p_sql;
        END IF;

        v_rows := SQL%ROWCOUNT;
        COMMIT;
        DBMS_OUTPUT.PUT_LINE('Rows inserted: ' || v_rows);
    END execute_insert;

    PROCEDURE run_sync(
        p_source_schema IN VARCHAR2,
        p_source_table  IN VARCHAR2,
        p_sync_mode     IN VARCHAR2,
        p_start_date    IN DATE,
        p_end_date      IN DATE,
        p_extra_where   IN VARCHAR2,
        p_batch_days    IN PLS_INTEGER DEFAULT NULL
    ) IS
        v_cfg           archive_table_config%ROWTYPE;
        v_archive_table VARCHAR2(128);
        v_date_col      VARCHAR2(128);
        v_source_ref    VARCHAR2(400);
        v_runtime_where VARCHAR2(4000);
        v_insert_cols   VARCHAR2(32767);
        v_select_cols   VARCHAR2(32767);
        v_bounds_sql    VARCHAR2(32767);
        v_sql           VARCHAR2(32767);
        v_min_date      DATE;
        v_max_date      DATE;
        v_full_end_date DATE;
        v_batch_start   DATE;
        v_batch_end     DATE;
    BEGIN
        get_config(p_source_schema, p_source_table, v_cfg);
        validate_request(
            p_sync_mode,
            p_start_date,
            p_end_date,
            p_extra_where,
            v_runtime_where
        );

        create_archive_table(v_cfg);
        build_column_lists(v_cfg, v_insert_cols, v_select_cols);
        build_source_ref(v_cfg, v_source_ref);

        v_archive_table := clean_name(
            v_cfg.archive_table_name,
            'archive_table_name'
        );

        v_sql :=
            'INSERT INTO ' || v_archive_table ||
            ' (' || v_insert_cols || ') ' ||
            'SELECT ' || v_select_cols ||
            ' FROM ' || v_source_ref || ' s ' ||
            'WHERE 1 = 1';

        IF p_sync_mode = 'FULL' THEN
            v_date_col := clean_name(v_cfg.date_column, 'date_column');
            v_bounds_sql :=
                'SELECT CAST(MIN(s.' || v_date_col || ') AS DATE), ' ||
                'CAST(MAX(s.' || v_date_col || ') AS DATE) ' ||
                'FROM ' || v_source_ref || ' s ' ||
                'WHERE s.' || v_date_col || ' < :end_date';
            EXECUTE IMMEDIATE v_bounds_sql
                INTO v_min_date, v_max_date
                USING p_end_date;

            IF v_min_date IS NULL THEN
                DBMS_OUTPUT.PUT_LINE('Rows inserted: 0');
                RETURN;
            END IF;

            v_full_end_date := TRUNC(v_max_date) + 1;
            IF p_end_date < v_full_end_date THEN
                v_full_end_date := p_end_date;
            END IF;

            v_sql := v_sql ||
                ' AND s.' || v_date_col || ' >= :start_date' ||
                ' AND s.' || v_date_col || ' < :end_date';
            v_batch_start := v_min_date;

            WHILE v_batch_start < v_full_end_date LOOP
                v_batch_end := v_batch_start + p_batch_days;
                IF v_batch_end > v_full_end_date THEN
                    v_batch_end := v_full_end_date;
                END IF;

                DBMS_OUTPUT.PUT_LINE(
                    'Full batch start/end: ' ||
                    v_batch_start || ' / ' || v_batch_end
                );
                execute_insert(v_sql, v_batch_start, v_batch_end);
                v_batch_start := v_batch_end;
            END LOOP;
            RETURN;
        END IF;

        IF p_start_date IS NOT NULL OR p_end_date IS NOT NULL THEN
            v_date_col := clean_name(v_cfg.date_column, 'date_column');
        END IF;

        IF p_start_date IS NOT NULL THEN
            v_sql := v_sql || ' AND s.' || v_date_col || ' >= :start_date';
        END IF;

        IF p_end_date IS NOT NULL THEN
            v_sql := v_sql || ' AND s.' || v_date_col || ' < :end_date';
        END IF;

        IF v_runtime_where IS NOT NULL THEN
            v_sql := v_sql || ' ' || v_runtime_where;
        END IF;

        execute_insert(v_sql, p_start_date, p_end_date);
    END run_sync;

    PROCEDURE sync_full(
        p_source_schema   IN VARCHAR2,
        p_source_table    IN VARCHAR2,
        p_retention_days  IN PLS_INTEGER,
        p_batch_days      IN PLS_INTEGER DEFAULT 1
    ) IS
        v_range_end_date DATE;
    BEGIN
        IF p_retention_days IS NULL OR p_retention_days < 0 THEN
            RAISE_APPLICATION_ERROR(-20016, 'p_retention_days must be zero or greater.');
        END IF;

        IF p_batch_days IS NULL OR p_batch_days <= 0 THEN
            RAISE_APPLICATION_ERROR(-20017, 'p_batch_days must be greater than zero.');
        END IF;

        v_range_end_date := TRUNC(SYSDATE) - p_retention_days;
        run_sync(
            p_source_schema,
            p_source_table,
            'FULL',
            NULL,
            v_range_end_date,
            NULL,
            p_batch_days
        );
    END sync_full;

    PROCEDURE sync_incremental(
        p_source_schema IN VARCHAR2,
        p_source_table  IN VARCHAR2,
        p_start_date    IN DATE,
        p_end_date      IN DATE
    ) IS
    BEGIN
        run_sync(
            p_source_schema,
            p_source_table,
            'INCREMENTAL',
            p_start_date,
            p_end_date,
            NULL
        );
    END sync_incremental;

    PROCEDURE sync_incremental_where(
        p_source_schema IN VARCHAR2,
        p_source_table  IN VARCHAR2,
        p_start_date    IN DATE,
        p_end_date      IN DATE,
        p_extra_where   IN VARCHAR2
    ) IS
    BEGIN
        run_sync(
            p_source_schema,
            p_source_table,
            'INCREMENTAL_WHERE',
            p_start_date,
            p_end_date,
            p_extra_where
        );
    END sync_incremental_where;
END history_archive_pkg;
/
