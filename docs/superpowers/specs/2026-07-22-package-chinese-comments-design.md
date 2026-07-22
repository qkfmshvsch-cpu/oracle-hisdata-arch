# Archive Package Chinese Comments Design

## Goal

Add concise Chinese comments to `data-archive/04_archive_package.sql` so the package is easier to study without changing its behavior.

## Comment Scope

- Replace the file header with a Chinese summary of the package purpose and execution location.
- Add a short responsibility comment before each public procedure and private function/procedure.
- Add block comments around the non-obvious logic: identifier validation, runtime WHERE validation, quoted-literal scanning, source DB Link construction, source interval detection, partition-key validation, column matching, monthly archive-table creation, cutoff calculation, filtered range lookup, and per-window commits.
- Explain design reasons where they matter, especially positional dynamic-SQL binds, `[start, end)` boundaries, source interval retention semantics, and why each batch commits independently.

## Style

- Use short `--` comments written in Chinese.
- Explain intent and constraints rather than translating every statement.
- Do not add comments to obvious assignments or repeat the procedure name in prose.
- Keep existing code formatting and Oracle 19c compatibility.

## Non-Goals

- No PL/SQL logic, API, error code, SQL text, parameter, Scheduler, example, README, or test behavior changes.
- No new helper, log, index, validation rule, or compatibility wrapper.

## Verification

- The existing archive static contract must still pass unchanged.
- `git diff` must show comment-only changes in `04_archive_package.sql`.
- The top-level `data-archive` mirror must be refreshed and its static contract must pass.
