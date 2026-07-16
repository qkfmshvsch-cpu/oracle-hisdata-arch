-- ============================================================================
-- Oracle 历史数据归档 - 归档库到生产库 DB Link
-- 执行环境: 归档库，以 archive_admin 执行
-- ============================================================================


-- 按实际环境修改连接串和密码。
-- Easy Connect 示例：
CREATE DATABASE LINK prod_ro_link
    CONNECT TO archive_ro IDENTIFIED BY "ChangeMe_Prod_RO_123!"
    USING '//prod-db-host.example.com:1521/PRODPDB';

-- TNS 示例：
-- CREATE DATABASE LINK prod_ro_link
--     CONNECT TO archive_ro IDENTIFIED BY "ChangeMe_Prod_RO_123!"
--     USING 'PRODDB_TNS';

SELECT 'DBLINK_OK' AS status FROM dual@prod_ro_link;
