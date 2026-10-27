begin;
set local lock_timeout = '2s';
set local statement_timeout = '30s';

-- Retain the restricted public-view owner and its approval/consent RLS policy.
grant select (sla_started_at, deadline_at) on public.reports to ecopin_public_map_reader;

-- Append only missing columns, preserving each deployed view's existing column
-- order, projection, privacy predicates, owner, grants and security options.
do $$
declare
  view_name text;
  definition text;
  additions text;
  options text;
begin
  foreach view_name in array array['public_reports', 'reports_view'] loop
    select string_agg(format('r.%I', field), ', ' order by ordinal)
    into additions
    from unnest(array['sla_started_at', 'deadline_at']) with ordinality as desired(field, ordinal)
    where not exists (
      select 1 from information_schema.columns c
      where c.table_schema = 'public' and c.table_name = view_name and c.column_name = field
    );
    if additions is not null then
      definition := rtrim(pg_get_viewdef(format('public.%I', view_name)::regclass, true), E';\n ');
      select array_to_string(reloptions, ', ') into options
      from pg_class where oid = format('public.%I', view_name)::regclass;
      execute format(
        'create or replace view public.%I%s as select v.*, %s from (%s) v join public.reports r on r.id = v.id',
        view_name, coalesce(' with (' || options || ')', ''), additions, definition
      );
    end if;
  end loop;
end $$;

notify pgrst, 'reload schema';
commit;
