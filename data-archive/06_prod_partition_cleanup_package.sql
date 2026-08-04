CREATE OR REPLACE PACKAGE history_partition_cleanup_pkg AS
    PROCEDURE drop_expired_partitions(
        p_source_schema     IN VARCHAR2,
        p_source_table      IN VARCHAR2,
        p_retention_periods IN PLS_INTEGER
    );
END history_partition_cleanup_pkg;
/

CREATE OR REPLACE PACKAGE BODY history_partition_cleanup_pkg AS
    PROCEDURE drop_expired_partitions(
        p_source_schema     IN VARCHAR2,
        p_source_table      IN VARCHAR2,
        p_retention_periods IN PLS_INTEGER
    ) IS
        v_owner                 VARCHAR2(128);
        v_table_name            VARCHAR2(128);
        v_ddl_owner             VARCHAR2(261);
        v_ddl_table_name        VARCHAR2(261);
        v_partition_name        VARCHAR2(261);
        v_partitioning_type     VARCHAR2(30);
        v_interval_expression   VARCHAR2(1000);
        v_interval_compact      VARCHAR2(1000);
        v_interval_unit         VARCHAR2(5);
        v_interval_count        PLS_INTEGER;
        v_key_count             PLS_INTEGER;
        v_cutoff                 TIMESTAMP(9);
        v_partition_boundary     TIMESTAMP(9);
    BEGIN
        IF p_source_schema IS NULL OR TRIM(p_source_schema) IS NULL
           OR p_source_table IS NULL OR TRIM(p_source_table) IS NULL THEN
            RAISE_APPLICATION_ERROR(
                -20001,
                'p_source_schema and p_source_table are required.'
            );
        END IF;

        IF p_retention_periods IS NULL OR p_retention_periods < 0 THEN
            RAISE_APPLICATION_ERROR(
                -20002,
                'p_retention_periods must be zero or greater.'
            );
        END IF;

        BEGIN
            v_owner := DBMS_ASSERT.SCHEMA_NAME(
                UPPER(TRIM(p_source_schema))
            );
            v_table_name := DBMS_ASSERT.SIMPLE_SQL_NAME(
                UPPER(TRIM(p_source_table))
            );
            v_ddl_owner := DBMS_ASSERT.ENQUOTE_NAME(v_owner, FALSE);
            v_ddl_table_name := DBMS_ASSERT.ENQUOTE_NAME(
                v_table_name,
                FALSE
            );
        EXCEPTION
            WHEN OTHERS THEN
                RAISE_APPLICATION_ERROR(
                    -20003,
                    'Invalid source schema or table identifier.'
                );
        END;

        BEGIN
            SELECT partitioning_type, interval
              INTO v_partitioning_type, v_interval_expression
              FROM ALL_PART_TABLES
             WHERE owner = v_owner
               AND table_name = v_table_name;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(
                    -20004,
                    'Source table is not partitioned or is not visible: ' ||
                    v_owner || '.' || v_table_name
                );
        END;

        IF v_partitioning_type <> 'RANGE' THEN
            RAISE_APPLICATION_ERROR(
                -20005,
                'Source table must use RANGE partitioning: ' ||
                v_owner || '.' || v_table_name
            );
        END IF;

        IF v_interval_expression IS NULL THEN
            RAISE_APPLICATION_ERROR(
                -20006,
                'Source table must define INTERVAL metadata: ' ||
                v_owner || '.' || v_table_name
            );
        END IF;

        SELECT COUNT(*)
          INTO v_key_count
          FROM ALL_PART_KEY_COLUMNS
         WHERE owner = v_owner
           AND name = v_table_name
           AND object_type = 'TABLE';

        IF v_key_count <> 1 THEN
            RAISE_APPLICATION_ERROR(
                -20007,
                'Source table must have exactly one partition key column: ' ||
                v_owner || '.' || v_table_name ||
                ', actual key count ' || v_key_count
            );
        END IF;

        v_interval_compact := UPPER(
            REGEXP_REPLACE(v_interval_expression, '[[:space:]]', '')
        );

        IF REGEXP_LIKE(
               v_interval_compact,
               '^NUMTODSINTERVAL\(([1-9][0-9]*),''DAY''\)$'
           ) THEN
            v_interval_unit := 'DAY';
        ELSIF REGEXP_LIKE(
                  v_interval_compact,
                  '^NUMTOYMINTERVAL\(([1-9][0-9]*),''MONTH''\)$'
              ) THEN
            v_interval_unit := 'MONTH';
        ELSE
            RAISE_APPLICATION_ERROR(
                -20008,
                'Unsupported source INTERVAL expression for ' ||
                v_owner || '.' || v_table_name ||
                ': actual interval expression ' || v_interval_expression
            );
        END IF;

        v_interval_count := TO_NUMBER(
            REGEXP_SUBSTR(v_interval_compact, '[0-9]+', 1, 1)
        );

        IF v_interval_unit = 'DAY' THEN
            v_cutoff := CAST(TRUNC(SYSDATE) AS TIMESTAMP) -
                        NUMTODSINTERVAL(
                            v_interval_count * p_retention_periods,
                            'DAY'
                        );
        ELSE
            v_cutoff := CAST(TRUNC(SYSDATE, 'MM') AS TIMESTAMP) -
                        NUMTOYMINTERVAL(
                            v_interval_count * p_retention_periods,
                            'MONTH'
                        );
        END IF;

        FOR r_partition IN (
            SELECT partition_name,
                   interval_flag,
                   high_value
              FROM XMLTABLE(
                       '/ROWSET/ROW'
                       PASSING DBMS_XMLGEN.GETXMLTYPE(
                           'SELECT partition_name, ' ||
                           'interval AS interval_flag, high_value ' ||
                           'FROM all_tab_partitions ' ||
                           'WHERE table_owner = ' ||
                           DBMS_ASSERT.ENQUOTE_LITERAL(v_owner) || ' ' ||
                           'AND table_name = ' ||
                           DBMS_ASSERT.ENQUOTE_LITERAL(v_table_name) || ' ' ||
                           'ORDER BY partition_position'
                       )
                       COLUMNS
                           partition_name VARCHAR2(128)  PATH 'PARTITION_NAME',
                           interval_flag  VARCHAR2(3)    PATH 'INTERVAL_FLAG',
                           high_value     VARCHAR2(4000) PATH 'HIGH_VALUE'
                   )
        ) LOOP
            IF r_partition.interval_flag = 'YES' THEN
                EXECUTE IMMEDIATE
                    'SELECT CAST(' || r_partition.high_value ||
                    ' AS TIMESTAMP(9)) FROM dual'
                    INTO v_partition_boundary;

                IF v_partition_boundary <= v_cutoff THEN
                    v_partition_name := DBMS_ASSERT.ENQUOTE_NAME(
                        r_partition.partition_name,
                        FALSE
                    );

                    DBMS_OUTPUT.PUT_LINE(
                        'Dropping partition: ' ||
                        v_owner || '.' || v_table_name || '.' ||
                        v_partition_name ||
                        ', boundary=' ||
                        TO_CHAR(v_partition_boundary, 'YYYY-MM-DD HH24:MI:SS')
                    );

                    EXECUTE IMMEDIATE
                        'ALTER TABLE ' ||
                        v_ddl_owner || '.' || v_ddl_table_name ||
                        ' DROP PARTITION ' || v_partition_name ||
                        ' UPDATE GLOBAL INDEXES';
                END IF;
            END IF;
        END LOOP;
    END drop_expired_partitions;
END history_partition_cleanup_pkg;
/

-- BEGIN
--     history_partition_cleanup_pkg.drop_expired_partitions(
--         p_source_schema     => 'ORDERS',
--         p_source_table      => 'ORDER_HEADERS',
--         p_retention_periods => 12
--     );
-- END;
-- /
