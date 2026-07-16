-- ============================================================================
-- Oracle historical data archive - minimal control schema
-- Run on the archive database as archive_admin.
-- ============================================================================


CREATE TABLE archive_table_config (
    config_id          NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    source_schema      VARCHAR2(128) NOT NULL,
    source_table       VARCHAR2(128) NOT NULL,
    archive_table_name VARCHAR2(128) NOT NULL,
    date_column        VARCHAR2(128) NOT NULL,
    dblink_name        VARCHAR2(128) DEFAULT 'PROD_RO_LINK' NOT NULL,
    is_active           VARCHAR2(1) DEFAULT 'Y' NOT NULL,
    created_at          TIMESTAMP WITH TIME ZONE DEFAULT SYSTIMESTAMP NOT NULL,
    updated_at          TIMESTAMP WITH TIME ZONE DEFAULT SYSTIMESTAMP NOT NULL,
    CONSTRAINT uq_archive_table_config UNIQUE (source_schema, source_table),
    CONSTRAINT ck_archive_config_active CHECK (is_active IN ('Y', 'N'))
);

COMMENT ON TABLE archive_table_config IS
    'Minimal source-to-archive table mapping.';
