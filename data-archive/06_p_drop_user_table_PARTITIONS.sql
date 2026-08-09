    
CREATE OR REPLACE PROCEDURE p_drop_user_table_PARTITIONS(in_table_owner varchar2,
                                                         in_table_name  varchar2,
                                                         keep_months    NUMBER)

 IS

  CURSOR partition_cursor IS
    SELECT table_owner, table_name, partition_name, high_value
      FROM all_tab_partitions
     WHERE table_owner = upper(in_table_owner)
       and table_name = upper(in_table_name);
  v_TABLE_OWNER    VARCHAR2(200);
  v_table_name     VARCHAR2(200);
  v_partition_name VARCHAR2(128);
  v_high_value     VARCHAR2(4000);
  v_high_date      DATE;
  v_cutoff_date    DATE := ADD_MONTHS(SYSDATE, -keep_months);

BEGIN

  FOR partition_rec IN partition_cursor LOOP
    v_table_owner    := partition_rec.table_owner;
    v_table_name     := partition_rec.table_name;
    v_partition_name := partition_rec.partition_name;
    v_high_value     := partition_rec.high_value;
  
    EXECUTE IMMEDIATE 'SELECT ' || v_high_value || ' FROM DUAL'
      INTO v_high_date;
  
    IF v_high_date < v_cutoff_date THEN
    
      EXECUTE IMMEDIATE 'ALTER TABLE ' || v_table_owner || '.' ||
                        v_table_name || ' DROP PARTITION ' ||
                        v_partition_name ||
                        ' UPDATE GLOBAL INDEXES PARALLEL 4';
      DBMS_OUTPUT.PUT_LINE('Dropped partition: ' || v_partition_name);
    ELSE
      DBMS_OUTPUT.PUT_LINE('Skipped partition: ' || v_partition_name ||
                           ' (HIGH_VALUE: ' || v_high_value || ')');
    END IF;
  END LOOP;
END;
/
