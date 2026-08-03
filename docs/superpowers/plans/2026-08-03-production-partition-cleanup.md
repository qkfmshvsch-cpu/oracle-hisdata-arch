# Production Partition Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Change the archive seed partition to 2026 and add a production-side package that drops expired Interval partitions using `HIGH_VALUE`.

**Architecture:** Keep archive synchronization unchanged except for the seed partition literals. Add a standalone production package that validates a single-column RANGE INTERVAL table, derives a retention cutoff from its Interval expression, reads `ALL_TAB_PARTITIONS.HIGH_VALUE` through XML, and drops only expired automatically generated Interval partitions.

**Tech Stack:** Oracle 19c SQL/PLSQL, Oracle dictionary views, `DBMS_XMLGEN`, `DBMS_ASSERT`, PowerShell static checks, Git.

## Global Constraints

- The archive seed partition is `P_BEFORE_2026` with boundary `DATE '2026-01-01'`.
- The public interface is `history_partition_cleanup_pkg.drop_expired_partitions(p_source_schema IN VARCHAR2, p_source_table IN VARCHAR2, p_retention_periods IN PLS_INTEGER)`.
- Support only one-column RANGE INTERVAL tables using fixed positive `NUMTODSINTERVAL(n, 'DAY')` or `NUMTOYMINTERVAL(n, 'MONTH')`.
- Day cutoff: `TRUNC(SYSDATE) - n * p_retention_periods`; month cutoff: `ADD_MONTHS(TRUNC(SYSDATE, 'MM'), -n * p_retention_periods)`.
- Only `INTERVAL = 'YES'` partitions with `HIGH_VALUE <= cutoff` can be dropped. Keep the initial RANGE partition.
- Do not add indexes, deduplication, custom logs, preview mode, or a production Scheduler Job.
- Never overwrite manual modifications in `D:\wp_codex\codex-oracleskills\data-archive`.
- Oracle compile and runtime deletion tests require a separate test database; do not claim they ran locally.

---

### Task 1: Add the failing static contract

**Files:**
- Modify: `data-archive/tests/archive_sql_static_checks.ps1:300-490`

**Interfaces:**
- Produces: checks for `P_BEFORE_2026` / `DATE '2026-01-01'` and the new cleanup package.

- [ ] **Step 1: Load the cleanup package in the test script**

Add `Read-OrEmpty (Join-Path $root '06_prod_partition_cleanup_package.sql')` and replace the old `P_BEFORE_2000` assertion with both new seed literals.

- [ ] **Step 2: Add executable cleanup-package assertions**

```powershell
Assert-Contains $cleanup 'CREATE OR REPLACE PACKAGE history_partition_cleanup_pkg AS' 'cleanup package name'
Assert-Contains $cleanup 'PROCEDURE drop_expired_partitions(' 'cleanup procedure interface'
Assert-Contains $cleanup 'all_tab_partitions' 'partition metadata'
Assert-Contains $cleanup 'HIGH_VALUE' 'partition high value'
Assert-Contains $cleanup "interval_flag = 'YES'" 'interval partitions only'
Assert-Contains $cleanup 'ALTER TABLE ' 'partition drop DDL'
Assert-NotContainsInsensitive $cleanup 'DBMS_SCHEDULER.CREATE_JOB' 'no production scheduler'
```

Add assertions for each public parameter, `ALL_PART_TABLES`, `ALL_PART_KEY_COLUMNS`, both supported Interval expressions, both cutoff formulas, `DBMS_XMLGEN`, `DBMS_OUTPUT.PUT_LINE`, `DROP PARTITION`, and absence of `CREATE INDEX` and `UPDATE GLOBAL INDEXES`.

- [ ] **Step 3: Confirm the test fails before the package exists**

Run `powershell -ExecutionPolicy Bypass -File data-archive/tests/archive_sql_static_checks.ps1`.

Expected: a failure identifying the missing cleanup package contract.

- [ ] **Step 4: Commit the contract**

Run `git add -- data-archive/tests/archive_sql_static_checks.ps1` and `git commit -m "test: define partition cleanup contract"`.

### Task 2: Implement production cleanup

**Files:**
- Create: `data-archive/06_prod_partition_cleanup_package.sql`

**Interfaces:**
- Consumes: `ALL_PART_TABLES`, `ALL_PART_KEY_COLUMNS`, `ALL_TAB_PARTITIONS`, `DBMS_ASSERT`, `DBMS_XMLGEN`, `DBMS_OUTPUT`.
- Produces: `history_partition_cleanup_pkg.drop_expired_partitions(p_source_schema IN VARCHAR2, p_source_table IN VARCHAR2, p_retention_periods IN PLS_INTEGER)`.

- [ ] **Step 1: Create the exact package specification**

```sql
CREATE OR REPLACE PACKAGE history_partition_cleanup_pkg AS
    PROCEDURE drop_expired_partitions(
        p_source_schema     IN VARCHAR2,
        p_source_table      IN VARCHAR2,
        p_retention_periods IN PLS_INTEGER
    );
END history_partition_cleanup_pkg;
/
```

