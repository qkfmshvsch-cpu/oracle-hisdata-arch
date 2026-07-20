# History Archive Sync API Simplification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the three existing archive synchronization entry points with retention-based `sync` and `sync_where`, and update every delivery caller and contract accordingly.

**Architecture:** Keep one private `run_sync` procedure for source interval detection, cutoff calculation, filtered range discovery, day-window batching, insert, and commit. `sync` passes no runtime condition; `sync_where` validates a required condition and passes it into the same flow. The Scheduler calls `sync` with fixed retention and batch values.

**Tech Stack:** Oracle Database 19c SQL and PL/SQL, `DBMS_SCHEDULER`, PowerShell static contract tests, Git.

## Global Constraints

- Public synchronization APIs are exactly `history_archive_pkg.sync` and `history_archive_pkg.sync_where`; no compatibility wrappers remain.
- Both APIs derive their cutoff from the production source table's fixed positive `N DAY` or `N MONTH` interval and `p_retention_periods`.
- Both APIs execute set-based `INSERT INTO ... SELECT ...` in `p_batch_days` windows and commit after each successful window.
- `sync_where` requires an `AND` condition that references source alias `s` and passes the existing unsafe-fragment checks.
- The archive target table remains monthly `INTERVAL` partitioned.
- Duplicate prevention remains the production source's responsibility.
- Do not add indexes, custom log tables, deduplication, explicit date-window APIs, or SQL*Plus-specific behavior.
- Preserve Oracle Database 19c compatibility.

---

### Task 1: Replace The Package API And Shared Sync Flow

**Files:**
- Modify: `data-archive/tests/archive_sql_static_checks.ps1`
- Modify: `data-archive/04_archive_package.sql`

**Interfaces:**
- Consumes: Existing `archive_table_config`, DB Link metadata helpers, target-table creation, column-list construction, and source interval detection.
- Produces: `sync(p_source_schema VARCHAR2, p_source_table VARCHAR2, p_retention_periods PLS_INTEGER, p_batch_days PLS_INTEGER DEFAULT 1)` and `sync_where(p_source_schema VARCHAR2, p_source_table VARCHAR2, p_retention_periods PLS_INTEGER, p_extra_where VARCHAR2, p_batch_days PLS_INTEGER DEFAULT 1)`.

- [ ] **Step 1: Replace package assertions with the new public contract**

Change the package section of the static test to require the new names and reject the old APIs and mode strings:

```powershell
Assert-Contains $package 'PROCEDURE sync(' 'sync interface'
Assert-Contains $package 'PROCEDURE sync_where(' 'filtered sync interface'
Assert-RegexCount $package 'PROCEDURE\s+sync\s*\(' 2 'sync declaration and body count'
Assert-RegexCount $package 'PROCEDURE\s+sync_where\s*\(' 2 'sync_where declaration and body count'
Assert-NotContainsInsensitive $package 'sync_full' 'old full interface removed'
Assert-NotContainsInsensitive $package 'sync_incremental' 'old incremental interfaces removed'
Assert-NotContainsInsensitive $package 'p_start_date' 'explicit start date removed'
Assert-NotContainsInsensitive $package 'p_end_date' 'explicit end date removed'
Assert-NotContainsInsensitive $package 'p_sync_mode' 'sync mode removed'
Assert-NotContainsInsensitive $package "'FULL'" 'full mode removed'
Assert-NotContainsInsensitive $package "'INCREMENTAL'" 'incremental mode removed'
Assert-Match $package 'p_extra_where\s+IN\s+VARCHAR2[\s\S]*p_batch_days\s+IN\s+PLS_INTEGER\s+DEFAULT\s+1' 'sync_where parameter order'
Assert-Match $package 'normalize_where\(\s*p_extra_where,\s*''p_extra_where'',\s*TRUE,\s*v_runtime_where\s*\)' 'sync_where required condition validation'
Assert-Match $package 'v_bounds_sql\s*:=[\s\S]*v_runtime_where' 'filtered source bounds'
Assert-Match $package 'v_sql\s*:=\s*v_sql\s*\|\|\s*'' ''\s*\|\|\s*v_runtime_where' 'filtered batch insert'
```

Retain the existing assertions for interval detection, cutoff formulas, monthly target partitioning, batch loop, commit behavior, minimal function count, and forbidden features.

