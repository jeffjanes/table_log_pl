-- 
-- Glyn Astill 28/08/2015
--
-- Attempt at pl/pgsql drop-in replacement for table_log C extenstion AKA
-- pg Table Audit / PostgreSQL Table Log / tablelog by Andreas Scherbaum
--     http://www.postgresql.org/ftp/projects/pgFoundry/tablelog/tablelog/
--     http://github.com/andreasscherbaum/table_log
--
-- A slightly more up to date version of the original C extension can 
-- also be found here:
--     https://github.com/glynastill/pg_table_audit
--
-- There are now many better ways to audit DML, using json types or 
-- advanced extensions like pgaudit (below), however if for some reason 
-- you're stuck with table_log this may help.
--
--     http://8kb.co.uk/blog/2015/01/19/copying-pavel-stehules-simple-history-table-but-with-the-jsonb-type/
--     https://github.com/2ndQuadrant/pgaudit

-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION table_log_pl" to load this file. \quit

--

CREATE OR REPLACE FUNCTION table_log_pl() RETURNS TRIGGER AS
$BODY$
DECLARE
    v_tabname text;
    v_loguser boolean := false;
    v_nspname text;    
    v_num_col int;
    v_num_col_log int;
    v_col_trig text := '';
    v_val_trig text := '';    
    v_cols text := '';
    v_sql text;
    v_col_cache text;
    v_max_cache int;
    v_enable_cache boolean := true;
BEGIN
    -- Notes:
    --     - The trigger_id comes off sequence, this function is oblivious
    --     - 3 columns means don't log trigger_user or trigger_id
    --     - 4 columns means don't log trigger_user
    --     - 5 columns means log both 
    --     - To use the column data caching on server versions prior to 
    --       9.6 add custom var "table_log.column_cache = ''" to postgresql.conf

    IF (TG_NARGS > 2) THEN
        v_nspname := TG_ARGV[2];
    ELSE
        v_nspname := TG_TABLE_SCHEMA;
    END IF;
        
    IF (TG_NARGS > 1 AND TG_ARGV[1]::int = 1) THEN
        v_loguser := true;
    END IF;
    
    IF (TG_NARGS > 0) THEN
        v_tabname := TG_ARGV[0];
    ELSE
        v_tabname := TG_TABLE_NAME || '_log';
    END IF;

    -- Retrieve custom variable used as a poor mans cache for multirow statements
    IF (v_enable_cache) THEN
        IF (current_setting('server_version_num')::int >= 90600) THEN
            v_col_cache := current_setting('table_log.column_cache', true);
        ELSE
            v_col_cache := current_setting('table_log.column_cache');
        END IF;
    END IF;
    
    IF (v_enable_cache AND left(v_col_cache, length(TG_RELID::text)+1) = (TG_RELID::text || ':')) THEN      
        v_cols := right(v_col_cache, (length(TG_RELID::text)+1)*-1);
    ELSE
        IF (TG_WHEN != 'AFTER') THEN
            RAISE EXCEPTION 'table_log: must be fired after event';
        END IF;
        IF (TG_LEVEL = 'STATEMENT') THEN
            RAISE EXCEPTION 'table_log: can''t process STATEMENT events';
        END IF;    
    
        SELECT count(*), string_agg(quote_ident(attname),',') INTO STRICT v_num_col, v_cols
        FROM pg_catalog.pg_attribute
        WHERE attrelid = TG_RELID
        AND attnum > 0
        AND NOT attisdropped;       
        
        IF (v_num_col < 1) THEN
            RAISE EXCEPTION 'table_log: number of columns in table is < 1, can this happen?';
        END IF;    
            
        SELECT count(*) INTO STRICT v_num_col_log
        FROM pg_catalog.pg_attribute
        WHERE attrelid = (v_nspname || '.' || v_tabname)::regclass
        AND attnum > 0
        AND NOT attisdropped;    
        
        IF (v_num_col_log < 1) THEN
            RAISE EXCEPTION 'could not get number columns in relation %.%', v_nspname, v_tabname;
        END IF;

        -- This is the way the original checks column count regardless of trigger_id is presence
        IF (v_num_col_log != (v_num_col + 3 + v_loguser::int)) AND (v_num_col_log != (v_num_col + 4 + v_loguser::int)) THEN
            RAISE EXCEPTION 'number colums in relation %.%(%) does not match columns in %.%(%)', TG_TABLE_SCHEMA, TG_TABLE_NAME, v_num_col, v_nspname, v_tabname, v_num_col_log;
        END IF;
        
        -- Set custom variable for use as a poor mans cache for multirow statements
        IF (v_enable_cache) THEN
            v_col_cache := (TG_RELID::text || ':' || v_cols);
            PERFORM set_config('table_log.column_cache', v_col_cache, true);
        END IF;
    END IF;

    IF (v_loguser) THEN
        v_col_trig := v_col_trig || ', "trigger_user"';
        v_val_trig := format('%L, ', session_user);
    END IF;
    v_col_trig := v_col_trig || ', "trigger_mode", "trigger_changed", "trigger_tuple"';
    v_val_trig := format('%s%L, %L', v_val_trig, TG_OP, current_timestamp);    

    IF (TG_OP != 'INSERT') THEN
        v_sql := format('INSERT INTO %I.%I (%s%s) SELECT %s, %s, ''old'' FROM (SELECT ($1::text::%I).*) t', v_nspname, v_tabname, v_cols, v_col_trig, v_cols, v_val_trig, TG_RELID::regclass);
        EXECUTE v_sql  USING OLD;
    END IF;
    IF (TG_OP != 'DELETE') THEN
        v_sql := format('INSERT INTO %I.%I (%s%s) SELECT %s, %s, ''new'' FROM (SELECT ($1::text::%I).*) t', v_nspname, v_tabname, v_cols, v_col_trig, v_cols, v_val_trig, TG_RELID::regclass);
        EXECUTE v_sql  USING NEW;
        RETURN NEW;
    ELSE 
        RETURN OLD;
    END IF;

