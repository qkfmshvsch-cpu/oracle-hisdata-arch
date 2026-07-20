# Source INTERVAL Retention Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make full synchronization interpret a generic retention-period count from the production source table's fixed integer N DAY or N MONTH INTERVAL partition definition.

**Architecture:** The archive package will query `ALL_PART_TABLES` and `ALL_PART_KEY_COLUMNS` through the configured DB Link before any target-table CTAS. One new private procedure will validate the source partition key, parse the fixed integer interval, and return unit/count; `run_sync` will calculate a day- or month-aligned cutoff and retain the existing day-sized commit batches.

**Tech Stack:** Oracle Database 19c PL/SQL, dynamic SQL over Oracle DB Link, PowerShell 5.1 static contract tests.

## Global Constraints

- Public full-sync parameter is `p_retention_periods IN PLS_INTEGER`; remove `p_retention_days` without a compatibility overload.
- Accept only fixed positive integer `NUMTODSINTERVAL(n, 'DAY')` and `NUMTOYMINTERVAL(n, 'MONTH')` source definitions.
- Source table must be RANGE INTERVAL partitioned on the single configured `date_column`.
- N DAY cutoff is `TRUNC(SYSDATE) - (n * p_retention_periods)`.
- N MONTH cutoff is `ADD_MONTHS(TRUNC(SYSDATE, 'MM'), -(n * p_retention_periods))`.
- `p_batch_days` remains a positive integer and continues to control commit-window size.
- Archive target tables remain monthly INTERVAL partitioned.
- Keep exactly one declared private function, `clean_name`; add no logs, indexes, deduplication, DBMS_SQL, or compatibility code.
- Incremental interfaces and behavior remain unchanged.

---

### Task 1: Add the source INTERVAL metadata contract and implementation

**Files:**
- Modify: `data-archive/tests/archive_sql_static_checks.ps1:311-335`
- Modify: `data-archive/04_archive_package.sql:9-464`

**Interfaces:**
- Consumes: active `archive_table_config%ROWTYPE` with `source_schema`, `source_table`, `date_column`, and `dblink_name`.
- Produces: `sync_full(p_source_schema VARCHAR2, p_source_table VARCHAR2, p_retention_periods PLS_INTEGER, p_batch_days PLS_INTEGER DEFAULT 1)`.
- Produces private procedure: `detect_source_interval(p_cfg, p_interval_unit OUT VARCHAR2, p_interval_count OUT PLS_INTEGER)`.

- [ ] **Step 1: Replace the old retention assertions with failing metadata and cutoff assertions**

Add these assertions beside the existing full-sync contract checks:

```powershell
Assert-Match $package 'p_retention_periods\s+IN\s+PLS_INTEGER' 'full retention-periods interface'
Assert-NotContainsInsensitive $package 'p_retention_days' 'old retention-days interface removed'
Assert-Contains $package 'PROCEDURE detect_source_interval(' 'source interval detector'
Assert-Contains $package 'all_part_tables@' 'source partition table metadata'
Assert-Contains $package 'all_part_key_columns@' 'source partition key metadata'
Assert-Contains $package "'^NUMTODSINTERVAL\(([1-9][0-9]*),''DAY''\)$'" 'N DAY interval pattern'
Assert-Contains $package "'^NUMTOYMINTERVAL\(([1-9][0-9]*),''MONTH''\)$'" 'N MONTH interval pattern'
Assert-Match $package 'TRUNC\s*\(\s*SYSDATE\s*\)\s*-\s*\(\s*v_interval_count\s*\*\s*p_retention_periods\s*\)' 'N DAY cutoff'
Assert-Match $package "ADD_MONTHS\s*\(\s*TRUNC\s*\(\s*SYSDATE\s*,\s*'MM'\s*\)\s*,\s*-\s*\(\s*v_interval_count\s*\*\s*p_retention_periods\s*\)\s*\)" 'N MONTH cutoff'
Assert-Match $package 'IF\s+p_retention_periods\s+IS\s+NULL\s+OR\s+p_retention_periods\s*<\s*0\s+THEN' 'nonnegative retention-periods validation'
Assert-RegexCount $package '\bFUNCTION\s+[A-Z0-9_$#]+\s*\(' 1 'minimal private function count'
```

Remove the assertions that require `p_retention_days` or the old day-only cutoff.