- [ ] **Step 2: Run the contract test and verify RED**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File data-archive/tests/archive_sql_static_checks.ps1
```

Expected: FAIL because `sync` and `sync_where` do not exist and the removed procedure names and mode/date parameters are still present.

- [ ] **Step 3: Replace the package specification**

Use exactly this public specification:

```sql
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
```

- [ ] **Step 4: Simplify the private execution flow**

Delete `validate_request`. Change `execute_insert` so every call binds one start and one end date:

```sql
EXECUTE IMMEDIATE p_sql USING p_batch_start, p_batch_end;
v_rows := SQL%ROWCOUNT;
COMMIT;
DBMS_OUTPUT.PUT_LINE('Rows inserted: ' || v_rows);
```

Change `run_sync` to this input shape:

```sql
PROCEDURE run_sync(
    p_source_schema      IN VARCHAR2,
    p_source_table       IN VARCHAR2,
    p_retention_periods  IN PLS_INTEGER,
    p_batch_days         IN PLS_INTEGER,
    p_runtime_where      IN VARCHAR2
)
```

Always validate retention and batch values, detect the source interval, and calculate `v_effective_end_date`. Build the source bounds query with the cutoff bind and append `p_runtime_where` when present:

```sql
v_bounds_sql :=
    'SELECT CAST(MIN(s.' || v_date_col || ') AS DATE), ' ||
    'CAST(MAX(s.' || v_date_col || ') AS DATE) ' ||
    'FROM ' || v_source_ref || ' s ' ||
    'WHERE s.' || v_date_col || ' < :end_date';

IF p_runtime_where IS NOT NULL THEN
    v_bounds_sql := v_bounds_sql || ' ' || p_runtime_where;
END IF;
```

Build every insert with `>= :start_date` and `< :end_date`, append `p_runtime_where` when present, then retain the existing `p_batch_days` loop and per-window `execute_insert` call.

- [ ] **Step 5: Add the two public wrappers**

Implement `sync` as a direct call with a null condition. Implement `sync_where` with required normalization before calling the same private procedure:

```sql
PROCEDURE sync_where(
    p_source_schema      IN VARCHAR2,
    p_source_table       IN VARCHAR2,
    p_retention_periods  IN PLS_INTEGER,
    p_extra_where        IN VARCHAR2,
    p_batch_days         IN PLS_INTEGER DEFAULT 1
) IS
    v_runtime_where VARCHAR2(4000);
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
```

- [ ] **Step 6: Run the contract test and verify GREEN**

Run the same PowerShell test. Expected: `PASS: archive SQL minimal contract checks` with the still-unchanged Scheduler and example assertions also passing.

- [ ] **Step 7: Commit the package change**

```powershell
git add data-archive/04_archive_package.sql data-archive/tests/archive_sql_static_checks.ps1
git commit -m "refactor: simplify archive sync package API"
```

---

### Task 2: Change The Daily Scheduler To Retention-Based Sync

**Files:**
- Modify: `data-archive/tests/archive_sql_static_checks.ps1`
- Modify: `data-archive/05_archive_scheduler_job.sql`

**Interfaces:**
- Consumes: `history_archive_pkg.sync(..., p_retention_periods, p_batch_days)` from Task 1.
- Produces: One disabled daily `ARCHIVE_ORDER_HEADERS_DAILY_JOB` template calling `sync` at 03:00 Asia/Shanghai.

- [ ] **Step 1: Replace Scheduler assertions**

Require two constants and one named-argument `sync` call; remove assertions for lag dates and removed APIs:

```powershell
Assert-Match $jobAction 'c_retention_periods\s+CONSTANT\s+PLS_INTEGER\s*:=\s*1;' 'scheduler retention constant'
Assert-Match $jobAction 'c_batch_days\s+CONSTANT\s+PLS_INTEGER\s*:=\s*1;' 'scheduler batch constant'
Assert-RegexCount $jobAction 'history_archive_pkg\.sync\s*\(' 1 'scheduler sync call count'
Assert-Match $jobAction "p_source_schema\s*=>\s*'ORDERS'" 'scheduler source schema'
Assert-Match $jobAction "p_source_table\s*=>\s*'ORDER_HEADERS'" 'scheduler source table'
Assert-Match $jobAction 'p_retention_periods\s*=>\s*c_retention_periods' 'scheduler retention argument'
Assert-Match $jobAction 'p_batch_days\s*=>\s*c_batch_days' 'scheduler batch argument'
Assert-NotContainsInsensitive $scheduler 'sync_incremental' 'scheduler old call removed'
Assert-NotMatch $jobAction '\bv_(start|end|today)_date\b' 'scheduler date-window variables removed'
```

- [ ] **Step 2: Run the test and verify RED**

Expected: FAIL because the Scheduler still calculates a daily date window and calls `sync_incremental`.

- [ ] **Step 3: Replace the Scheduler action**

Use this minimal action body:

```sql
DECLARE
    c_retention_periods CONSTANT PLS_INTEGER := 1;
    c_batch_days        CONSTANT PLS_INTEGER := 1;
BEGIN
    history_archive_pkg.sync(
        p_source_schema      => 'ORDERS',
        p_source_table       => 'ORDER_HEADERS',
        p_retention_periods  => c_retention_periods,
        p_batch_days         => c_batch_days
    );
