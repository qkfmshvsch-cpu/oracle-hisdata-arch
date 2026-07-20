# Oracle 历史数据归档

这套脚本在归档数据库中创建 `history_archive_pkg`，通过只读 DB Link 从生产库复制历史数据。

## 最小契约

- 对象范围：一个配置表、一个归档包，以及按需自动创建的归档表。
- 同步模式：全量、`[start, end)` 增量、`[start, end)` 增量加额外 `WHERE` 条件。
- 目标表：按月 `INTERVAL` 分区，初始分区为 `P_BEFORE_2000`。
- 不创建索引，不做去重，不写日志（不写自定义日志），也不做复制后的二次校验。
- Scheduler 运行历史使用 Oracle 自带视图查询，不额外创建日志表。
- 重复执行会再次插入重复记录；并发执行且时间范围重叠时也会产生重复记录。
- 全量同步按 `p_retention_periods` 计算保留周期，并按 `p_batch_days` 划分时间窗口；默认每 1 天执行一条 `INSERT INTO ... SELECT ...` 并提交。
- 可选提供每个源表一个独立的 Scheduler Job 模板，默认创建后为禁用状态，便于后续按需调整再启用。

## 安装顺序

1. 在生产数据库由 DBA 执行 `00_prod_readonly_user.sql`，并仅向待归档源表授予 `SELECT`。
2. 在归档数据库由 DBA 执行 `01_archive_schema_setup.sql`。
3. 在归档数据库以 `archive_admin` 执行 `02_archive_control_tables.sql`。
4. 修改 `03_dblink_setup.sql` 的连接信息后，以 `archive_admin` 执行它。
5. 以 `archive_admin` 执行 `04_archive_package.sql`。
6. 插入归档配置并提交。
7. 先选定 Scheduler 的首个增量时间窗口起点，并将该起点作为基线切换点。
8. 在启用 Scheduler 之前，先执行一次 `history_archive_pkg.sync_full`，并设置 `p_retention_periods`，使计算出的截止日期等于上一步选定的首个增量窗口起点。
9. 以 `archive_admin` 执行 `05_archive_scheduler_job.sql`，创建默认禁用的每日任务模板。
10. 先同步测试任务窗口，再按需启用每日任务。

## 最小配置

```sql
INSERT INTO archive_table_config (
    source_schema,
    source_table,
    archive_table_name,
    date_column,
    dblink_name
) VALUES (
    'ORDERS',
    'ORDER_HEADERS',
    'ARC_ORDER_HEADERS',
    'ORDER_DATE',
    'PROD_RO_LINK'
);
COMMIT;
```

## 手工调用示例

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

BEGIN
    history_archive_pkg.sync_incremental(
        'ORDERS', 'ORDER_HEADERS', DATE '2024-01-01', DATE '2024-02-01'
    );
END;
/

BEGIN
    history_archive_pkg.sync_incremental_where(
        'ORDERS', 'ORDER_HEADERS', DATE '2024-01-01', DATE '2024-02-01',
        q'[AND s.customer_id = 1001 AND s.status = 'CLOSED']'
    );
