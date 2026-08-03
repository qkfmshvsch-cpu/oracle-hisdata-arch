# Trusted Sync Where Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove `normalize_where` and make `sync_where` pass a trusted condition fragment directly to the existing batch sync logic.

**Architecture:** The public `sync_where` signature remains unchanged. Its `p_extra_where` input is passed directly to `run_sync`, which already appends a non-null condition fragment to the bounds query and batch insert. Documentation and static tests retain only the caller contract that the condition begins with `AND` and uses alias `s`.

**Tech Stack:** Oracle 19c PL/SQL, PowerShell static checks, Git.

## Global Constraints

- `p_extra_where` is a trusted SQL fragment supplied by the caller.
- The caller must start it with `AND` and use source alias `s`.
- Remove all runtime validation, normalization, grouping, and rewriting of this condition.
- Do not change `sync`, `run_sync` batching, partition logic, cleanup package, or Scheduler logic.
- Do not overwrite manual changes in `D:\wp_codex\codex-oracleskills\data-archive`; merge only scoped differences after review.
- Oracle compilation and runtime testing require an Oracle 19c test database and are not claimed by local static validation.

---

### Task 1: Define direct-pass static contract

**Files:**
- Modify: `data-archive/tests/archive_sql_static_checks.ps1:322-354,531-534`

**Interfaces:**
- Consumes: `history_archive_pkg.sync_where` and `run_sync` condition parameter.
- Produces: assertions that reject `normalize_where` and require direct condition passing.

- [ ] **Step 1: Replace old validation assertions**

Remove checks for `normalize_where`, predicate stripping, grouping, q-quote rejection, parenthesis tracking, and validation keywords. Add:

```powershell
Assert-NotContainsInsensitive $package 'normalize_where' 'where normalizer removed'
Assert-Match $package 'run_sync\([\s\S]*p_extra_where\s*\)' 'sync_where direct trusted condition'
Assert-Contains $package "v_runtime_where := p_runtime_where;" 'run_sync direct runtime condition'
```

- [ ] **Step 2: Update README assertions**

Replace encoded restriction assertions with checks that README contains `受信任` and `以 \`AND\` 开头`, retaining the `sync_where` call assertion.

- [ ] **Step 3: Confirm red state**

Run `powershell -ExecutionPolicy Bypass -File data-archive/tests/archive_sql_static_checks.ps1`.

Expected: failure because `normalize_where` remains and `sync_where` does not direct-pass `p_extra_where`.

- [ ] **Step 4: Commit test contract**

Run `git add -- data-archive/tests/archive_sql_static_checks.ps1` followed by `git commit -m "test: require trusted sync where"`.

### Task 2: Simplify sync_where and documentation

**Files:**
- Modify: `data-archive/04_archive_package.sql:47-171,595-618`
- Modify: `data-archive/README.md:168`
- Modify: `data-archive/07_custom_sync_examples.sql:33-41`

**Interfaces:**
- Consumes: unchanged `sync_where` signature and `run_sync(..., p_runtime_where IN VARCHAR2)`.
- Produces: trusted direct condition pass-through.

- [ ] **Step 1: Delete private normalizer**

Delete the complete `normalize_where` procedure. Do not add any new condition validation helper.

- [ ] **Step 2: Directly call run_sync**

Replace the local buffer and normalizer call with:

```sql
        run_sync(
            p_source_schema,
            p_source_table,
            p_retention_periods,
            p_batch_days,
            p_extra_where
        );
```

- [ ] **Step 3: Update comments and operator text**

Describe trusted direct condition use in the package, README, and example. README must say the caller provides valid SQL beginning with `AND` and using alias `s`; the package appends it unchanged to both source bounds and batch insert SQL.

- [ ] **Step 4: Verify implementation**

Run `powershell -ExecutionPolicy Bypass -File data-archive/tests/archive_sql_static_checks.ps1`, `git diff --check`, and `git diff -- data-archive/04_archive_package.sql`.

Expected: static checks pass, no whitespace errors, and package diff only removes the normalizer and directly passes the condition.

- [ ] **Step 5: Commit implementation**

Run `git add -- data-archive/04_archive_package.sql data-archive/README.md data-archive/07_custom_sync_examples.sql` followed by `git commit -m "feat: trust sync where conditions"`.

### Task 3: Safely update local delivery mirror

**Files:**
- Merge after diff: `D:\wp_codex\codex-oracleskills\data-archive\04_archive_package.sql`
- Merge after diff: `D:\wp_codex\codex-oracleskills\data-archive\README.md`
- Merge after diff: `D:\wp_codex\codex-oracleskills\data-archive\07_custom_sync_examples.sql`
- Merge after diff: `D:\wp_codex\codex-oracleskills\data-archive\tests\archive_sql_static_checks.ps1`

**Interfaces:**
- Consumes: completed repository changes and local user-authored comments.
- Produces: local delivery files with manual edits preserved.

- [ ] **Step 1: Inspect SHA-256 and textual diffs**

Compare every local target against the repository. For a differing file, apply only normalizer removal, direct-pass, documentation, example, and static-contract changes.

- [ ] **Step 2: Run both static checks**

Run repository static checks and `D:\wp_codex\codex-oracleskills\data-archive\tests\archive_sql_static_checks.ps1`.

Expected: both emit `PASS: archive SQL minimal contract checks`.

- [ ] **Step 3: Keep publication explicit**

Run `git status --short --branch`. Do not push unless the user separately requests GitHub synchronization.
