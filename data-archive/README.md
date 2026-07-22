# Oracle 历史数据归档

这套脚本在归档数据库中创建 `history_archive_pkg`，通过只读 DB Link 从生产库复制历史数据。

## 最小契约

- 对象范围：一个配置表、一个归档包，以及按需自动创建的归档表。
- 同步方式：`sync` 和带额外 `WHERE` 条件的 `sync_where`；两者都按保留周期计算归档范围，并按批次复制。
- 目标表：按月 `INTERVAL` 分区，初始分区为 `P_BEFORE_2000`。
- 不创建索引，不做去重，不写日志（不写自定义日志），也不做复制后的二次校验。
- Scheduler 运行历史使用 Oracle 自带视图查询，不额外创建日志表。
- 重复执行会再次插入重复记录；重复资格由源端数据控制。
- `sync` 和 `sync_where` 都按 `p_retention_periods` 计算保留周期，并按 `p_batch_days` 划分时间窗口；默认每 1 天执行一条 `INSERT INTO ... SELECT ...` 并提交。
- 可选提供每个源表一个独立的 Scheduler Job 模板，默认创建后为禁用状态，便于后续按需调整再启用。

## 安装顺序

1. 在生产数据库由 DBA 执行 `00_prod_readonly_user.sql`，并仅向待归档源表授予 `SELECT`。
2. 在归档数据库由 DBA 执行 `01_archive_schema_setup.sql`。
3. 在归档数据库以 `archive_admin` 执行 `02_archive_control_tables.sql`。
4. 修改 `03_dblink_setup.sql` 的连接信息后，以 `archive_admin` 执行它。
5. 以 `archive_admin` 执行 `04_archive_package.sql`。
6. 插入归档配置并提交。
7. 使用下方的 `sync` 或 `sync_where` 手工归档所需数据。
8. 以 `archive_admin` 执行 `05_archive_scheduler_job.sql`，创建默认禁用的每日任务模板。
9. 先运行测试任务，再按需启用每日任务。

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

## 分区与保留周期语义

- 两种同步调用都会通过 DB Link 读取生产库源表的分区定义，先确认是否为单列 RANGE INTERVAL 分区。
- 只支持固定正整数 `n` 形式 `NUMTODSINTERVAL(n, 'DAY')` 和 `NUMTOYMINTERVAL(n, 'MONTH')`，分别表示按天或按月的保留周期。
- `p_retention_periods` 表示保留多少个源表分区周期：例如 7 天一个分区时保留 4 个周期等于 28 天；3 个月一个分区时保留 2 个周期等于 6 个月。
- 月分区的截断时间对齐到自然月第一天，日分区的截断时间对齐到当天零点。
- 如果源表不是受支持的单列 RANGE INTERVAL 分区，两种同步调用在创建归档表和复制数据前就会报错。
- 归档目标表始终保持按月 `INTERVAL` 分区，不随源表分区粒度变化。

## Scheduler 任务模板

- `05_archive_scheduler_job.sql` 为 `ORDERS.ORDER_HEADERS` 创建一个标准的每日 Scheduler Job 模板。
- Scheduler 每日调用 `sync`，并使用固定的保留周期和批次设置。
- 模板保持最小化：不创建 program、schedule、chain、job class、重试循环、自定义日志表或多表驱动器。
- 任务使用 `Asia/Shanghai` 时区，每日 `03:00` 触发，`enabled => FALSE`，`auto_drop => FALSE`。
- 如需覆盖更多源表，请按“每个已配置源表一个 Job”的方式复制并编辑该模板。

## Scheduler 使用与监控

Scheduler 会在每日 03:00 以固定的保留周期和批次设置调用 `sync`。用标准匿名 PL/SQL 块运行测试、启用和停用该任务：

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

包不会去重；是否允许重复归档由源端数据控制。手工调用和 Scheduler 重跑前，应确认源端数据的重复资格符合预期。

每个批次成功后都会提交。较晚的批次失败时，此前成功提交的批次会保留；重跑前必须先修正或删除相关目标表记录，再重新执行对应的 `sync` 或 `sync_where` 调用。

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
- `sync` 和 `sync_where` 先读取符合保留周期条件的最小、最大归档时间，再按 `p_batch_days` 循环执行集合式 `INSERT INTO ... SELECT ...`；每个批次成功后立即提交。
- 两种调用每批执行前都会通过 `DBMS_OUTPUT` 输出起止时间。某一批失败时，该批不会提交，但此前已经成功提交的批次会保留；重跑前必须先修正或删除相关目标表记录。
- 目标表首次创建后如果后续 INSERT 失败，CTAS 创建出的表可能因为 DDL 隐式提交而保留。

`sync_where` 的 `p_extra_where` 由受信任的调用方提供，必须以 `AND` 开头并使用源表别名 `s`。长度不得超过 4,000 字节；拒绝绑定标记（`:`）、分隔符（`;`）、注释（`--`、`/*`、`*/`）、控制字符、DML/DDL、事务、PL/SQL 和查询整形关键字（`SELECT`、`UNION`、`INTERSECT`、`MINUS`、`WITH`）。运行时值不支持 Oracle q-quoted 字面量语法；这不影响调用方使用 PL/SQL q-quoting 构造参数，包接收到的是其中的内容。
