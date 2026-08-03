# 生产库历史分区清理设计

## 目标

在现有 Oracle 历史数据归档脚本中完成两项独立改动：

1. 新建归档表的初始分区改为 `P_BEFORE_2026`，边界为 `DATE '2026-01-01'`。
2. 新增一个由生产库人工调用的存储过程，根据分区的 `HIGH_VALUE` 删除超出保留期的 Interval 分区。

本次不创建生产库 Scheduler Job；调用方自行调度或人工执行。

## 范围与边界

- 新增独立生产端脚本 `data-archive/06_prod_partition_cleanup_package.sql`，不修改既有归档包的同步逻辑。
- 生产端过程名称为 `history_partition_cleanup_pkg.drop_expired_partitions`。
- 调用参数保持与归档接口一致：`p_source_schema`、`p_source_table`、`p_retention_periods`。
- 支持单列 `RANGE INTERVAL` 分区表，且 Interval 表达式仅允许固定正整数形式的 `NUMTODSINTERVAL(n, 'DAY')` 或 `NUMTOYMINTERVAL(n, 'MONTH')`。
- 不处理索引维护、去重、日志表、预览模式或 Scheduler Job。

## 保留期语义

过程从 `ALL_PART_TABLES` 读取 Interval 定义并计算截止时间，与当前归档包保持一致：

- 日分区：`TRUNC(SYSDATE) - n * p_retention_periods`。
- 月分区：`ADD_MONTHS(TRUNC(SYSDATE, 'MM'), -n * p_retention_periods)`。

因此，按月 `INTERVAL (NUMTOYMINTERVAL(1, 'MONTH'))` 的表保留一年时传入 `12`；按天 `INTERVAL (NUMTODSINTERVAL(1, 'DAY'))` 的表保留一年时传入 `365`。对于 `n DAY` 或 `n MONTH`，参数表示保留的分区周期数。

## 分区删除规则

1. 校验目标表是支持的单列 `RANGE INTERVAL` 分区表。
2. 从 `ALL_TAB_PARTITIONS` 获取 `PARTITION_NAME`、`INTERVAL` 和 `HIGH_VALUE`。
3. 使用 XML 读取方式将字典中的 `HIGH_VALUE` LONG 值转换为可处理文本，并将 Oracle 数据字典生成的边界表达式计算为日期/时间边界。
4. 仅当 `INTERVAL = 'YES'` 且分区上界 `HIGH_VALUE <= 截止时间` 时，执行 `ALTER TABLE ... DROP PARTITION ...`。
5. 初始 RANGE 分区始终跳过。Oracle Interval 分区表不能删除范围段中的最后一个分区；保留它可避免 ORA-14758，并使清理过程只处理自动创建的 Interval 分区。

分区边界表示该分区存储的值严格小于 `HIGH_VALUE`。因此用 `HIGH_VALUE <= 截止时间` 判断时，不会删除仍可能包含保留期内数据的分区。

## 错误处理与运行输出

- 对空参数、无效标识符、非分区表、非 Interval 表、非单列分区键和不支持的 Interval 表达式使用 `RAISE_APPLICATION_ERROR` 终止。
- 每个将要执行的 `DROP PARTITION` 输出表名、分区名和上界；DDL 本身会隐式提交。
- 不捕获并吞掉 DDL 错误。任一删除失败立即返回 Oracle 错误，便于调用方处理。
- 过程不删除初始 RANGE 分区，也不删除 `HIGH_VALUE` 不能可靠解析的分区。

## 文件修改

- `data-archive/04_archive_package.sql`：只将建表 DDL 中的种子分区名称和边界改为 `P_BEFORE_2026` / `DATE '2026-01-01'`。
- `data-archive/06_prod_partition_cleanup_package.sql`：新增生产端清理包与人工调用示例。
- `data-archive/README.md`：补充新种子分区和生产端人工清理说明。
- `data-archive/tests/archive_sql_static_checks.ps1`：将种子分区断言改为新值，并新增清理包的静态契约检查。

本地镜像目录中已经存在的手工改动不覆盖；同步时仅复制本次明确修改或新增的文件，并先核对差异。

## 验证

1. 运行 PowerShell 静态检查，确认接口、分区边界、`HIGH_VALUE` 查询、Interval 过滤和截止时间公式存在。
2. 检查 Git 差异，确认归档包只出现种子分区的两行变更。
3. Oracle 19c 的编译和真实分区删除测试需要在具备测试表的数据库中执行；本地不具备数据库连接时不宣称已完成运行验证。
