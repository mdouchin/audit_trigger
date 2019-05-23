-- Sync tool based on audit.sql tool
CREATE SCHEMA IF NOT EXISTS sync;

-- Metadata
CREATE TABLE IF NOT EXISTS sync.server_metadata (
    server_id uuid DEFAULT md5(random()::text || clock_timestamp()::text)::uuid PRIMARY KEY,
    server_name text UNIQUE NOT NULL DEFAULT md5(random()::text || clock_timestamp()::text)::uuid
);


-- Schema to sync (white list)
DROP TABLE IF EXISTS sync.synchronized_schemas;
CREATE TABLE IF NOT EXISTS sync.synchronized_schemas (
    server_id uuid PRIMARY KEY,
    sync_schemas jsonb NOT NULL
);
COMMENT ON TABLE sync.synchronized_schemas IS 'List of schemas to synchronize per slave server id. This list works as a white list. Only listed schemas will be synchronized for each server ids.';

-- Sync history log
CREATE TABLE IF NOT EXISTS sync.history (
    sync_id uuid DEFAULT md5(random()::text || clock_timestamp()::text)::uuid PRIMARY KEY,
    sync_time TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
    server_from text NOT NULL,
    server_to text[],
    min_event_id integer,
    max_event_id integer,
    max_action_tstamp_tx TIMESTAMP WITH TIME ZONE,
    sync_type text NOT NULL,
    sync_status text NOT NULL DEFAULT 'pending'
);

-- sync_type
-- 'full'    = Lors d'une récupération des données via écrasement et restauration de toutes les données ->
-- 'partial' = Lors d'une récupération des données via synchronisation


-- Add the uid column when needed
-- You can run it for all tables in a schema with
-- SELECT sync.add_uid_columns(table_schema, table_name) FROM information_schema.tables WHERE table_schema = 'my_schema_name'
DROP FUNCTION IF EXISTS sync.add_uid_columns( text, text);
CREATE OR REPLACE FUNCTION sync.add_uid_columns( p_schema_name text, p_table_name text) RETURNS void AS $body$
DECLARE
  query text;
BEGIN

    BEGIN
        SELECT INTO query
        concat(
            ' ALTER TABLE ' || quote_ident(p_schema_name) || '.' || quote_ident(p_table_name) ||
            ' ADD COLUMN uid uuid DEFAULT md5(random()::text || clock_timestamp()::text)::uuid ' ||
            ' UNIQUE NOT NULL'
        );
        execute query;
        RAISE NOTICE 'uid column created for % %', quote_ident(p_schema_name), quote_ident(p_table_name);
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'ERROR - uid column already exists';
    END;

END;
$body$
LANGUAGE plpgsql;

-- Get the SQL corresponding to an event log, without the PKs for INSERTS
-- Use the uid to filter the UPDATE and INSERT clauses
DROP FUNCTION IF EXISTS sync.get_event_sql(bigint, text);
CREATE OR REPLACE FUNCTION sync.get_event_sql(pevent_id bigint, puid_column text) RETURNS text AS $body$
DECLARE
  sql text;
BEGIN
    with
    event as (
        select * from audit.logged_actions where event_id = pevent_id
    )
    -- get primary key names
    , where_pks as (
        select array_agg(uid_column) as pkey_fields
        from audit.logged_relations r
        join event on relation_name = (quote_ident(schema_name) || '.' || quote_ident(table_name))
    )
    -- create where clause with uid column
    -- not with primary keys, to manage multi-way sync
    , where_uid as (
        select puid_column || '=' || quote_literal(row_data->puid_column) as where_clause
        from event
    )
    select into sql
        case
            when action = 'I' then
                'INSERT INTO "' || schema_name || '"."' || table_name || '"' ||
                ' ('||(select string_agg(key, ',') from each(row_data) WHERE key != ANY(pkey_fields))||') VALUES ' ||
                '('||(select string_agg(case when value is null then 'null' else quote_literal(value) end, ',') from each(row_data) WHERE key != ANY(pkey_fields))||')'
            when action = 'D' then
                'DELETE FROM "' || schema_name || '"."' || table_name || '"' ||
                ' WHERE ' || where_clause
            when action = 'U' then
                'UPDATE "' || schema_name || '"."' || table_name || '"' ||
                ' SET ' || (select string_agg(key || '=' || case when value is null then 'null' else quote_literal(value) end, ',') from each(changed_fields) WHERE key != ANY(pkey_fields)) ||
                ' WHERE ' || where_clause
        end
    from
        event, where_pks, where_uid
    ;
    RETURN sql;
END;
$body$
LANGUAGE plpgsql;

COMMENT ON FUNCTION sync.get_event_sql(bigint, text) IS $body$
Get the SQL to use for replay from a audit log event

Arguments:
   pevent_id:  The event_id of the event in audit.logged_actions to replay
   puid_column: The name of the column with unique uuid values
$body$;



-- PostgreSQL 9.5: add fallback current_setting function
-- CREATE OR REPLACE FUNCTION public.current_setting(myvar text, myretex boolean) RETURNS text AS $$
-- DECLARE
    -- mytext text;
-- BEGIN
   -- BEGIN
      -- mytext := current_setting(myvar)::text;
   -- EXCEPTION
      -- WHEN SQLSTATE '42704' THEN
         -- mytext := NULL;
   -- END;
   -- RETURN mytext;
-- END;
-- $$ LANGUAGE plpgsql;
