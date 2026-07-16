-- ============================================================================
-- Oracle 历史数据归档 - 归档库 Schema 初始化
-- 执行环境: 归档库，以 DBA 身份执行
-- ============================================================================


CREATE TABLESPACE archive_data
    DATAFILE SIZE 10G AUTOEXTEND ON NEXT 1G MAXSIZE 500G
    EXTENT MANAGEMENT LOCAL AUTOALLOCATE
    SEGMENT SPACE MANAGEMENT AUTO;

CREATE USER archive_admin IDENTIFIED BY "ChangeMe_Archive_123!"
    DEFAULT TABLESPACE archive_data
    TEMPORARY TABLESPACE temp
    QUOTA UNLIMITED ON archive_data
    ACCOUNT UNLOCK;

GRANT CREATE SESSION TO archive_admin;
GRANT CREATE TABLE TO archive_admin;
GRANT CREATE PROCEDURE TO archive_admin;
GRANT CREATE DATABASE LINK TO archive_admin;
GRANT CREATE JOB TO archive_admin;
