-- ============================================================================
-- Oracle 历史数据归档 - 生产库只读账号
-- 执行环境: 生产库，以 DBA 身份执行
-- 说明:
--   1. 归档库通过该账号 DB Link 读取生产数据。
--   2. 不授予 SELECT ANY TABLE，只授予需要归档的业务表。
-- ============================================================================


-- 按实际环境修改密码和默认表空间。
CREATE USER archive_ro IDENTIFIED BY "ChangeMe_Prod_RO_123!"
    DEFAULT TABLESPACE users
    TEMPORARY TABLESPACE temp
    ACCOUNT UNLOCK;

GRANT CREATE SESSION TO archive_ro;

-- 示例：按表授权。把下面对象改成你的生产业务表。
-- GRANT SELECT ON orders.order_headers TO archive_ro;
-- GRANT SELECT ON orders.order_lines   TO archive_ro;
-- GRANT SELECT ON finance.transactions TO archive_ro;
