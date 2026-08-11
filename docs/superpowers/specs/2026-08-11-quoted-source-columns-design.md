# 关键字源列归档设计

## 目标

使 Oracle 历史归档包支持源表中的关键字列和双引号创建的大小写敏感列，例如 `"ORDER"`、`"DATE"` 和 `"OrderDate"`。

## 设计

- 保持 `clean_name` 仅用于 Schema、表、DB Link 和归档表等对象名。
- 新增私有 `quote_column_name`，通过 `DBMS_ASSERT.ENQUOTE_NAME(..., FALSE)` 校验并生成双引号列标识符。
- 所有动态 SQL 中的列引用均使用 `quote_column_name`：CTAS 分区键、INSERT 列表、`s.` 选择列表、MIN/MAX 和时间窗口条件。
- `archive_table_config.date_column` 必须保存源数据库字典中的精确列名。普通列配置为 `CREATE_TIME`；双引号混合大小写列 `"OrderDate"` 配置为 `OrderDate`。
- 继续将 `p_extra_where` 视为受信任 SQL。若条件使用关键字列，调用方自行写 `AND s."ORDER" = 'CLOSED'`。

## 非目标

- 不改变 Schema、表或 DB Link 的标识符处理。
- 不改变同步接口、分区检测、批次提交、Scheduler 或生产端删分区过程。

## 验证

- 静态检查要求 `quote_column_name` 和 `DBMS_ASSERT.ENQUOTE_NAME` 存在。
- 静态检查要求列列表、分区键和时间条件使用带双引号的列变量。
- README 和示例说明精确 `date_column` 配置及可信 WHERE 条件的双引号用法。
- Oracle 19c 编译和包含关键字列的实表归档仍需在测试库验证。
