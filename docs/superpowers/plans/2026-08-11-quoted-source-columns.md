# Quoted Source Columns Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Support Oracle source columns that are keywords or case-sensitive quoted identifiers during archive synchronization.

**Architecture:** Keep `clean_name` for object identifiers. Add a separate `quote_column_name` helper that validates and double-quotes a column without uppercasing it. Use it for every dynamic SQL column position, while `archive_table_config.date_column` remains an exact dictionary column name.

**Tech Stack:** Oracle 19c PL/SQL, `DBMS_ASSERT`, PowerShell static checks, Git.

## Global Constraints

- Schema, table, DB Link, and archive table identifiers remain handled by `clean_name`.
- Source and archive columns must be emitted via `quote_column_name` and `DBMS_ASSERT.ENQUOTE_NAME(..., FALSE)`.
- `date_column` must equal the exact source dictionary column name; ordinary columns use uppercase names and quoted mixed-case columns preserve case.
- `p_extra_where` remains trusted caller SQL; callers quote keyword columns themselves.
- Do not change sync interfaces, partition behavior, batching, Scheduler jobs, or the production partition cleanup procedure.
- Preserve local mirror manual changes through diff-based merging.

---

### Task 1: Define quoted-column static contract

**Files:**
- Modify: `data-archive/tests/archive_sql_static_checks.ps1`

**Interfaces:**
- Produces: checks requiring `quote_column_name`, `DBMS_ASSERT.ENQUOTE_NAME`, quoted source column lists, and quoted date-column SQL.

- [ ] **Step 1: Add failing assertions**

Add checks for the helper and its use in the exact SQL assembly points:

```powershell
Assert-Contains $package 'FUNCTION quote_column_name(' 'quoted column helper'
Assert-Contains $package 'DBMS_ASSERT.ENQUOTE_NAME' 'quoted column validation'
Assert-Match $package "p_select_cols\s*:=\s*p_select_cols\s*\|\|\s*'s\.'\s*\|\|\s*quote_column_name" 'quoted source select column'
Assert-Match $package 'v_date_col\s*:=\s*quote_column_name\(' 'quoted date column'
```

Require the minimal private function count to become two and add README assertions for exact source dictionary naming and `s."ORDER"` usage.

- [ ] **Step 2: Confirm red state**

Run `powershell -ExecutionPolicy Bypass -File data-archive/tests/archive_sql_static_checks.ps1`.

Expected: failure because the quoted-column helper and its call sites do not yet exist.

- [ ] **Step 3: Commit test contract**

Run `git add -- data-archive/tests/archive_sql_static_checks.ps1` and `git commit -m "test: require quoted source columns"`.

### Task 2: Implement quoted column handling

**Files:**
- Modify: `data-archive/04_archive_package.sql`
- Modify: `data-archive/README.md`
- Modify: `data-archive/07_custom_sync_examples.sql`

**Interfaces:**
- Consumes: source dictionary column names and `archive_table_config.date_column`.
- Produces: `quote_column_name(p_name IN VARCHAR2, p_label IN VARCHAR2) RETURN VARCHAR2`.

- [ ] **Step 1: Add quote_column_name**

Add a private helper that trims non-null input, invokes `DBMS_ASSERT.ENQUOTE_NAME(v_name, FALSE)`, and converts invalid-name errors to `RAISE_APPLICATION_ERROR(-20000, 'Invalid identifier ' || p_label || ': ' || p_name)`.

- [ ] **Step 2: Preserve exact date-column metadata matching**

In remote dictionary comparisons and binds, use `TRIM(p_cfg.date_column)` instead of `clean_name(p_cfg.date_column, ...)`. Keep `clean_name` for object values only.

- [ ] **Step 3: Quote every SQL column position**

Use `quote_column_name` when building insert/select lists, creating the archive partition key, assigning `v_date_col`, and composing MIN/MAX plus time-window expressions.

- [ ] **Step 4: Document caller contract**

Add README text stating that `date_column` is exact dictionary spelling, and add a `sync_where` example condition `AND s."ORDER" = 'CLOSED'`. Add the same short guidance to the custom examples.

- [ ] **Step 5: Verify and commit**

Run `powershell -ExecutionPolicy Bypass -File data-archive/tests/archive_sql_static_checks.ps1` and `git diff --check`. Commit with `git add -- data-archive/04_archive_package.sql data-archive/README.md data-archive/07_custom_sync_examples.sql` and `git commit -m "feat: quote archive source columns"`.

### Task 3: Safely synchronize local mirror

**Files:**
- Merge after diff: `D:\wp_codex\codex-oracleskills\data-archive\04_archive_package.sql`
- Merge after diff: `D:\wp_codex\codex-oracleskills\data-archive\README.md`
- Merge after diff: `D:\wp_codex\codex-oracleskills\data-archive\07_custom_sync_examples.sql`
- Merge after diff: `D:\wp_codex\codex-oracleskills\data-archive\tests\archive_sql_static_checks.ps1`

**Interfaces:**
- Consumes: completed repository files and user manual notes.
- Produces: local delivery files with manual changes preserved.

- [ ] **Step 1: Compare before writing**

Compare SHA-256 and textual diffs for each local target. Merge only the quoted-column changes; do not overwrite local comments or unrelated scheduling configuration.

- [ ] **Step 2: Verify both locations**

Run the static script in the repository and local mirror. Expected output in both: `PASS: archive SQL minimal contract checks`.

- [ ] **Step 3: Keep GitHub publication explicit**

Run `git status --short --branch`. Do not push unless separately requested.
