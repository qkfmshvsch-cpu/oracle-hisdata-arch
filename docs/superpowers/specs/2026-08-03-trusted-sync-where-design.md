# 可信 sync_where 条件设计

## 目标

精简历史归档包的 `sync_where` 实现：移除 `normalize_where` 及其全部调用，使 `p_extra_where` 作为受信任 SQL 片段原样传递并追加到归档查询。

## 调用约定

- `p_extra_where` 由可信调用方提供。
- 条件必须以 `AND` 开头，并使用源表别名 `s`。
- 调用方自行保证 SQL 语法、括号、关键字、绑定变量和业务过滤条件正确。
- 包不再检查空值、长度、`AND` 前缀、别名、关键字、注释、分号、q-quoted 字面量或括号平衡，也不再重写或包裹条件。

## 实现范围

- 删除 `history_archive_pkg` 私有过程 `normalize_where`。
- 删除 `sync_where` 内的运行时条件缓冲变量和 `normalize_where` 调用。
- `sync_where` 将 `p_extra_where` 直接作为最后一个参数传递给 `run_sync`。
- 保持 `run_sync` 中原有的条件追加行为：非空时分别追加到边界查询和批次 `INSERT INTO ... SELECT ...`。
- 更新 README 和自定义调用示例，明确这是受信任输入约定。
- 精简静态检查：验证直传调用与原样追加，删除已移除校验器的断言，并拒绝 `normalize_where` 残留。

## 非目标

- 不改变 `sync`、归档表创建、分区周期判断、批次提交、清理包、Scheduler 或索引维护逻辑。
- 不新增新的 SQL 注入防护、配置表字段或额外接口。

## 验证

运行 `powershell -ExecutionPolicy Bypass -File data-archive/tests/archive_sql_static_checks.ps1`。静态检查应确认 `normalize_where` 不存在、`sync_where` 直传 `p_extra_where`，并保留 `run_sync` 对非空条件的原样追加。

Oracle 19c 编译及包含业务条件的实际归档调用仍需在数据库测试环境执行。