END;
$BODY$
LANGUAGE plpgsql VOLATILE;

--

CREATE OR REPLACE FUNCTION table_log_pl_restore_table (origtab varchar, origtab_pk varchar, logtab char, logtab_pk char, restoretab char, to_timestamp timestamptz, search_pk char DEFAULT NULL, method int DEFAULT 0, not_temporarly int DEFAULT 0, origtab_schema varchar DEFAULT NULL, logtab_schema varchar DEFAULT NULL) RETURNS varchar AS
$BODY$
DECLARE
    v_origtab_cols int;
    v_logtab_cols int;
    v_restoretab_cols int;
    v_origtab_fqn text;
    v_logtab_fqn text;
    v_sql text;
    v_cols text;
    v_pk_count int;
    v_rec record;
    v_old_pk_str text;
BEGIN

    -- Notes:
    --
    -- The original implimentation doesn't allow fully qualified table 
    -- references in table_log_restore_table;  You can get some milage 
    -- out of search_path if required there. For this reason the plpgsql
    -- version adds the following two optional parameters to those below:
    --
    --   - original table schema
    --   - logging table schema
    --
    -- Comments from C implimentation:
    --
    -- restore a complete table based on the logging table
    --
    -- parameter:   
    --   - original table name
    --   - name of primary key in original table
    --   - logging table
    --   - name of primary key in logging table
    --   - restore table name
    --   - timestamp for restoring data
    --   - primary key to restore (only this key will be restored) (optional)
    --   - restore mode
    --     0: restore from blank table (default)
    --        needs a complete logging table
    --     1: restore from actual table backwards
    --   - dont create table temporarly
    --     0: create restore table temporarly (default)
    --     1: create restore table not temporarly
    --   return:
    --     not yet defined

    IF origtab IS NULL THEN
        RAISE NOTICE 'table_log_restore_table: missing original table name';
    END IF;
    IF origtab_pk IS NULL THEN
        RAISE NOTICE 'table_log_restore_table: missing primary key name for original table';
    END IF;
    IF logtab IS NULL THEN
        RAISE NOTICE 'table_log_restore_table: missing log table name';
    END IF;
    IF logtab_pk IS NULL THEN
        RAISE NOTICE 'table_log_restore_table: missing primary key name for log table';
    END IF;
    IF restoretab IS NULL THEN
        RAISE NOTICE 'table_log_restore_table: missing copy table name';
    END IF;
    IF to_timestamp IS NULL THEN
        RAISE NOTICE 'table_log_restore_table: missing timestamp';
    END IF;
    IF (search_pk IS NOT NULL) THEN
        RAISE NOTICE 'table_log_restore_table: will restore a single key';
    END IF;
    
    IF origtab_pk = logtab_pk THEN 
        RAISE EXCEPTION 'pkey of logging table cannot be the pkey of the original table: % <-> %', origtab_pk, logtab_pk;
    END IF;
    
    v_origtab_fqn := coalesce(quote_ident(origtab_schema) || '.','') || quote_ident(origtab);
    v_logtab_fqn := coalesce(quote_ident(logtab_schema) || '.','') || quote_ident(logtab);
    
    -- Check original table and get column list
    SELECT string_agg(quote_ident(attname), ','), count(*), count(*) filter (where attname=origtab_pk)
    INTO v_cols, v_origtab_cols, v_pk_count
    FROM pg_catalog.pg_class c 
    JOIN pg_catalog.pg_attribute a ON a.attrelid = c.oid
    JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
    WHERE c.relname = origtab AND c.relkind='r' AND a.attnum > 0 
    AND (origtab_schema IS NULL OR n.nspname = origtab_schema)
    AND NOT attisdropped;
                
    IF v_origtab_cols = 0 OR v_cols IS NULL THEN
        RAISE EXCEPTION 'could not check relation: % (columns = %)', v_origtab_fqn, v_origtab_cols;
    ELSIF v_pk_count != 1 THEN
        RAISE EXCEPTION 'could not check relation: (missing pkey) % in table %', origtab_pk, v_origtab_fqn;
    ELSE
        RAISE NOTICE 'original table: OK (% columns)', v_origtab_cols;
    END IF;
        
    -- Check log table    
    SELECT count(*), count(*) filter (where attname=logtab_pk) 
    INTO v_logtab_cols, v_pk_count
    FROM pg_catalog.pg_class c 
    JOIN pg_catalog.pg_attribute a ON a.attrelid = c.oid
    JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
    WHERE c.relname = logtab AND c.relkind='r' AND a.attnum > 0
    AND (logtab_schema IS NULL OR n.nspname = logtab_schema)
    AND NOT attisdropped;   
    
    IF v_logtab_cols = 0 THEN
        RAISE EXCEPTION 'could not check relation: % (columns = %)', v_logtab_fqn, v_logtab_cols;
    ELSIF v_pk_count != 1 THEN
        RAISE EXCEPTION 'could not check relation: (missing pkey) % in table %', logtab_pk, v_logtab_fqn;
    ELSE
        RAISE NOTICE 'log table: OK (% columns)', v_logtab_cols;
    END IF;
       
    -- Check restore table
    IF EXISTS(SELECT 1 FROM pg_catalog.pg_class
              WHERE relname=restoretab AND relkind='r') THEN
        RAISE EXCEPTION 'restore table already exists: %', restoretab;
    ELSE
        RAISE NOTICE 'restore table: OK (doesnt exists)';
    END IF;
    
    -- create restore table 
    v_sql := 'CREATE';
    IF not_temporarly = 0 THEN
        v_sql := v_sql || ' TEMPORARY';
    END IF;    
    v_sql := v_sql || format(' TABLE %I AS SELECT * FROM %s', restoretab, v_origtab_fqn);    
    IF search_pk IS NOT NULL THEN
        v_sql := v_sql || format(' WHERE %I = %L', origtab_pk, search_pk);
    END IF;     
    IF method = 0 THEN
        RAISE NOTICE 'need logs from start to timestamp: %', to_timestamp;
        v_sql := v_sql || ' LIMIT 0'; -- Create blank table to roll forward into (need all logs)
    ELSE
        RAISE NOTICE 'need logs from end to timestamp: %', to_timestamp;
    END IF;
    
    -- RAISE NOTICE 'DDL: %', v_sql;
    EXECUTE v_sql;
  
    -- now build query for getting logs
    v_sql := format('SELECT * FROM %s WHERE ', v_logtab_fqn);
    IF method = 0 THEN
        v_sql := v_sql || format('trigger_changed <= %L', to_timestamp); -- ROLL FORWARD
    ELSE
        v_sql := v_sql || format('trigger_changed >= %L', to_timestamp); -- ROLL BACK
    END IF;
    
    IF search_pk IS NOT NULL THEN
        v_sql := v_sql || format(' AND %I = %L', origtab_pk, search_pk);
    END IF;
    
    IF method = 0 THEN 
        v_sql := v_sql || format(' ORDER BY %I ASC', logtab_pk);
    ELSE
        v_sql := v_sql || format(' ORDER BY %I DESC', logtab_pk);
    END IF;
    
    -- RAISE NOTICE 'SQL: %', v_sql;
    
    FOR v_rec IN EXECUTE v_sql 
    LOOP        
        IF v_rec.trigger_mode = 'UPDATE' AND ((method = 0 AND v_rec.trigger_tuple = 'old') OR (method = 1 AND v_rec.trigger_tuple = 'new')) THEN
            -- For previous update row versions we needn't apply anything; 
            -- we just note the pk value for the quals when applying the 
            -- next row change, i.e when rolling forward the old pk value, 
            -- when rolling back the new pk value
            EXECUTE format('SELECT ($1::text::%s).%I', v_logtab_fqn, origtab_pk) INTO v_old_pk_str USING v_rec;
        ELSE
            -- Apply the row changes from the log table, the following is
            -- a mass of substitutions, but essentially we're selecting 
            -- data out of the log table record and casting it into the 
            -- restore table.

            IF v_rec.trigger_mode = 'UPDATE' THEN 
                v_sql := format('UPDATE %I SET (%s) = (SELECT %s FROM (SELECT ($1::text::%s).*) t) WHERE %I = %L',
                                restoretab, v_cols, v_cols, v_logtab_fqn, origtab_pk, v_old_pk_str);                
            ELSIF (v_rec.trigger_mode = 'INSERT' AND method = 0) OR (v_rec.trigger_mode = 'DELETE' AND method != 0) THEN            
                v_sql := format('INSERT INTO %I (%s) SELECT %s FROM (SELECT ($1::text::%s).*) t', 
                                restoretab, v_cols, v_cols, v_logtab_fqn);
            ELSIF (v_rec.trigger_mode = 'INSERT' AND method != 0) OR (v_rec.trigger_mode = 'DELETE' AND method = 0) THEN
                v_sql := format('DELETE FROM %I WHERE %I = ($1::text::%s).%I', 
                                restoretab, origtab_pk, v_logtab_fqn, origtab_pk);
            ELSE 
                RAISE EXCEPTION 'unknown trigger_mode: %', trigger_mode;
            END IF;            
            
            -- RAISE NOTICE 'DML: %', v_sql;
            EXECUTE v_sql USING v_rec;            
        END IF;

    END LOOP;

    RETURN quote_ident(restoretab);
