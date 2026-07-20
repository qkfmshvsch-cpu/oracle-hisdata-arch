# 源表 INTERVAL 周期保留设计

## 目标

全量同步时自动读取生产库源表的 INTERVAL 分区定义。调用方只传入需要保留的分区周期数量，程序根据源表是按 N DAY 还是 N MONTH 分区计算归档截止时间。

## 公共接口

```sql
PROCEDURE sync_full(
    p_source_schema      IN VARCHAR2,
    p_source_table       IN VARCHAR2,
    p_retention_periods  IN PLS_INTEGER,
    p_batch_days         IN PLS_INTEGER DEFAULT 1
);
```

- 删除原参数 `p_retention_days`，不保留兼容接口。
- `p_retention_periods` 必须大于或等于 0，表示保留多少个源表分区周期。
- `p_batch_days` 仍表示全量复制时每个提交批次包含的天数，必须大于 0。

## 自动识别规则

程序通过配置中的 DB Link 查询生产库数据字典：

- `ALL_PART_TABLES`：源表必须是 `RANGE` 分区并且存在 INTERVAL 表达式。
- `ALL_PART_KEY_COLUMNS`：一级分区键必须只有一列，并且必须等于配置中的 `date_column`。
- INTERVAL 只接受以下固定整数形式，匹配时忽略大小写和空白：
  - `NUMTODSINTERVAL(n, 'DAY')`
  - `NUMTOYMINTERVAL(n, 'MONTH')`
- `n` 必须是大于 0 的整数。

普通 RANGE、非分区表、多列分区键、分区键不一致、季度/年度单位和复杂自定义表达式均直接报错，不做猜测或默认回退。

## 截止时间

假设解析出的 INTERVAL 数量为 `n`：

- N DAY：

```sql
TRUNC(SYSDATE) - (n * p_retention_periods)
```

- N MONTH：

```sql
ADD_MONTHS(
    TRUNC(SYSDATE, 'MM'),
    -(n * p_retention_periods)
)
```

月分区始终对齐到自然月第一天。例如当前日期是 `2026-07-20`，源表每 3 个月一个分区，`p_retention_periods => 2` 时，截止时间为 `2026-01-01 00:00:00`。

当 `p_retention_periods => 0` 时，日分区截止到当天零点，月分区截止到当月第一天。

## 执行流程

1. 读取并校验归档配置。
2. 校验 `p_retention_periods` 和 `p_batch_days`。
3. 通过 DB Link 识别源表分区单位和 INTERVAL 数量。
4. 计算全量归档截止时间。
5. 按现有逻辑创建按月 INTERVAL 分区的归档表。
6. 按 `p_batch_days` 生成时间窗口，逐批执行集合式 `INSERT INTO ... SELECT ...` 并提交。

分区识别和参数校验必须在可能执行 CTAS 的步骤之前完成，避免配置错误时先创建目标表。

## 代码约束

- 新增一个私有过程返回分区单位和 INTERVAL 数量，不新增私有函数。
- 保留现有唯一的 `clean_name` 私有函数。
- 不引入日志表、状态表、索引、去重或 DBMS_SQL。
- 增量同步和带额外 WHERE 条件的增量同步接口及行为不变。
- 归档库目标表继续按月 INTERVAL 分区，与源表日/月分区方式无关。

## 错误处理

以下情况在复制数据前通过 `RAISE_APPLICATION_ERROR` 终止：

- 保留周期为负数或批次天数不大于 0。
- 无法读取源表分区元数据。
- 源表不是 RANGE INTERVAL 分区。
- 一级分区键不是配置的归档日期列。
- INTERVAL 表达式不是受支持的固定整数 DAY/MONTH 形式。

错误信息应包含源表名称和具体原因，但不输出连接密码或完整动态 SQL。

## 验证

静态检查覆盖：

- 新接口名称及旧参数移除。
- DAY/MONTH 两种 INTERVAL 识别。
- N 与保留周期相乘后的截止时间公式。
- 非法参数和不支持分区表达式的失败路径。
- 全量逐批提交仍然存在。
- 私有函数声明仍然只有一个。
- 增量接口、月度归档目标表和不创建索引等原有契约保持不变。

实际 Oracle 环境还应分别编译并验证 1 DAY、7 DAY、1 MONTH、3 MONTH，以及非 INTERVAL 源表的报错行为。
