# Configured Retention, Row-Cursor Batching, And Deduplication Design

## Goal

Keep the archive program small while moving retention settings into `archive_table_config`, committing large archive runs in configurable row batches, and preventing duplicate copies based on the production table's primary key or unique key.

## Configuration

`archive_table_config` gains two required retention columns:

```sql
keep_interval_unit   VARCHAR2(10) NOT NULL
keep_interval_count  NUMBER(10)   NOT NULL
```

`keep_interval_unit` accepts only `DAY` and `MONTH`. `keep_interval_count` must be a positive integer. Examples are `DAY + 365` for 365 days and `MONTH + 12` for twelve calendar months. A year is intentionally represented as `MONTH + 12`; `YEAR` is not an accepted value.

The package reads these values from the active configuration row. It continues to inspect the source table through the configured database link, confirms a single `RANGE INTERVAL` partition key, and rejects a configuration whose retention unit differs from the source interval unit. The source's positive interval multiplier remains supported, such as `NUMTOYMINTERVAL(3, 'MONTH')`.

The cutoff is calculated from the configuration, rather than from a public parameter:

- `DAY`: `TRUNC(SYSDATE) - keep_interval_count`.
- `MONTH`: `ADD_MONTHS(TRUNC(SYSDATE, 'MM'), -keep_interval_count)`.

## Public API

The two public procedures become:

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

`p_retention_periods` and date-window batch parameters are removed. `p_batch_rows` must be positive. `sync_where` keeps the existing validation requirements: it must begin with `AND`, reference source alias `s`, and cannot contain comments, delimiters, unsafe SQL tokens, unbalanced parentheses, or runtime q-quoted literals.

## Data Flow

1. Read the active table configuration, validate identifiers, retention values, source partition metadata, and the configured date column.
2. Create the monthly interval-partitioned archive table if it does not exist, then read the source column list in source order.
3. Read the source primary key through the DB Link. If no primary key exists, read one unique key in deterministic constraint-name order. If neither exists, stop before copying any row.
4. Open a `DBMS_SQL` cursor for source rows older than the calculated cutoff and matching the optional validated filter. The cursor drives the archive in source-row order and preserves the source column data types when binding rows to the insert statement.
5. For each fetched row, test the selected key against the local archive table using null-safe comparisons for a fallback unique key. Insert only when no matching archive row exists.
6. Commit after every `p_batch_rows` successfully processed source rows. Commit a final partial batch. Earlier committed batches remain committed if a later batch fails.

This is a row-driven cursor by explicit user choice. It avoids a single large `INSERT ... SELECT` transaction and makes commit size independent of date distribution. It has higher per-row PL/SQL overhead than the previous date-window set-based insert, so `10000` is the recommended starting batch size and should be adjusted only after production testing.

## Deduplication Scope

Primary keys are preferred. A unique key is used only when the source has no primary key. The archive package does not create index DDL because the delivery must remain minimal and prior scope explicitly removed index management. For large repeated runs, the DBA should independently evaluate a matching archive-side index; without one, local key-existence checks can become progressively expensive.

The package performs no source cleanup and does not make any claim that deduplication replaces the production-side archive-and-cleanup process.

## Scheduler, Examples, And Documentation

The daily Scheduler job calls `sync` with `p_source_schema`, `p_source_table`, and optional `p_batch_rows` only. Retention is documented as a configuration-table responsibility. Examples and README show `DAY` and `MONTH` retention settings, both public APIs, the source-key prerequisite, cursor batch commits, duplicate behavior, and operational recovery after a partial run.

## Errors And Recovery

The package raises an application error for inactive or missing configuration, invalid retention unit or count, a source/configuration interval mismatch, unsupported source partition metadata, missing primary/unique keys, invalid batch rows, or an invalid custom filter.

If a run fails after one or more commits, rerunning is safe with respect to duplicate rows because each row is checked against the archive key before insertion. The failure cause must still be corrected before rerun; this package does not provide automatic retry state or cleanup.

## Verification

Static checks will confirm the new configuration columns and constraints, public signatures without retention-period parameters, `DBMS_SQL` cursor and row-batch commit behavior, source key discovery with the required failure path, duplicate predicate generation, Scheduler and example updates, and removal of obsolete date-window wording.

No connected Oracle environment is available here. Oracle 19c compilation plus tests covering primary-key tables, nullable unique-key tables, no-key failure, no qualifying rows, multiple commits, and partial-run rerun remain deployment-time verification.
