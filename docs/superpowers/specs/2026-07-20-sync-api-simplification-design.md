# History Archive Sync API Simplification Design

## Goal

Reduce `history_archive_pkg` to two retention-based public procedures while preserving source-partition detection, batched commits, optional filtering, and the existing minimal delivery style.

## Public API

The package exposes only these procedures:

```sql
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
```

`sync_full`, `sync_incremental`, and `sync_incremental_where` are removed without compatibility wrappers. Callers cannot supply explicit start and end dates.

## Behavior

Both procedures read the configured production source table through its DB Link and validate that its configured date column is the single `RANGE INTERVAL` partition key. Fixed positive `NUMTODSINTERVAL(n, 'DAY')` and `NUMTOYMINTERVAL(n, 'MONTH')` intervals remain supported.

The cutoff is calculated from `p_retention_periods` using the source partition interval:

- Day interval: `TRUNC(SYSDATE) - (n * p_retention_periods)`.
- Month interval: `ADD_MONTHS(TRUNC(SYSDATE, 'MM'), -(n * p_retention_periods))`.

Rows older than the cutoff are copied in `p_batch_days` date windows. Each successful window is committed independently. The archive target table remains a monthly interval-partitioned table.

`sync_where` performs the same retention-based, batched synchronization and appends `p_extra_where` to every batch query. The condition is required, must start with `AND`, must reference source alias `s`, and keeps the existing rejection rules for unsafe SQL fragments.

Duplicate prevention is outside this package. The production source controls which rows remain eligible for repeated scheduled synchronization.

## Internal Structure

One private `run_sync` procedure contains the shared retention, partition detection, table creation, range discovery, batching, insertion, and commit flow. A nullable runtime condition is the only behavioral difference between the public procedures:

- `sync` calls `run_sync` without a condition.
- `sync_where` validates its required condition and calls the same flow with that condition.

The old mode argument, explicit start/end parameters, incremental branches, and incremental validation messages are removed. This is preferred over duplicating the synchronization loop in both public procedures because it keeps the package smaller and ensures both APIs retain identical batching behavior. A compatibility-wrapper approach is rejected because backward compatibility is not required.

## Scheduler And Examples

The daily Scheduler template remains and calls `history_archive_pkg.sync`. It declares fixed `p_retention_periods` and `p_batch_days` values instead of calculating an incremental date window. The job remains disabled after creation and continues to run daily at 03:00 in the `Asia/Shanghai` time zone when enabled.

The example file contains one call to `sync` and one call to `sync_where`. README installation, operation, Scheduler, transaction, and recovery guidance use only the two new interfaces.

## Error Handling

Existing validation remains for configuration, identifiers, source metadata, partition intervals, date columns, retention periods, batch size, and runtime conditions. Each insert batch commits only after success. If a later batch fails, earlier committed batches remain; operational recovery is to correct or remove the relevant archive rows before rerunning because explicit incremental restart APIs no longer exist.

## Verification

Static contract tests must prove that:

- Only `sync` and `sync_where` are public synchronization procedures.
- All old procedure names and incremental mode strings are absent from the delivery bundle.
- Both entry points use retention periods and day-sized batch commits.
- `sync_where` requires and appends a validated source-alias condition.
- The Scheduler calls `sync` with fixed retention and batch parameters.
- Examples and README contain no removed interface calls.

The available environment does not include a connected Oracle instance. Package compilation and execution against Oracle 19c remain deployment-time verification steps.
