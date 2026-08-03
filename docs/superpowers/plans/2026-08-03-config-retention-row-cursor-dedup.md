# Configured Retention, Row-Cursor Batching, And Deduplication Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Read retention from configuration, copy source rows using `DBMS_SQL` row batching, and prevent duplicate archive rows through source primary or unique keys.

**Architecture:** `archive_table_config` is the sole source of retention. The package validates its configuration against source `RANGE INTERVAL` metadata over the DB Link, reads source keys, fetches typed source rows through `DBMS_SQL`, and skips a row when its archive-side key already exists.

**Tech Stack:** Oracle Database 19c SQL/PLSQL, `DBMS_SQL`, `ALL_CONSTRAINTS@DB_LINK`, `ALL_CONS_COLUMNS@DB_LINK`, `DBMS_SCHEDULER`, PowerShell static contract checks.

## Global Constraints

- Do not add index DDL, audit tables, retry state, compatibility wrappers, or external clients.
- Support only `DAY` and `MONTH`; one year is `MONTH + 12`.
- Preserve all existing Chinese comments in `data-archive/07_custom_sync_examples.sql`.
- Keep the archive target monthly interval-partitioned and retain existing `sync_where` safety validation.
- No Oracle connection exists locally; Oracle 19c compile/runtime validation remains deployment work.

---

### Task 1: Define The New Static Contract

**Files:**
- Modify: `data-archive/tests/archive_sql_static_checks.ps1`

**Interfaces:**
- Consumes: the approved configuration, API, cursor, and deduplication rules.
- Produces: a red static contract for the old package.

- [ ] **Step 1: Replace old retention and date-window assertions**

Remove assertions requiring `p_retention_periods`, `p_batch_days`, date-window variables, `execute_insert`, “no deduplication”, and “no DBMS_SQL”. Require the schema and new APIs:

```powershell
Assert-Match $tables 'keep_interval_unit\s+VARCHAR2\(10\)\s+NOT\s+NULL' 'retention unit column'
Assert-Match $tables 'keep_interval_count\s+NUMBER\(10\)\s+NOT\s+NULL' 'retention count column'
Assert-Match $tables "CHECK\s*\(\s*keep_interval_unit\s+IN\s*\('DAY',\s*'MONTH'\)\s*\)" 'retention unit constraint'
Assert-Match $package 'p_batch_rows\s+IN\s+PLS_INTEGER\s+DEFAULT\s+10000' 'row batch interface'
Assert-NotContainsInsensitive $package 'p_retention_periods' 'retention parameter removed'
Assert-NotContainsInsensitive $package 'p_batch_days' 'date batch parameter removed'
```

- [ ] **Step 2: Add cursor and deduplication assertions**

Require `DBMS_SQL.OPEN_CURSOR`, `DBMS_SQL.PARSE`, `DBMS_SQL.FETCH_ROWS`, typed `DEFINE_COLUMN`/`COLUMN_VALUE`, positive `p_batch_rows` validation, processed-row counter, `COMMIT`, `ALL_CONSTRAINTS@`, `ALL_CONS_COLUMNS@`, primary-key preference, a no-key `RAISE_APPLICATION_ERROR`, and an archive-side `NOT EXISTS` predicate. Allow `NOT EXISTS`; retain the ban on archive `CREATE INDEX`.

- [ ] **Step 3: Update Scheduler, examples, and README assertions**

Require only `p_source_schema`, `p_source_table`, and `p_batch_rows` in the Scheduler and examples. Require `keep_interval_unit`, `keep_interval_count`, source-key prerequisite, and duplicate-safe reruns in README. Remove checks that require fixed Scheduler retention or statements that reruns insert duplicates.

- [ ] **Step 4: Run the test and confirm the expected red state**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File data-archive/tests/archive_sql_static_checks.ps1
```

Expected: failure for missing configuration columns, `p_batch_rows`, cursor, key discovery, and deduplication requirements.

- [ ] **Step 5: Commit**

```powershell
git add data-archive/tests/archive_sql_static_checks.ps1
git commit -m "test: define cursor archive contract"
```

### Task 2: Implement Configuration, Cursor, And Deduplication

**Files:**
- Modify: `data-archive/02_archive_control_tables.sql`
- Modify: `data-archive/04_archive_package.sql`

**Interfaces:**
- Consumes: configuration `keep_interval_unit`, `keep_interval_count`, source DB Link metadata, and `p_batch_rows`.
- Produces:

```sql
PROCEDURE sync(
    p_source_schema IN VARCHAR2,
    p_source_table  IN VARCHAR2,
    p_batch_rows    IN PLS_INTEGER DEFAULT 10000
);

PROCEDURE sync_where(
    p_source_schema IN VARCHAR2,
    p_source_table  IN VARCHAR2,
    p_extra_where   IN VARCHAR2,
    p_batch_rows    IN PLS_INTEGER DEFAULT 10000
);
```

- [ ] **Step 1: Extend `archive_table_config`**

Add the two columns after `date_column` and the named checks:

```sql
keep_interval_unit  VARCHAR2(10) NOT NULL,
keep_interval_count NUMBER(10)   NOT NULL,
CONSTRAINT ck_archive_config_keep_unit
    CHECK (keep_interval_unit IN ('DAY', 'MONTH')),