END;
```

Keep the existing job name, time zone, repeat interval, disabled state, and `auto_drop => FALSE`. Change comments from incremental synchronization to retention-based synchronization.

- [ ] **Step 4: Run the test and verify GREEN**

Expected: `PASS: archive SQL minimal contract checks`.

- [ ] **Step 5: Commit the Scheduler change**

```powershell
git add data-archive/05_archive_scheduler_job.sql data-archive/tests/archive_sql_static_checks.ps1
git commit -m "refactor: schedule retention-based archive sync"
```

---

### Task 3: Replace Delivery Examples And Documentation

**Files:**
- Modify: `data-archive/tests/archive_sql_static_checks.ps1`
- Modify: `data-archive/07_custom_sync_examples.sql`
- Modify: `data-archive/README.md`

**Interfaces:**
- Consumes: The two public APIs from Task 1 and Scheduler behavior from Task 2.
- Produces: Current installation, manual-call, Scheduler, and recovery instructions with no callable references to removed APIs.

- [ ] **Step 1: Replace example and README assertions**

Require one example for each new API and reject old callable names across the delivery bundle:

```powershell
Assert-Contains $examples 'history_archive_pkg.sync(' 'sync example'
Assert-Contains $examples 'history_archive_pkg.sync_where(' 'filtered sync example'
Assert-Match $examples 'p_retention_periods\s+=>\s+6' 'sync retention example'
Assert-Match $examples "q'\[AND s\.customer_id = 1001 AND s\.status = 'CLOSED'\]'" 'filtered condition example'
Assert-NotContainsInsensitive $deliveryText 'history_archive_pkg.sync_full' 'old full calls removed from delivery'
Assert-NotContainsInsensitive $deliveryText 'history_archive_pkg.sync_incremental' 'old incremental calls removed from delivery'
Assert-Contains $readme 'history_archive_pkg.sync(' 'README sync call'
Assert-Contains $readme 'history_archive_pkg.sync_where(' 'README filtered sync call'
```

Replace old README assertions about baseline-to-incremental cutover, lag windows, and incremental restart with assertions for daily retention-based calls, source-owned duplicate handling, and cleanup-before-rerun recovery.

- [ ] **Step 2: Run the test and verify RED**

Expected: FAIL because the examples and README still call and describe the removed APIs.

- [ ] **Step 3: Reduce the example file to two calls**

Keep the configuration insert, then provide:

```sql
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
```

- [ ] **Step 4: Rewrite the README around the two APIs**

State that both procedures are retention-based and batched. Remove explicit `[start, end)` synchronization, baseline/incremental cutover, lag-day calculations, and calls to removed APIs. Explain that the Scheduler calls `sync` daily with fixed retention and batch settings, duplicate eligibility is controlled at the source, and a failed later batch leaves earlier commits in place so relevant target rows must be corrected or removed before rerunning.

- [ ] **Step 5: Run the test and verify GREEN**

Expected: `PASS: archive SQL minimal contract checks`.

- [ ] **Step 6: Commit examples and documentation**

```powershell
git add data-archive/07_custom_sync_examples.sql data-archive/README.md data-archive/tests/archive_sql_static_checks.ps1
git commit -m "docs: update archive sync calls and scheduler guidance"
```

---

### Task 4: Verify The Complete Delivery And Refresh The Mirror

**Files:**
- Verify: `data-archive/*.sql`
- Verify: `data-archive/README.md`
- Verify: `data-archive/tests/archive_sql_static_checks.ps1`
- Refresh: `D:/wp_codex/codex-oracleskills/data-archive/`

**Interfaces:**
- Consumes: Completed package, Scheduler, examples, docs, and static contract.
- Produces: A clean feature branch and a top-level delivery mirror matching the repository delivery files.

- [ ] **Step 1: Scan the delivery bundle for removed calls and obsolete mode logic**

Run:

```powershell
rg -n "history_archive_pkg\.(sync_full|sync_incremental|sync_incremental_where)|p_sync_mode|p_start_date|p_end_date|INCREMENTAL_WHERE" data-archive
```

Expected: no matches. Mentions in historical design documents are outside the delivery bundle and are not executable calls.

- [ ] **Step 2: Run the complete static contract**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File data-archive/tests/archive_sql_static_checks.ps1
```

Expected: `PASS: archive SQL minimal contract checks`.

- [ ] **Step 3: Check formatting and branch state**

```powershell
git diff --check
git status --short --branch
```

Expected: no whitespace errors and no uncommitted repository changes.

- [ ] **Step 4: Refresh the top-level delivery mirror**

Copy the repository `data-archive` directory contents into `D:/wp_codex/codex-oracleskills/data-archive/` without deleting unrelated workspace files. Then run the mirror's static test:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File D:/wp_codex/codex-oracleskills/data-archive/tests/archive_sql_static_checks.ps1
```

Expected: `PASS: archive SQL minimal contract checks`.

- [ ] **Step 5: Compare delivery hashes**

Compare SHA-256 hashes for `04_archive_package.sql`, `05_archive_scheduler_job.sql`, `07_custom_sync_examples.sql`, `README.md`, and `tests/archive_sql_static_checks.ps1` between the repository worktree and top-level mirror.

Expected: all five file pairs match.

- [ ] **Step 6: Record the Oracle verification boundary**

Report that static verification passed and that package compilation plus runtime execution against a connected Oracle 19c database were not available in this environment.
