-- Migration: Remove Redundant Index on fc_operation_log (P06)
-- Timestamp: 20261012100000
-- Purpose:
--   Removes the non-unique redundant index `idx_fc_operation_log_operation_id` on `public.fc_operation_log(operation_id)`.
--   The table's primary key constraint `fc_operation_log_pkey` already provides an identical B-Tree index on `(operation_id)`.
--   Eliminating this duplicate removes 16 KiB of redundant index storage and avoids dual-index write penalty on every offline operation log insertion.
-- Rollback:
--   CREATE INDEX IF NOT EXISTS idx_fc_operation_log_operation_id ON public.fc_operation_log USING btree (operation_id);

DROP INDEX IF EXISTS public.idx_fc_operation_log_operation_id;
