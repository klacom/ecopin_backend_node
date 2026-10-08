begin;
-- The lifecycle function records a durable completion audit on every run.
select cron.schedule('ecopin-report-lifecycle','0 * * * *','select public.advance_report_lifecycle();');
select cron.schedule('ecopin-dispatch-watchdog','*/5 * * * *','select public.expire_unpublished_dispatch_claims();');
commit;
