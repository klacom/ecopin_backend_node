-- Minimal isolated schema for testing the actual photo RPC, not a policy copy.
do $$ begin
 if not exists(select 1 from pg_roles where rolname='anon') then create role anon; end if;
 if not exists(select 1 from pg_roles where rolname='authenticated') then create role authenticated; end if;
 if not exists(select 1 from pg_roles where rolname='service_role') then create role service_role; end if;
end $$;
create schema workflow_private;
create table public.cleanup_tasks(id uuid primary key,status text);
create table public.reports(id uuid primary key,cleanup_task_id uuid,status text,stage text,
 fc_version bigint,before_photo_url text,after_photo_url text,before_photo_hash text,after_photo_hash text,updated_at timestamptz);
create function workflow_private.can_execute_task(actor uuid,task public.cleanup_tasks)
returns boolean language sql as $$ select actor='00000000-0000-0000-0000-000000000002'::uuid $$;