- [ ] **Step 2: Run the static test and confirm the new contract fails**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "data-archive\tests\archive_sql_static_checks.ps1"
```

Expected: FAIL for the missing `p_retention_periods`, detector, source metadata queries, and day/month cutoff formulas.

- [ ] **Step 3: Rename the public parameter and add the private detector**

Change both package specification and body to:

```sql
PROCEDURE sync_full(
    p_source_schema      IN VARCHAR2,
    p_source_table       IN VARCHAR2,
    p_retention_periods  IN PLS_INTEGER,
    p_batch_days         IN PLS_INTEGER DEFAULT 1
);
```

Add this private procedure after `build_source_ref`:

```sql
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
            'Source partition key must be the configured date column: ' ||
            p_cfg.date_column
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
            'Unsupported source INTERVAL expression: ' || v_interval_expr
        );
    END IF;

    p_interval_count := TO_NUMBER(
        REGEXP_SUBSTR(v_interval_compact, '[0-9]+', 1, 1)
    );
END detect_source_interval;
```

- [ ] **Step 4: Calculate the effective full-sync cutoff before CTAS**

Extend `run_sync` with the retention input and local state:

```sql
PROCEDURE run_sync(
    p_source_schema      IN VARCHAR2,
    p_source_table       IN VARCHAR2,
    p_sync_mode          IN VARCHAR2,
    p_start_date         IN DATE,
    p_end_date           IN DATE,
    p_extra_where        IN VARCHAR2,
    p_retention_periods  IN PLS_INTEGER DEFAULT NULL,
    p_batch_days         IN PLS_INTEGER DEFAULT NULL
) IS
    v_effective_end_date DATE := p_end_date;
    v_interval_unit     VARCHAR2(5);
    v_interval_count    PLS_INTEGER;
```

Immediately after `get_config`, validate and calculate full-sync state:

```sql
IF p_sync_mode = 'FULL' THEN
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
END IF;
```

Pass `v_effective_end_date` to `validate_request`, the source MIN/MAX query, the full cutoff cap, and the final incremental `execute_insert`. Keep `create_archive_table(v_cfg)` after detection and cutoff calculation.

Replace the public full body with:

```sql
PROCEDURE sync_full(
    p_source_schema      IN VARCHAR2,
    p_source_table       IN VARCHAR2,
    p_retention_periods  IN PLS_INTEGER,
    p_batch_days         IN PLS_INTEGER DEFAULT 1
) IS
BEGIN
    run_sync(
        p_source_schema,
        p_source_table,
        'FULL',
        NULL,
        NULL,
        NULL,
        p_retention_periods,
        p_batch_days
    );
END sync_full;
```

Update incremental calls to pass no retention value; the trailing defaults preserve their public behavior.

- [ ] **Step 5: Run static checks and inspect whitespace**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "data-archive\tests\archive_sql_static_checks.ps1"
git diff --check
```

Expected: `PASS: archive SQL minimal contract checks`; `git diff --check` emits no errors.

- [ ] **Step 6: Commit the package and contract test**

```powershell
git add -- data-archive/04_archive_package.sql data-archive/tests/archive_sql_static_checks.ps1
git commit -m "feat: derive retention from source intervals"
```

Expected: one commit containing only the package and static contract test.

---

### Task 2: Update operator documentation and examples

**Files:**
- Modify: `data-archive/README.md:5-164`
- Modify: `data-archive/07_custom_sync_examples.sql:19-28`
- Modify: `data-archive/tests/archive_sql_static_checks.ps1:413-435`

**Interfaces:**
- Consumes: `sync_full(..., p_retention_periods, p_batch_days)` from Task 1.
- Produces: examples for N DAY and N MONTH semantics without references to `p_retention_days`.

- [ ] **Step 1: Add failing documentation assertions**

Replace the old README retention assertion and add:

```powershell
Assert-Contains $examples 'p_retention_periods => 6' 'full retention-periods example'
Assert-NotContainsInsensitive $examples 'p_retention_days' 'examples old retention name removed'
Assert-Contains $readme 'p_retention_periods' 'README retention-period parameter'
Assert-NotContainsInsensitive $readme 'p_retention_days' 'README old retention name removed'
Assert-Contains $readme 'NUMTODSINTERVAL(n, ''DAY'')' 'README N DAY support'
Assert-Contains $readme 'NUMTOYMINTERVAL(n, ''MONTH'')' 'README N MONTH support'
```