END;
$BODY$
LANGUAGE plpgsql VOLATILE;

--

CREATE OR REPLACE FUNCTION table_log_pl_init(level int, orig_schema text, orig_name text, log_schema text, log_name text) 
RETURNS void AS 
$BODY$
DECLARE
    do_log_user  int = 0;
    level_create text = E'''';
    orig_qq      text;
    log_qq       text;
BEGIN
    -- Quoted qualified names
    orig_qq := quote_ident(orig_schema)||'.'||quote_ident(orig_name);
    log_qq := quote_ident(log_schema)||'.'||quote_ident(log_name);

    IF level <> 3 THEN
        level_create := level_create
            ||', trigger_id BIGSERIAL NOT NULL PRIMARY KEY';
        IF level <> 4 THEN
            level_create := level_create
                ||', trigger_user VARCHAR(32) NOT NULL';
            do_log_user := 1;
            IF level <> 5 THEN
                RAISE EXCEPTION 
                    'table_log_pl_init: First arg has to be 3, 4 or 5.';
            END IF;
        END IF;
    END IF;
    
    EXECUTE 'CREATE TABLE '||log_qq
          ||'(LIKE '||orig_qq
          ||', trigger_mode VARCHAR(10) NOT NULL'
          ||', trigger_tuple VARCHAR(5) NOT NULL'
          ||', trigger_changed TIMESTAMPTZ NOT NULL'
          ||level_create
          ||')';
            
    EXECUTE 'CREATE TRIGGER "table_log_trigger_pl" AFTER UPDATE OR INSERT OR DELETE ON '
          ||orig_qq||' FOR EACH ROW EXECUTE PROCEDURE table_log_pl('
          ||quote_literal(log_name)||','
          ||do_log_user||','
          ||quote_literal(log_schema)||')';

    RETURN;
END;
$BODY$
LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION table_log_pl_init(level int, orig_name text) 
RETURNS void AS 

$BODY$
BEGIN
    PERFORM table_log_pl_init(level, orig_name, current_schema());
    RETURN;
END;
$BODY$
LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION table_log_pl_init(level int, orig_name text, log_schema text) 
RETURNS void AS 
$BODY$
BEGIN
    PERFORM table_log_pl_init(level, current_schema(), orig_name, log_schema);
    RETURN;
END;
$BODY$
LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION table_log_pl_init(level int, orig_schema text, orig_name text, log_schema text) 
RETURNS void AS 
$BODY$
BEGIN
    PERFORM table_log_pl_init(level, orig_schema, orig_name, log_schema,
        CASE WHEN orig_schema=log_schema 
            THEN orig_name||'_log' ELSE orig_name END);
    RETURN;
END;
$BODY$
LANGUAGE plpgsql;
