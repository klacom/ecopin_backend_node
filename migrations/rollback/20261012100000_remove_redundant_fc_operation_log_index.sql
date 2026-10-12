-- Rollback Migration for 20261012100000_remove_redundant_fc_operation_log_index.sql
-- Restores the non-unique index on public.fc_operation_log(operation_id).

CREATE INDEX IF NOT EXISTS idx_fc_operation_log_operation_id
  ON public.fc_operation_log USING btree (operation_id);