- [ ] **Step 2: Add minimum metadata validation**

Use `DBMS_ASSERT.SCHEMA_NAME` and `DBMS_ASSERT.SIMPLE_SQL_NAME` for identifiers. Query `ALL_PART_TABLES` and `ALL_PART_KEY_COLUMNS`; reject null or negative retention, absent tables, non-RANGE, missing Interval metadata, multi-column keys, and unsupported expressions using `RAISE_APPLICATION_ERROR`. Compact the expression with `REGEXP_REPLACE`, extract the positive interval count, and calculate exactly the two cutoff formulas in Global Constraints.

- [ ] **Step 3: Add HIGH_VALUE scan and destructive DDL**

Use `DBMS_XMLGEN.GETXMLTYPE` to expose dictionary `HIGH_VALUE` LONG text. Read partition name, `INTERVAL` into an `interval_flag` alias, and high-value text. Evaluate only the dictionary-supplied boundary expression. For `interval_flag = 'YES'` and boundary `<=` cutoff, print owner/table/partition/boundary and execute:

```sql
EXECUTE IMMEDIATE
    'ALTER TABLE ' || v_owner || '.' || v_table_name ||
    ' DROP PARTITION ' || v_partition_name;
```

Do not catch a failed DDL. Skip the initial RANGE partition because it does not have `INTERVAL = 'YES'`.

- [ ] **Step 4: Add one commented manual call**

```sql
BEGIN
    history_partition_cleanup_pkg.drop_expired_partitions(
        p_source_schema     => 'ORDERS',
        p_source_table      => 'ORDER_HEADERS',
        p_retention_periods => 12
    );
END;
/
```

- [ ] **Step 5: Run the static checks**

Run `powershell -ExecutionPolicy Bypass -File data-archive/tests/archive_sql_static_checks.ps1`.

Expected: `All archive SQL static checks passed.`

- [ ] **Step 6: Commit the package**

Run `git add -- data-archive/06_prod_partition_cleanup_package.sql` and `git commit -m "feat: add production partition cleanup"`.

### Task 3: Change the archive seed partition and document cleanup

**Files:**
- Modify: `data-archive/04_archive_package.sql:428-430`
- Modify: `data-archive/README.md:7-10,72-80`

**Interfaces:**
- Consumes: current CTAS DDL and the cleanup package interface.
- Produces: new seed boundary and operator guidance.

- [ ] **Step 1: Change only the two archive DDL fragments**

```sql
'(PARTITION P_BEFORE_2026 ' ||
'VALUES LESS THAN (DATE ''2026-01-01'') ' ||
```

No other `history_archive_pkg` logic may change.

- [ ] **Step 2: Add README guidance**

Replace `P_BEFORE_2000` with `P_BEFORE_2026`. Add the production manual-call example and state: only automatic Interval partitions are considered, `HIGH_VALUE <= cutoff` is the rule, the initial RANGE partition remains, monthly 12 and daily 365 retain one year for 1-month/1-day intervals, and DROP PARTITION is irreversible.

- [ ] **Step 3: Verify and commit**

Run `powershell -ExecutionPolicy Bypass -File data-archive/tests/archive_sql_static_checks.ps1`, `git diff --check`, and `git diff HEAD -- data-archive/04_archive_package.sql`.

Expected: static checks pass, no whitespace errors, and archive package diff has only the two seed literals. Commit with `git add -- data-archive/04_archive_package.sql data-archive/README.md` and `git commit -m "feat: align archive seed partition with 2026"`.

### Task 4: Synchronize safely to the local mirror

**Files:**
- Copy new: `D:\wp_codex\codex-oracleskills\data-archive\06_prod_partition_cleanup_package.sql`
- Merge after diff: `D:\wp_codex\codex-oracleskills\data-archive\04_archive_package.sql`
- Merge after diff: `D:\wp_codex\codex-oracleskills\data-archive\README.md`
- Merge after diff: `D:\wp_codex\codex-oracleskills\data-archive\tests\archive_sql_static_checks.ps1`

**Interfaces:**
- Consumes: implementation repository and the user's manually edited local mirror.
- Produces: a synchronized local delivery directory without lost manual edits.

- [ ] **Step 1: Compare SHA-256 hashes and textual differences**

For every existing local target, inspect the diff before writing. Merge only the seed-partition, README, and test assertions planned above; never wholesale-copy a differing local file.

- [ ] **Step 2: Copy only the new cleanup package**

Copy `06_prod_partition_cleanup_package.sql`, which has no local predecessor.

- [ ] **Step 3: Verify both delivery locations**

Run `powershell -ExecutionPolicy Bypass -File data-archive/tests/archive_sql_static_checks.ps1` in the repository and use the absolute local test-script path for the mirror. Expected: both return `All archive SQL static checks passed.`

- [ ] **Step 4: Leave GitHub push explicit**

Run `git status --short --branch`. Do not push unless the user separately requests GitHub synchronization.
