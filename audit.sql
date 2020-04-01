-- An audit history is important on most tables. Provide an audit trigger that logs to
-- a dedicated audit table for the major relations.
--
-- This file should be generic and not depend on application roles or structures,
-- as it's being listed here:
--
--    https://wiki.postgresql.org/wiki/Audit_trigger_91plus    
--
-- This trigger was originally based on
--   http://wiki.postgresql.org/wiki/Audit_trigger
-- but has been completely rewritten.
--
-- Should really be converted into a relocatable EXTENSION, with control and upgrade files.

CREATE EXTENSION IF NOT EXISTS hstore;

CREATE SCHEMA audit;
REVOKE ALL ON SCHEMA audit FROM public;

COMMENT ON SCHEMA audit IS 'Out-of-table audit/history logging tables and trigger functions';

--
-- Audited data. Lots of information is available, it's just a matter of how much
-- you really want to record. See:
--
--   http://www.postgresql.org/docs/9.1/static/functions-info.html
--
-- Remember, every column you add takes up more audit table space and slows audit
-- inserts.
--
-- Every index you add has a big impact too, so avoid adding indexes to the
-- audit table unless you REALLY need them. The hstore GIST indexes are
-- particularly expensive.
--
-- It is sometimes worth copying the audit table, or a coarse subset of it that
-- you're interested in, into a temporary table where you CREATE any useful
-- indexes and do your analysis.
--
CREATE TABLE audit.logged_actions (
    event_id bigserial primary key,
    schema_name text not null,
    table_name text not null,
    referenced_table_name text,
    code_value text not null,
    relid oid not null,
    session_user_name text,
    action_tstamp_tx TIMESTAMP WITH TIME ZONE NOT NULL,
    action_tstamp_stm TIMESTAMP WITH TIME ZONE NOT NULL,
    action_tstamp_clk TIMESTAMP WITH TIME ZONE NOT NULL,
    transaction_id bigint,
    application_name text,
    client_addr inet,
    client_port integer,
    client_query text,
    action TEXT NOT NULL CHECK (action IN ('I','D','U', 'T')),
    row_data hstore,
    changed_fields hstore,
    statement_only boolean not null
);

REVOKE ALL ON audit.logged_actions FROM public;