- [ ] **Step 2: Run the static test and confirm documentation assertions fail**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "data-archive\tests\archive_sql_static_checks.ps1"
```

Expected: FAIL because README and examples still use `p_retention_days`.

- [ ] **Step 3: Update the full-sync example**

Use this call in `07_custom_sync_examples.sql` and the README:

```sql
BEGIN
    history_archive_pkg.sync_full(
        p_source_schema      => 'ORDERS',
        p_source_table       => 'ORDER_HEADERS',
        p_retention_periods  => 6,
        p_batch_days         => 1
    );
END;
/
```

- [ ] **Step 4: Document supported metadata and period semantics**

Document these exact rules in the README:

```markdown
- 全量同步通过 DB Link 读取生产库源表的 INTERVAL 分区定义。
- 仅支持固定正整数 `NUMTODSINTERVAL(n, 'DAY')` 和 `NUMTOYMINTERVAL(n, 'MONTH')`。
- `p_retention_periods` 表示保留多少个源表分区周期：每 7 天一分区时保留 4 个周期等于 28 天；每 3 个月一分区时保留 2 个周期等于 6 个月。
- 月分区截止时间对齐到自然月第一天，日分区截止时间对齐到当天零点。
- 源表不是受支持的单列 RANGE INTERVAL 分区时，全量同步在创建归档表和复制数据前报错。
```

Keep the target-table statement explicit: archive tables remain monthly INTERVAL partitioned regardless of source granularity.

- [ ] **Step 5: Run checks and commit documentation**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "data-archive\tests\archive_sql_static_checks.ps1"
git diff --check
```

Expected: static checks pass and no whitespace errors.

Commit:

```powershell
git add -- data-archive/README.md data-archive/07_custom_sync_examples.sql data-archive/tests/archive_sql_static_checks.ps1
git commit -m "docs: explain interval-based retention periods"
```

---

### Task 3: Mirror delivery files and perform final verification

**Files:**
- Copy from: `.github-sync/oracle-hisdata-arch/data-archive/04_archive_package.sql`
- Copy from: `.github-sync/oracle-hisdata-arch/data-archive/07_custom_sync_examples.sql`
- Copy from: `.github-sync/oracle-hisdata-arch/data-archive/README.md`
- Copy from: `.github-sync/oracle-hisdata-arch/data-archive/tests/archive_sql_static_checks.ps1`
- Copy to matching paths under: `D:\wp_codex\codex-oracleskills\data-archive`

**Interfaces:**
- Consumes: verified delivery from Tasks 1 and 2.
- Produces: identical delivery files in the user's top-level local `data-archive` directory.

- [ ] **Step 1: Run final checks in the Git repository**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "data-archive\tests\archive_sql_static_checks.ps1"
git diff --check
git status -sb
```

Expected: static checks pass, no whitespace errors, and no uncommitted delivery changes.

- [ ] **Step 2: Copy the four changed delivery files to the top-level local directory**

From `D:\wp_codex\codex-oracleskills\.github-sync\oracle-hisdata-arch`:

```powershell
Copy-Item -LiteralPath 'data-archive\04_archive_package.sql' -Destination '..\..\data-archive\04_archive_package.sql'
Copy-Item -LiteralPath 'data-archive\07_custom_sync_examples.sql' -Destination '..\..\data-archive\07_custom_sync_examples.sql'
Copy-Item -LiteralPath 'data-archive\README.md' -Destination '..\..\data-archive\README.md'
Copy-Item -LiteralPath 'data-archive\tests\archive_sql_static_checks.ps1' -Destination '..\..\data-archive\tests\archive_sql_static_checks.ps1'
```

- [ ] **Step 3: Verify both delivery copies**

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "data-archive\tests\archive_sql_static_checks.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "..\..\data-archive\tests\archive_sql_static_checks.ps1"
```

Expected: both commands print `PASS: archive SQL minimal contract checks`.

- [ ] **Step 4: Report the live-database verification boundary**

Record that static validation completed, but actual package compilation and 1 DAY, 7 DAY, 1 MONTH, 3 MONTH runtime checks require a connected Oracle 19c database with representative source tables and are not claimed unless executed.
