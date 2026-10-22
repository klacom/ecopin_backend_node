-- New enum labels commit before schema/functions can reference them.
alter type public.cleanup_task_type add value if not exists 'Mixed';
alter type public.cleanup_task_status add value if not exists 'failed';
alter type public.route_waypoint_type add value if not exists 'bundled_report';

do $$ begin
  if not exists(select 1 from pg_type where typnamespace='public'::regnamespace and typname='vehicle_type_enum') then
    create type public.vehicle_type_enum as enum ('compactor','pickup','tricycle','motorcycle','hazmat_unit');
  end if;
end $$;