CONSTRAINT ck_archive_config_keep_count
    CHECK (keep_interval_count = TRUNC(keep_interval_count)
           AND keep_interval_count > 0),
```

- [ ] **Step 2: Replace public retention and batching parameters**

Remove `p_retention_periods`, `p_batch_days`, time-window discovery, and `execute_insert`. Validate `p_batch_rows > 0`; read the keep columns from the active configuration; compare normalized `keep_interval_unit` to `detect_source_interval`; calculate cutoff as:

```sql
IF v_keep_unit = 'DAY' THEN
    v_effective_end_date := TRUNC(SYSDATE) - v_cfg.keep_interval_count;
ELSE
    v_effective_end_date := ADD_MONTHS(
        TRUNC(SYSDATE, 'MM'),
        -v_cfg.keep_interval_count
    );
END IF;
```

Raise an application error before DDL/DML for an invalid count or source/configuration unit mismatch. Retain source positive N-day/N-month interval parsing and partition-key checks.

- [ ] **Step 3: Discover source keys deterministically**

Add a private routine querying `ALL_CONSTRAINTS@<dblink>` and `ALL_CONS_COLUMNS@<dblink>`. Select enabled `P` first; otherwise use enabled `U` ordered by `constraint_name`; order columns by `position`. Raise `-20022` with the schema/table if neither is available. Remember whether the chosen key is primary.

- [ ] **Step 4: Build typed `DBMS_SQL` fetch and insert helpers**

Use source metadata and matching `DBMS_SQL.DEFINE_COLUMN`, `COLUMN_VALUE`, and `BIND_VARIABLE` overloads for visible `VARCHAR2`/`CHAR`, `NUMBER`, `DATE`, `TIMESTAMP`, `RAW`, `CLOB`, and `BLOB` columns. Reject another data type before copying with an application error naming the column/type. Build a local key-existence query using equality for primary keys and null-safe equality for a fallback unique key:

```sql
(t.KEY_COL = :key_n OR (t.KEY_COL IS NULL AND :key_n IS NULL))
```

No index statement is added.

- [ ] **Step 5: Add row cursor commits**

Open a `DBMS_SQL` cursor selecting visible source columns from the DB Link where the date column is before cutoff and the validated optional `p_extra_where` applies. For each fetched row, look up the key locally, insert only when absent, and count every processed source row. Commit when `p_batch_rows` is reached and after the final partial batch. Close opened cursors in normal and exception paths, then re-raise errors. Print processed, inserted, and duplicate-skipped counts at each commit.

- [ ] **Step 6: Run the new static contract**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File data-archive/tests/archive_sql_static_checks.ps1
```

Expected: `PASS: archive SQL minimal contract checks`.

- [ ] **Step 7: Commit**

```powershell
git add data-archive/02_archive_control_tables.sql data-archive/04_archive_package.sql
git commit -m "feat: add cursor archive deduplication"
```

### Task 3: Align Scheduler, Examples, And Operations Documentation

**Files:**
- Modify: `data-archive/05_archive_scheduler_job.sql`
- Modify: `data-archive/07_custom_sync_examples.sql`
- Modify: `data-archive/README.md`
- Modify: `data-archive/tests/archive_sql_static_checks.ps1`

**Interfaces:**
- Consumes: Task 2 public APIs and configuration-driven retention.
- Produces: executable calls and accurate operational guidance.

- [ ] **Step 1: Update the Scheduler template**

Replace both old constants with:

```sql
c_batch_rows CONSTANT PLS_INTEGER := 10000;
```

Call `history_archive_pkg.sync` with source schema/table and `p_batch_rows => c_batch_rows`. Preserve job name, daily 03:00 `Asia/Shanghai`, `enabled => FALSE`, and `auto_drop => FALSE`.

- [ ] **Step 2: Update examples while preserving manual comments**

Do not delete or alter opening Chinese comments in `07_custom_sync_examples.sql`. Add `keep_interval_unit => 'MONTH'` and `keep_interval_count => 12` to its configuration insert; replace old runtime arguments with `p_batch_rows => 10000`.

- [ ] **Step 3: Rewrite README usage and recovery text**

Document configuration-driven retention, accepted units, `MONTH + 12`, key discovery, no-key failure, duplicate skipping, row-batch commits, no automatic index creation, and potential no-index lookup cost. Replace instructions to delete target rows before rerun with duplicate-safe rerun guidance.

- [ ] **Step 4: Run full checks and inspect scope**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File data-archive/tests/archive_sql_static_checks.ps1
git diff --check
git status --short
```

Expected: static check prints `PASS: archive SQL minimal contract checks`; diff check prints nothing; status lists only intended delivery edits before commit.

- [ ] **Step 5: Commit**

```powershell
git add data-archive/05_archive_scheduler_job.sql data-archive/07_custom_sync_examples.sql data-archive/README.md data-archive/tests/archive_sql_static_checks.ps1
git commit -m "docs: align cursor archive usage"
```

## Final Verification

- [ ] Run the static contract and retain its `PASS` output.
- [ ] Run `git diff --check origin/main..HEAD` and `git status --short --branch`.
- [ ] Compare the opening comments in `07_custom_sync_examples.sql` with the pre-change file; they must remain verbatim.
- [ ] State that Oracle 19c compilation and live tests for primary keys, nullable unique keys, no key, empty source, multiple commits, and post-failure rerun remain deployment verification.
