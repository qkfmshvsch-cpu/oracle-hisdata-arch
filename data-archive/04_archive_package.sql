-- ============================================================================
-- Oracle historical data archive - minimal copy package
-- Run on the archive database as archive_admin.
-- Oracle Database 19c compatible baseline.
-- ============================================================================


CREATE OR REPLACE PACKAGE history_archive_pkg AS
    PROCEDURE sync(
        p_source_schema      IN VARCHAR2,
        p_source_table       IN VARCHAR2,
        p_retention_periods  IN PLS_INTEGER,
        p_batch_days         IN PLS_INTEGER DEFAULT 1
    );

    PROCEDURE sync_where(
        p_source_schema      IN VARCHAR2,
        p_source_table       IN VARCHAR2,
        p_retention_periods  IN PLS_INTEGER,
        p_extra_where        IN VARCHAR2,
        p_batch_days         IN PLS_INTEGER DEFAULT 1
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
        v_where            VARCHAR2(32767) := TRIM(p_where);
        v_validation_where VARCHAR2(32767) := NULL;
        v_predicate        VARCHAR2(32767);
        v_pos              PLS_INTEGER := 1;
        v_in_literal       BOOLEAN := FALSE;
        v_char             CHAR(1);
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

        WHILE v_pos <= LENGTH(v_where) LOOP
            v_char := SUBSTR(v_where, v_pos, 1);

            IF v_in_literal THEN
                v_validation_where := v_validation_where || ' ';
                IF v_char = '''' THEN
                    IF v_pos < LENGTH(v_where)
                       AND SUBSTR(v_where, v_pos + 1, 1) = '''' THEN
                        v_validation_where := v_validation_where || ' ';
                        v_pos := v_pos + 2;
                    ELSE
                        v_in_literal := FALSE;
                        v_pos := v_pos + 1;
                    END IF;
                ELSE
                    v_pos := v_pos + 1;
                END IF;
            ELSIF v_char = '''' THEN
                v_validation_where := v_validation_where || ' ';
                v_in_literal := TRUE;
                v_pos := v_pos + 1;
            ELSE
                v_validation_where := v_validation_where || v_char;
                v_pos := v_pos + 1;
            END IF;
        END LOOP;

        IF v_in_literal THEN
            RAISE_APPLICATION_ERROR(
                -20005,
                p_label || ' contains an unterminated literal.'
            );
        END IF;

        IF NOT REGEXP_LIKE(v_validation_where, '(^|[^A-Z0-9_$#])S\.', 'i') THEN
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
               v_validation_where,
               '(^|[^A-Z0-9_$#])' ||
               '(INSERT|UPDATE|DELETE|MERGE|DROP|ALTER|CREATE|GRANT|REVOKE|' ||
               'COMMIT|ROLLBACK|EXECUTE|BEGIN|DECLARE|DBMS_[A-Z0-9_$#]*|' ||
               'UTL_[A-Z0-9_$#]*|SELECT|UNION|INTERSECT|MINUS|WITH)' ||
               '([^A-Z0-9_$#]|$)',
               'i'
           ) THEN
            RAISE_APPLICATION_ERROR(-20006, p_label || ' contains a forbidden SQL token.');
        END IF;

        v_predicate := TRIM(SUBSTR(v_where, 4));
        p_result := 'AND (' || v_predicate || ')';
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

    PROCEDURE detect_source_interval(
        p_cfg            IN  archive_table_config%ROWTYPE,
        p_interval_unit  OUT VARCHAR2,
        p_interval_count OUT PLS_INTEGER
    ) IS
        v_sql               VARCHAR2(4000);
        v_partitioning_type VARCHAR2(30);
        v_interval_expr     VARCHAR2(1000);
        v_interval_compact  VARCHAR2(1000);
        v_key_count         PLS_INTEGER;
        v_key_column        VARCHAR2(128);
    BEGIN
        v_sql :=
            'SELECT partitioning_type, interval FROM all_part_tables@' ||
            clean_name(p_cfg.dblink_name, 'dblink_name') ||
            ' WHERE owner = :owner AND table_name = :table_name';

        BEGIN
            EXECUTE IMMEDIATE v_sql
                INTO v_partitioning_type, v_interval_expr
                USING
                    clean_name(p_cfg.source_schema, 'source_schema'),
                    clean_name(p_cfg.source_table, 'source_table');
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(
                    -20018,
                    'Source table is not partitioned: ' ||
                    p_cfg.source_schema || '.' || p_cfg.source_table
                );
        END;

        IF v_partitioning_type <> 'RANGE' OR v_interval_expr IS NULL THEN
            RAISE_APPLICATION_ERROR(
                -20019,
                'Source table must use RANGE INTERVAL partitioning: ' ||
                p_cfg.source_schema || '.' || p_cfg.source_table
            );
        END IF;

        v_sql :=
            'SELECT COUNT(*), MIN(column_name) FROM all_part_key_columns@' ||
            clean_name(p_cfg.dblink_name, 'dblink_name') ||
            q'[ WHERE owner = :owner
                 AND name = :table_name
                 AND object_type = 'TABLE']';

        EXECUTE IMMEDIATE v_sql
            INTO v_key_count, v_key_column
            USING
                clean_name(p_cfg.source_schema, 'source_schema'),
                clean_name(p_cfg.source_table, 'source_table');

        IF v_key_count <> 1
           OR v_key_column <> clean_name(p_cfg.date_column, 'date_column') THEN
            RAISE_APPLICATION_ERROR(
                -20020,
                'Source partition key mismatch for ' ||
                p_cfg.source_schema || '.' || p_cfg.source_table ||
                ': expected configured date_column ' ||
                clean_name(p_cfg.date_column, 'date_column') ||
                ', actual key column ' || v_key_column ||
                ', key count ' || v_key_count
            );
        END IF;

        v_interval_compact := UPPER(
            REGEXP_REPLACE(v_interval_expr, '[[:space:]]', '')
        );

        IF REGEXP_LIKE(
               v_interval_compact,
               '^NUMTODSINTERVAL\(([1-9][0-9]*),''DAY''\)$'
           ) THEN
            p_interval_unit := 'DAY';
        ELSIF REGEXP_LIKE(
                  v_interval_compact,
                  '^NUMTOYMINTERVAL\(([1-9][0-9]*),''MONTH''\)$'
              ) THEN
            p_interval_unit := 'MONTH';
        ELSE
            RAISE_APPLICATION_ERROR(
                -20021,
                'Unsupported source INTERVAL expression for ' ||
                p_cfg.source_schema || '.' || p_cfg.source_table ||
                ': actual interval expression ' || v_interval_expr
            );
        END IF;

        p_interval_count := TO_NUMBER(
            REGEXP_SUBSTR(v_interval_compact, '[0-9]+', 1, 1)
        );
    END detect_source_interval;

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

    PROCEDURE execute_insert(
        p_sql         IN VARCHAR2,
        p_batch_start IN DATE,
        p_batch_end   IN DATE
    ) IS
        v_rows NUMBER;
    BEGIN
        EXECUTE IMMEDIATE p_sql USING p_batch_start, p_batch_end;

        v_rows := SQL%ROWCOUNT;
        COMMIT;
        DBMS_OUTPUT.PUT_LINE('Rows inserted: ' || v_rows);
    END execute_insert;

    PROCEDURE run_sync(
        p_source_schema      IN VARCHAR2,
        p_source_table       IN VARCHAR2,
        p_retention_periods  IN PLS_INTEGER,
        p_batch_days         IN PLS_INTEGER,
        p_runtime_where      IN VARCHAR2
    ) IS
        v_cfg                archive_table_config%ROWTYPE;
        v_archive_table      VARCHAR2(128);
        v_date_col           VARCHAR2(128);
        v_source_ref         VARCHAR2(400);
        v_runtime_where      VARCHAR2(32767);
        v_insert_cols        VARCHAR2(32767);
        v_select_cols        VARCHAR2(32767);
        v_bounds_sql         VARCHAR2(32767);
        v_sql                VARCHAR2(32767);
        v_min_date           DATE;
        v_max_date           DATE;
        v_full_end_date      DATE;
        v_batch_start        DATE;
        v_batch_end          DATE;
        v_effective_end_date DATE;
        v_interval_unit      VARCHAR2(5);
        v_interval_count     PLS_INTEGER;
    BEGIN
        get_config(p_source_schema, p_source_table, v_cfg);
        v_runtime_where := p_runtime_where;

        IF p_retention_periods IS NULL OR p_retention_periods < 0 THEN
            RAISE_APPLICATION_ERROR(
                -20016,
                'p_retention_periods must be zero or greater.'
            );
        END IF;

        IF p_batch_days IS NULL OR p_batch_days <= 0 THEN
            RAISE_APPLICATION_ERROR(
                -20017,
                'p_batch_days must be greater than zero.'
            );
        END IF;

        detect_source_interval(v_cfg, v_interval_unit, v_interval_count);

        IF v_interval_unit = 'DAY' THEN
            v_effective_end_date :=
                TRUNC(SYSDATE) -
                (v_interval_count * p_retention_periods);
        ELSE
            v_effective_end_date :=
                ADD_MONTHS(
                    TRUNC(SYSDATE, 'MM'),
                    -(v_interval_count * p_retention_periods)
                );
        END IF;

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

        v_date_col := clean_name(v_cfg.date_column, 'date_column');
        v_bounds_sql :=
            'SELECT CAST(MIN(s.' || v_date_col || ') AS DATE), ' ||
            'CAST(MAX(s.' || v_date_col || ') AS DATE) ' ||
            'FROM ' || v_source_ref || ' s ' ||
            'WHERE s.' || v_date_col || ' < :end_date';

        IF v_runtime_where IS NOT NULL THEN
            v_bounds_sql := v_bounds_sql || ' ' || v_runtime_where;
        END IF;

        EXECUTE IMMEDIATE v_bounds_sql
            INTO v_min_date, v_max_date
            USING v_effective_end_date;

        IF v_min_date IS NULL THEN
            DBMS_OUTPUT.PUT_LINE('Rows inserted: 0');
            RETURN;
        END IF;

        v_full_end_date := TRUNC(v_max_date) + 1;
        IF v_effective_end_date < v_full_end_date THEN
            v_full_end_date := v_effective_end_date;
        END IF;

        v_sql := v_sql ||
            ' AND s.' || v_date_col || ' >= :start_date' ||
            ' AND s.' || v_date_col || ' < :end_date';

        IF v_runtime_where IS NOT NULL THEN
            v_sql := v_sql || ' ' || v_runtime_where;
        END IF;

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
    END run_sync;

    PROCEDURE sync(
        p_source_schema      IN VARCHAR2,
        p_source_table       IN VARCHAR2,
        p_retention_periods  IN PLS_INTEGER,
        p_batch_days         IN PLS_INTEGER DEFAULT 1
    ) IS
    BEGIN
        run_sync(
            p_source_schema,
            p_source_table,
            p_retention_periods,
            p_batch_days,
            NULL
        );
    END sync;

    PROCEDURE sync_where(
        p_source_schema      IN VARCHAR2,
        p_source_table       IN VARCHAR2,
        p_retention_periods  IN PLS_INTEGER,
        p_extra_where        IN VARCHAR2,
        p_batch_days         IN PLS_INTEGER DEFAULT 1
    ) IS
        v_runtime_where VARCHAR2(32767);
    BEGIN
        normalize_where(
            p_extra_where,
            'p_extra_where',
            TRUE,
            v_runtime_where
        );

        run_sync(
            p_source_schema,
            p_source_table,
            p_retention_periods,
            p_batch_days,
            v_runtime_where
        );
    END sync_where;
END history_archive_pkg;
/
