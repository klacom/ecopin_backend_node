-- Commit these enum labels before executing any crew writes that use them.
-- Rollback leaves the additive labels in place; removing enum values requires rebuilding the type.
alter type public.lifecycle_stage add value if not exists 'acknowledged' after 'assigned';
alter type public.lifecycle_stage add value if not exists 'responded' after 'in_progress';