COMMENT ON TABLE audit.logged_actions IS 'History of auditable actions on audited tables, from audit.if_modified_func()';
COMMENT ON COLUMN audit.logged_actions.event_id IS 'Unique identifier for each auditable event';
COMMENT ON COLUMN audit.logged_actions.schema_name IS 'Database schema audited table for this event is in';
COMMENT ON COLUMN audit.logged_actions.table_name IS 'Non-schema-qualified table name of table event occured in';
COMMENT ON COLUMN audit.logged_actions.referenced_table_name IS 'Non-schema-qualified table name of table of primary entity';
COMMENT ON COLUMN audit.logged_actions.code_value IS 'Value present in table''s column represented by audit_metadata''s code_column';
COMMENT ON COLUMN audit.logged_actions.relid IS 'Table OID. Changes with drop/create. Get with ''tablename''::regclass';
COMMENT ON COLUMN audit.logged_actions.session_user_name IS 'Login / session user whose statement caused the audited event';
COMMENT ON COLUMN audit.logged_actions.action_tstamp_tx IS 'Transaction start timestamp for tx in which audited event occurred';
COMMENT ON COLUMN audit.logged_actions.action_tstamp_stm IS 'Statement start timestamp for tx in which audited event occurred';
COMMENT ON COLUMN audit.logged_actions.action_tstamp_clk IS 'Wall clock time at which audited event''s trigger call occurred';
COMMENT ON COLUMN audit.logged_actions.transaction_id IS 'Identifier of transaction that made the change. May wrap, but unique paired with action_tstamp_tx.';
COMMENT ON COLUMN audit.logged_actions.client_addr IS 'IP address of client that issued query. Null for unix domain socket.';
COMMENT ON COLUMN audit.logged_actions.client_port IS 'Remote peer IP port address of client that issued query. Undefined for unix socket.';
COMMENT ON COLUMN audit.logged_actions.client_query IS 'Top-level query that caused this auditable event. May be more than one statement.';
COMMENT ON COLUMN audit.logged_actions.application_name IS 'Application name set when this audit event occurred. Can be changed in-session by client.';
COMMENT ON COLUMN audit.logged_actions.action IS 'Action type; I = insert, D = delete, U = update, T = truncate';
COMMENT ON COLUMN audit.logged_actions.row_data IS 'Record value. Null for statement-level trigger. For INSERT this is the new tuple. For DELETE and UPDATE it is the old tuple.';
COMMENT ON COLUMN audit.logged_actions.changed_fields IS 'New values of fields changed by UPDATE. Null except for row-level UPDATE events.';
COMMENT ON COLUMN audit.logged_actions.statement_only IS '''t'' if audit event is from an FOR EACH STATEMENT trigger, ''f'' for FOR EACH ROW';

CREATE INDEX logged_actions_relid_idx ON audit.logged_actions(relid);
CREATE INDEX logged_actions_action_tstamp_tx_stm_idx ON audit.logged_actions(action_tstamp_stm);
CREATE INDEX logged_actions_action_idx ON audit.logged_actions(action);

CREATE TABLE audit.audit_metadata (
    id serial primary key,
    schema_name text not null,
    table_name text not null,
    code_column text
);

COMMENT ON TABLE audit.audit_metadata IS 'Metadata of audited tables to help retrieving and presenting data';
COMMENT ON COLUMN audit.audit_metadata.id IS 'Unique identifier for audited table';
COMMENT ON COLUMN audit.audit_metadata.schema_name IS 'Schema the audited table for this event is in';
COMMENT ON COLUMN audit.audit_metadata.table_name IS 'Non-schema-qualified table name of table which event occurred in';
COMMENT ON COLUMN audit.audit_metadata.code_column IS 'Column that represents an end-user-meaningful identifier for audited entity; NULL for weak entities';

CREATE TABLE audit.audit_reference (
    table_id int not null references audit.audit_metadata (id) ON UPDATE CASCADE ON DELETE CASCADE,
    referenced_table_id int not null references audit.audit_metadata (id) ON UPDATE CASCADE ON DELETE CASCADE,
    relation_column text not null,
    relation_direction text not null check (relation_direction IN ('DIRECT', 'INVERSE')),
    primary key (table_id, referenced_table_id)
);

COMMENT ON TABLE audit.audit_reference IS 'Relationship between audited tables of weak entities and audited tables of stronger entities';
COMMENT ON COLUMN audit.audit_reference.table_id IS 'Identifier of weak entities on audit_metadata';
COMMENT ON COLUMN audit.audit_reference.referenced_table_id IS 'Identifier of stronger entities on audit_metadata';
COMMENT ON COLUMN audit.audit_reference.relation_column IS 'Column of referencing table of relationship';
COMMENT ON COLUMN audit.audit_reference.relation_direction IS 'Relationship direction from weak table''s viewpoint';

CREATE OR REPLACE FUNCTION audit.if_modified_func() RETURNS TRIGGER AS $body$
DECLARE
    audit_row audit.logged_actions;
    include_values boolean;
    log_diffs boolean;
    h_old hstore;
    h_new hstore;
    excluded_cols text[] = ARRAY[]::text[];
    table_id int;
    code_value text;
BEGIN
    IF TG_WHEN <> 'AFTER' THEN
        RAISE EXCEPTION 'audit.if_modified_func() may only run as an AFTER trigger';
    END IF;

    audit_row = ROW(
        NULL,                                         -- event_id
        TG_TABLE_SCHEMA::text,                        -- schema_name
        TG_TABLE_NAME::text,                          -- table_name
        NULL,                                         -- referenced_table_name  
        NULL,                                         -- code_value  
        TG_RELID,                                     -- relation OID for much quicker searches
        session_user::text,                           -- session_user_name
        current_timestamp,                            -- action_tstamp_tx
        statement_timestamp(),                        -- action_tstamp_stm
        clock_timestamp(),                            -- action_tstamp_clk
        txid_current(),                               -- transaction ID
        current_setting('application_name'),          -- client application
        inet_client_addr(),                           -- client_addr
        inet_client_port(),                           -- client_port
        current_query(),                              -- top-level query or queries (if multistatement) from client
        substring(TG_OP,1,1),                         -- action
        NULL, NULL,                                   -- row_data, changed_fields
        'f'                                           -- statement_only
        );

    IF NOT TG_ARGV[0]::boolean IS DISTINCT FROM 'f'::boolean THEN
        audit_row.client_query = NULL;
    END IF;

    IF TG_ARGV[1] IS NOT NULL THEN
        excluded_cols = TG_ARGV[1]::text[];
    END IF;
    
    IF (TG_OP = 'UPDATE' AND TG_LEVEL = 'ROW') THEN
        audit_row.row_data = hstore(OLD.*) - excluded_cols;
        audit_row.changed_fields =  (hstore(NEW.*) - audit_row.row_data) - excluded_cols;
        IF audit_row.changed_fields = hstore('') THEN
            -- All changed fields are ignored. Skip this update.
            RETURN NULL;
        END IF;
    ELSIF (TG_OP = 'DELETE' AND TG_LEVEL = 'ROW') THEN
        audit_row.row_data = hstore(OLD.*) - excluded_cols;
    ELSIF (TG_OP = 'INSERT' AND TG_LEVEL = 'ROW') THEN
        audit_row.row_data = hstore(NEW.*) - excluded_cols;
    ELSIF (TG_LEVEL = 'STATEMENT' AND TG_OP IN ('INSERT','UPDATE','DELETE','TRUNCATE')) THEN
        audit_row.statement_only = 't';
    ELSE
        RAISE EXCEPTION '[audit.if_modified_func] - Trigger func added as trigger for unhandled case: %, %',TG_OP, TG_LEVEL;
        RETURN NULL;
    END IF;
   
    code_value = audit_row.row_data::json ->> (
        SELECT
            code_column
        FROM
            audit.audit_metadata
        WHERE
            table_name = tg_table_name
            AND schema_name = tg_table_schema);
           
    IF code_value IS NOT NULL THEN
        audit_row.code_value = code_value;
        audit_row.event_id = nextval('audit.logged_actions_event_id_seq');
        audit_row.referenced_table_name = tg_table_name::text;
        INSERT INTO audit.logged_actions VALUES (audit_row.*);
    ELSE
        table_id = (
            SELECT
                am.id
            FROM
                audit.audit_metadata am
            WHERE
                am.schema_name = tg_table_schema
                AND am.table_name = tg_table_name);
        PERFORM audit.audit_for_stronger_entity (audit_row, table_id, tg_table_name::text, audit_row.row_data);
    END IF;

    RETURN NULL;
END;
$body$
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public;


COMMENT ON FUNCTION audit.if_modified_func() IS $body$
Track changes to a table at the statement and/or row level.

Optional parameters to trigger in CREATE TRIGGER call:

param 0: boolean, whether to log the query text. Default 't'.

param 1: text[], columns to ignore in updates. Default [].

         Updates to ignored cols are omitted from changed_fields.

         Updates with only ignored cols changed are not inserted
         into the audit log.

         Almost all the processing work is still done for updates
         that ignored. If you need to save the load, you need to use
         WHEN clause on the trigger instead.

         No warning or error is issued if ignored_cols contains columns
         that do not exist in the target table. This lets you specify
         a standard set of ignored columns.

There is no parameter to disable logging of values. Add this trigger as
a 'FOR EACH STATEMENT' rather than 'FOR EACH ROW' trigger if you do not
want to log row values.

Note that the user name logged is the login role for the session. The audit trigger
cannot obtain the active role because it is reset by the SECURITY DEFINER invocation
of the audit trigger its self.
$body$;

CREATE OR REPLACE FUNCTION audit.audit_for_stronger_entity (audit_row audit.logged_actions, audit_table_id int, table_path text, previous_row_data hstore)
    RETURNS void
    AS $body$
DECLARE
    _code_column text;
    _code_value text;
    where_clause text;
    _table_name text;
    _referenced_table_name text;
    relation record;
    relation_count int;
    linked_entity_id bigint;
    queryText text;
BEGIN
    FOR relation IN SELECT * FROM audit.audit_reference ar WHERE ar.table_id = audit_table_id LOOP

        _table_name = (
            SELECT
                am.schema_name || '.' || am.table_name
            FROM
                audit.audit_metadata am
            WHERE
                id = relation.table_id);

        _referenced_table_name = (
            SELECT
                am.schema_name || '.' || am.table_name
            FROM
                audit.audit_metadata am
            WHERE
                id = relation.referenced_table_id);

        IF relation.relation_direction = 'DIRECT' THEN
            linked_entity_id = (previous_row_data::json ->> relation.relation_column);
            where_clause = 'id = ' || linked_entity_id;
        ELSE
            linked_entity_id = (previous_row_data::json ->> 'id');
            where_clause = relation.relation_column || ' = ' || linked_entity_id;
        END IF;

        _code_column = (
            SELECT
                am.code_column
            FROM
                audit.audit_metadata am
            WHERE
                am.schema_name = (SELECT split_part(_referenced_table_name, '.', 1))
                AND am.table_name = (SELECT split_part(_referenced_table_name, '.', 2)));

        IF where_clause IS NOT NULL THEN

            IF _code_column IS NULL THEN
                EXECUTE 'SELECT hstore(t) FROM ' || _referenced_table_name || ' AS t WHERE ' || where_clause || ';' INTO previous_row_data;
                PERFORM
                    audit.audit_for_stronger_entity (audit_row,
                        relation.referenced_table_id,
                        (SELECT split_part(_referenced_table_name, '.', 2)) || '/' || table_path, previous_row_data);
            ELSE
                queryText = 'SELECT COUNT(*) FROM ' || _referenced_table_name || ' WHERE ' || where_clause || ';';
                EXECUTE queryText INTO relation_count;
                EXECUTE 'SELECT ' || _referenced_table_name || '.' || _code_column || ' FROM ' || _referenced_table_name || ' WHERE ' || where_clause || ';' INTO _code_value;
                IF _code_value IS NOT NULL AND relation_count = 1 THEN
                    audit_row.code_value = _code_value;
                    audit_row.changed_fields = ('"Relationship"=>"' || (SELECT split_part(_referenced_table_name, '.', 2)) || '/' || table_path || '"')::hstore || audit_row.changed_fields;
                    audit_row.event_id = nextval('audit.logged_actions_event_id_seq');
                    audit_row.referenced_table_name = (SELECT split_part(_referenced_table_name, '.', 2));
                    INSERT INTO audit.logged_actions VALUES (audit_row.*);
                END IF;
            END IF;
        END IF;
    END LOOP;
    RETURN;
END;

$body$
LANGUAGE 'plpgsql';

-- comments
COMMENT ON FUNCTION audit.audit_for_stronger_entity (audit.logged_actions, int, text, hstore) IS $body$

Add relation of tables of weaker entities with tables of stronger ones.
This recursive function searches on audit_reference for relations among tables to set the changes of weaker tables as changes on the strong ones.
Thus, when retrieving changes from strong entities'' tables, it will also retrieve changes of depending tables. 

Arguments:
   audit_row:               audit.logged_actions row to be stored
   audit_table_id:          audit.audit_metadata identifier of table being audited
   table_path:              Representation of relationship of the strong entity with weaker ones
   previous_row_data:       Auxiliary variable storing information from weak entites for use in recursion
   
$body$;

CREATE OR REPLACE FUNCTION audit.audit_table(sq_table_name regclass, audit_rows boolean, audit_query_text boolean, ignored_cols text[], table_relations text[][], code_column text)
RETURNS void AS $body$
DECLARE
  stm_targets text = 'INSERT OR UPDATE OR DELETE OR TRUNCATE';
  _q_txt text;
  _ignored_cols_snip text = '';
  relation_count int;
  _table_id int;
  _referenced_table_id int;
  _referenced_schema_name text;
  _referenced_table_name text;
  _formatted_code_column text;
  _formatted_i18n text;
  _is_existing_id boolean;
  _relation_column text;
  _direction text;
  target_schema text;
  target_table text;
BEGIN
	target_schema = (SELECT split_part(sq_table_name::text, '.', 1));
	target_table = (SELECT split_part(sq_table_name::text, '.', 2));
	
    EXECUTE 'DROP TRIGGER IF EXISTS audit_trigger_row ON ' || target_schema || '.' || target_table;
    EXECUTE 'DROP TRIGGER IF EXISTS audit_trigger_stm ON ' || target_schema || '.' || target_table;

    IF array_length(ignored_cols, 1) > 0 THEN

        IF (SELECT
                count(*)
            FROM
                information_schema.columns
            WHERE
                table_schema = target_schema::text
                AND table_name = target_table::text
                AND column_name::text = ANY (ignored_cols)) <> array_length(ignored_cols, 1) THEN

            RAISE EXCEPTION 'Error creating trigger: column some ignored column(s) does not exist on table ''%.%''', target_schema, target_table;

        END IF;

        _ignored_cols_snip = quote_literal(ignored_cols);

    END IF;

   IF code_column IS NULL THEN
        _formatted_code_column = 'null';
    ELSE
        _formatted_code_column = '''' || code_column || '''';
    END IF;
   
   IF audit_rows THEN

        IF array_length(ignored_cols,1) > 0 THEN
            _ignored_cols_snip = ', ' || quote_literal(ignored_cols);
        END IF;
        
        _q_txt = 'CREATE TRIGGER audit_trigger_row AFTER INSERT OR UPDATE OR DELETE ON ' || target_schema || '.' 
                 || target_table || 
                 ' FOR EACH ROW EXECUTE PROCEDURE audit.if_modified_func(' ||
                 quote_literal(audit_query_text) || _ignored_cols_snip || ');';
        RAISE NOTICE '%',_q_txt;
        EXECUTE _q_txt;
        stm_targets = 'TRUNCATE';
    ELSE
    END IF;

    _q_txt = 'CREATE TRIGGER audit_trigger_stm AFTER ' || stm_targets || ' ON ' || target_schema || '.' ||
             target_table ||
             ' FOR EACH STATEMENT EXECUTE PROCEDURE audit.if_modified_func('||
             quote_literal(audit_query_text) || ');';
    RAISE NOTICE '%',_q_txt;
    EXECUTE _q_txt;

    _table_id = (SELECT id FROM audit.audit_metadata WHERE table_name = target_table::text AND schema_name = target_schema::text);

    IF _table_id IS NULL THEN
        _is_existing_id = FALSE;
        _table_id = nextval('audit.audit_metadata_id_seq');
        EXECUTE 'INSERT INTO audit.audit_metadata (id, schema_name, table_name, code_column) VALUES (''' || _table_id || ''', '''
        || target_schema || ''', ''' || target_table || ''', ' || _formatted_code_column || ');';
    ELSE
        _is_existing_id = TRUE;
        EXECUTE 'UPDATE audit.audit_metadata SET schema_name = ''' || target_schema || ''', table_name = ''' || target_table || ''', code_column = ' ||
        _formatted_code_column || ' WHERE id = ' || _table_id || ' ;';
    END IF;

    IF array_length(table_relations, 1) > 0 THEN

        IF _is_existing_id THEN
            DELETE FROM audit_reference
            WHERE table_id = _table_id;
        END IF;

        FOR relation_count IN 1..array_length(table_relations, 1) LOOP

            _referenced_schema_name = TRIM('''' FROM (table_relations[relation_count][1]));
            _referenced_table_name = TRIM('''' FROM (table_relations[relation_count][2]));
            _relation_column = TRIM('''' FROM (table_relations[relation_count][3]));
            _direction = TRIM('''' FROM (table_relations[relation_count][4]));

            IF _direction = 'DIRECT' THEN

                IF (SELECT
                        count(*)
                    FROM
                        information_schema.columns
                    WHERE
                        table_schema = target_schema
                        AND table_name = target_table::text
                        AND column_name = _relation_column) <> 1 THEN

                    RAISE EXCEPTION 'Error creating trigger: column ''%'' does not exist on table ''%.%''', _relation_column, schema_name, target_table;

                END IF;

            ELSE

                IF (SELECT
                        count(*)
                    FROM
                        information_schema.columns
                    WHERE
                        table_schema = _referenced_schema_name
                        AND table_name = _referenced_table_name
                        AND column_name = _relation_column) <> 1 THEN

                    RAISE EXCEPTION 'Error creating trigger: column ''%'' does not exist on table ''%.%''', _relation_column, schema_name, _referenced_table_name;

                END IF;

            END IF;

            _referenced_table_id = (SELECT
                                        id
                                    FROM
                                        audit.audit_metadata
                                    WHERE
                                        schema_name = _referenced_schema_name
                                        AND table_name = _referenced_table_name);

            EXECUTE 'INSERT INTO audit.audit_reference(table_id, referenced_table_id, relation_column, relation_direction) VALUES(' || _table_id || ',' ||
            _referenced_table_id || ',''' || _relation_column || ''',''' || _direction || ''');';

        END LOOP;

    END IF;

END;
$body$
language 'plpgsql';

COMMENT ON FUNCTION audit.audit_table(regclass, boolean, boolean, text[], text[][], text) IS $body$
Add auditing support to a table.

Arguments:
   sq_table_name:    Schema-qualified table name
   audit_rows:       Record each row change, or only audit at a statement level
   audit_query_text: Record the text of the client query that triggered the audit event?
   ignored_cols:     Columns to exclude from update diffs, ignore updates that change only ignored cols.
   table_relations:  Text representation of relations between weaker entities and stronger ones
   code_column:      Column that represents an end-user-meaningful identifier for audited entity
$body$;

-- Pg doesn't allow variadic calls with 0 params, so provide a wrapper
CREATE OR REPLACE FUNCTION audit.audit_table(sq_table_name regclass, audit_rows boolean, audit_query_text boolean, code_column text) RETURNS void AS $body$
SELECT audit.audit_table($1, $2, $3, ARRAY[]::text[], ARRAY[ARRAY[]::text[]]::text[], $4);
$body$ LANGUAGE SQL;

-- And provide a convenience call wrapper for the simplest case
-- of row-level logging with no excluded cols and query logging enabled.
--
CREATE OR REPLACE FUNCTION audit.audit_table(sq_table_name regclass, code_column text) RETURNS void AS $body$
SELECT audit.audit_table($1, BOOLEAN 't', BOOLEAN 't', $2);
$body$ LANGUAGE 'sql';

COMMENT ON FUNCTION audit.audit_table(regclass, text) IS $body$
Add auditing support to the given table. Row-level changes will be logged with full client query text. No cols are ignored.
$body$;

CREATE OR REPLACE VIEW audit.tableslist AS 
 SELECT DISTINCT triggers.trigger_schema AS schema,
    triggers.event_object_table AS auditedtable
   FROM information_schema.triggers
    WHERE triggers.trigger_name::text IN ('audit_trigger_row'::text, 'audit_trigger_stm'::text)  
ORDER BY schema, auditedtable;

COMMENT ON VIEW audit.tableslist IS $body$
View showing all tables with auditing set up. Ordered by schema, then table.
$body$;
