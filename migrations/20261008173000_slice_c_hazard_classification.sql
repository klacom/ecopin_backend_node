begin;

alter table public.reports
  add column if not exists hazard_class text not null default 'unknown',
  add column if not exists hazard_model_version text,
  add column if not exists hazard_confidence numeric(4,3),
  add column if not exists hazard_decision_source text,
  add column if not exists hazard_classified_at timestamptz;

alter table public.reports
  add constraint reports_hazard_class_check
    check (hazard_class in ('unknown','standard','suspected_hazard','hazmat_required')),
  add constraint reports_hazard_confidence_check
    check (hazard_confidence is null or hazard_confidence between 0 and 1),
  add constraint reports_hazard_metadata_check
    check (hazard_class = 'unknown' or
      (hazard_model_version is not null and hazard_confidence is not null
       and hazard_decision_source is not null and hazard_classified_at is not null));

create index reports_hazard_dispatch_review
  on public.reports(hazard_class, lifecycle_state)
  where hazard_class in ('suspected_hazard','hazmat_required');

commit;