END;
/
```

## 分区与保留周期语义

- 全量同步会通过 DB Link 读取生产库源表的分区定义，先确认是否为单列 RANGE INTERVAL 分区。
- 只支持固定正整数 `n` 形式 `NUMTODSINTERVAL(n, 'DAY')` 和 `NUMTOYMINTERVAL(n, 'MONTH')`，分别表示按天或按月的保留周期。
- `p_retention_periods` 表示保留多少个源表分区周期：例如 7 天一个分区时保留 4 个周期等于 28 天；3 个月一个分区时保留 2 个周期等于 6 个月。
- 月分区的截断时间对齐到自然月第一天，日分区的截断时间对齐到当天零点。
- 如果源表不是受支持的单列 RANGE INTERVAL 分区，全量同步在创建归档表和复制数据前就会报错。
- 归档目标表始终保持按月 `INTERVAL` 分区，不随源表分区粒度变化。

## Scheduler 任务模板

- `05_archive_scheduler_job.sql` 为 `ORDERS.ORDER_HEADERS` 创建一个标准的每日 Scheduler Job 模板。
- 该任务只调用 `history_archive_pkg.sync_incremental`，不会定时调用 `history_archive_pkg.sync_full`。
- 模板保持最小化：不创建 program、schedule、chain、job class、重试循环、自定义日志表或多表驱动器。
- 任务使用 `Asia/Shanghai` 时区，每日 `03:00` 触发，`enabled => FALSE`，`auto_drop => FALSE`。
- `c_archive_lag_days CONSTANT PLS_INTEGER := 1` 表示默认归档前天的数据：先按上海时区求当天零点，再计算 `v_end_date := v_today - c_archive_lag_days` 和 `v_start_date := v_end_date - 1`，最终归档 `[v_start_date, v_end_date)`。
- 如果要改为归档昨天的数据，可把 `c_archive_lag_days` 调整为 `0`。
- 如需覆盖更多源表，请按“每个已配置源表一个 Job”的方式复制并编辑该模板。

## Scheduler 使用与监控

启用 Scheduler 之前，必须先完成一次基线全量归档，再切换到固定的首个增量窗口。例如，在 `2026-07-17` 执行基线同步，首个 Scheduler 窗口计划为 `[2026-07-15, 2026-07-16)`，若源表按 `NUMTODSINTERVAL(1, 'DAY')` 每 1 天一个分区，则设置保留 2 个源表分区周期，使全量同步截止到 `2026-07-15`：

```sql
BEGIN
    history_archive_pkg.sync_full(
        p_source_schema      => 'ORDERS',
        p_source_table       => 'ORDER_HEADERS',
        p_retention_periods  => 2,
        p_batch_days         => 1
    );
END;
/
```

完成基线切换后，再用标准匿名 PL/SQL 块同步测试、启用和停用该任务：

```sql
BEGIN
    DBMS_SCHEDULER.RUN_JOB(
        job_name            => 'ARCHIVE_ORDER_HEADERS_DAILY_JOB',
        use_current_session => TRUE
    );
END;
/

BEGIN
    DBMS_SCHEDULER.ENABLE(
        name => 'ARCHIVE_ORDER_HEADERS_DAILY_JOB'
    );
END;
/

BEGIN
    DBMS_SCHEDULER.DISABLE(
        name => 'ARCHIVE_ORDER_HEADERS_DAILY_JOB'
    );
END;
/
```

不要在已经归档增量窗口后，再次执行截止范围重叠的全量同步，因为当前版本不做去重。

手工重跑可能重复归档同一时间窗口的数据，执行 `DBMS_SCHEDULER.RUN_JOB(` 或重新启用任务前，应先确认目标时间范围尚未归档。

可通过 Oracle 自带的 Scheduler 视图查看任务定义和运行历史：

```sql
SELECT
    job_name,
    enabled,
    state,
    repeat_interval,
    comments
FROM user_scheduler_jobs
WHERE job_name = 'ARCHIVE_ORDER_HEADERS_DAILY_JOB';

SELECT
    job_name,
    status,
    actual_start_date,
    run_duration,
    additional_info
FROM USER_SCHEDULER_JOB_RUN_DETAILS
WHERE job_name = 'ARCHIVE_ORDER_HEADERS_DAILY_JOB'
ORDER BY log_date DESC;
```

## 事务语义

- 目标表首次同步时如果不存在，包会先使用 CTAS 创建表。Oracle DDL 会隐式提交。
- 全量同步先读取符合截止条件的最小、最大归档时间，再按 `p_batch_days` 循环执行集合式 `INSERT INTO ... SELECT ...`；每个批次成功后立即提交。
- 增量同步和带额外条件的增量同步仍各执行一条 `INSERT INTO ... SELECT ...`，成功后提交。
- 全量同步每批执行前会通过 `DBMS_OUTPUT` 输出起止时间。某一批失败时，该批不会提交，但此前已经成功提交的批次会保留；可按输出的失败窗口，使用 `sync_incremental` 分段继续，避免重跑已提交的数据。
- 目标表首次创建后如果后续 INSERT 失败，CTAS 创建出的表可能因为 DDL 隐式提交而保留。
- 交付范围的禁用子串检查和行首客户端命令检查仍然会对整个交付内容保持注释敏感；而 Scheduler 语义检查会在分析前先去除 SQL 注释。

`WHERE` 参数由受信任的调用方提供，必须以 `AND` 开头，并使用源表别名 `s`。
