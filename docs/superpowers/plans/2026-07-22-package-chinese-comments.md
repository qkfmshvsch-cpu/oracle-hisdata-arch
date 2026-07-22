# Archive Package Chinese Comments Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add concise Chinese learning-oriented comments to `04_archive_package.sql` without changing PL/SQL behavior.

**Architecture:** Keep the package code byte-for-byte equivalent after SQL comments are removed. Add responsibility comments before each unit and intent comments before complex validation, metadata, dynamic SQL, cutoff, and batch blocks.

**Tech Stack:** Oracle Database 19c PL/SQL, PowerShell static contract tests, Git.

## Global Constraints

- Modify production content only in `data-archive/04_archive_package.sql`.
- Add Chinese `--` comments only; do not change executable SQL or PL/SQL.
- Explain intent and constraints, not obvious assignments.
- Preserve the public `sync` and `sync_where` interfaces and all existing validation and batching behavior.
- Refresh the top-level `data-archive` mirror non-destructively.

---

### Task 1: Add Chinese Package Comments

**Files:**
- Modify: `data-archive/04_archive_package.sql`

**Interfaces:**
- Consumes: The existing Oracle 19c package at current branch HEAD.
- Produces: The same package behavior with Chinese study comments.

- [ ] **Step 1: Capture the executable-content baseline**

Create a temporary comparison artifact by removing full-line `--` comments from `04_archive_package.sql`. This baseline will prove that the final change is comment-only.

- [ ] **Step 2: Add unit responsibility comments**

Add concise Chinese comments before:

```text
history_archive_pkg package specification
clean_name
normalize_where
get_config
build_source_ref
detect_source_interval
validate_partition_column
build_column_lists
create_archive_table
execute_insert
run_sync
sync
sync_where
```

- [ ] **Step 3: Add key block comments**

Explain these non-obvious blocks:

```text
WHERE delimiter/token restrictions
ordinary quoted-literal masking
parenthesis-depth and runtime q-quote validation
DB Link source reference assembly
remote RANGE INTERVAL metadata parsing
partition key and configured date-column matching
source/target column-list matching
monthly interval target CTAS
source interval-based retention cutoff
filtered MIN/MAX range lookup
[start, end) insert SQL and positional binds
per-window commit behavior
```

- [ ] **Step 4: Prove the change is comment-only**

Remove full-line `--` comments from the modified file using the same comparison method as Step 1 and compare it with the baseline.

Expected: no executable-content difference.

- [ ] **Step 5: Run the repository static contract**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File data-archive/tests/archive_sql_static_checks.ps1
```

Expected: `PASS: archive SQL minimal contract checks`.

- [ ] **Step 6: Check and commit**

```powershell
git diff --check
git add data-archive/04_archive_package.sql
git commit -m "docs: add Chinese comments to archive package"
```

Expected: only `04_archive_package.sql` is committed for this task.

---

### Task 2: Refresh And Verify The Delivery Mirror

**Files:**
- Refresh: `D:/wp_codex/codex-oracleskills/data-archive/04_archive_package.sql`

**Interfaces:**
- Consumes: The commented package from Task 1.
- Produces: A top-level delivery mirror matching the repository package.

- [ ] **Step 1: Refresh the mirror non-destructively**

Copy the repository package to the top-level `data-archive` directory with overwrite enabled and without deleting other files.

- [ ] **Step 2: Run the mirror static contract**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File D:/wp_codex/codex-oracleskills/data-archive/tests/archive_sql_static_checks.ps1
```

Expected: `PASS: archive SQL minimal contract checks`.

- [ ] **Step 3: Compare the package hash**

Compare SHA-256 for the repository and mirrored `04_archive_package.sql`.

Expected: hashes match.

- [ ] **Step 4: Confirm final branch state**

```powershell
git status --short --branch
```

Expected: clean `feature/source-interval-retention` branch.

- [ ] **Step 5: Record the Oracle verification boundary**

Report that static verification passed and that no connected Oracle 19c instance was available for package compilation or runtime execution.
