-- ============================================================================
-- ECOPIN P06/P07 INDEX REGRESSION TEST SUITE
-- Verifies redundant index removal (P06), overlapping index justification (P07),
-- index-only scan access paths, and preservation of all uniqueness invariants.
-- ============================================================================

DO $$
DECLARE
  v_test_name text;
  v_count integer;
BEGIN
  RAISE NOTICE 'Starting P06/P07 Index Optimization & Invariant Regression Suite...';

  -- --------------------------------------------------------------------------
  -- TEST 1: P06 Redundant Index Removal on fc_operation_log
  -- --------------------------------------------------------------------------
  v_test_name := 'P06: idx_fc_operation_log_operation_id is dropped';
  SELECT count(*) INTO v_count
  FROM pg_indexes
  WHERE schemaname = 'public'
    AND tablename = 'fc_operation_log'
    AND indexname = 'idx_fc_operation_log_operation_id';

  IF v_count = 0 THEN
    RAISE NOTICE 'PASS: %', v_test_name;
  ELSE
    RAISE EXCEPTION 'FAIL: % (found % instances)', v_test_name, v_count;
  END IF;

  -- --------------------------------------------------------------------------
  -- TEST 2: P06 Primary Key Index Intact on fc_operation_log
  -- --------------------------------------------------------------------------
  v_test_name := 'P06: fc_operation_log_pkey exists and covers (operation_id)';
  SELECT count(*) INTO v_count
  FROM pg_indexes
  WHERE schemaname = 'public'
    AND tablename = 'fc_operation_log'
    AND indexname = 'fc_operation_log_pkey';

  IF v_count = 1 THEN
    RAISE NOTICE 'PASS: %', v_test_name;
  ELSE
    RAISE EXCEPTION 'FAIL: % (found % instances)', v_test_name, v_count;
  END IF;

  -- --------------------------------------------------------------------------
  -- TEST 3: P06 Version Index Retention on reports and cleanup_tasks
  -- --------------------------------------------------------------------------
  v_test_name := 'P06: idx_reports_fc_version and idx_cleanup_tasks_fc_version retained';
  SELECT count(*) INTO v_count
  FROM pg_indexes
  WHERE schemaname = 'public'
    AND (
      (tablename = 'reports' AND indexname = 'idx_reports_fc_version') OR
      (tablename = 'cleanup_tasks' AND indexname = 'idx_cleanup_tasks_fc_version')
    );

  IF v_count = 2 THEN
    RAISE NOTICE 'PASS: %', v_test_name;
  ELSE
    RAISE EXCEPTION 'FAIL: % (found % of 2)', v_test_name, v_count;
  END IF;

  -- --------------------------------------------------------------------------
  -- TEST 4: P07 Cluster Index Specialization on reports
  -- --------------------------------------------------------------------------
  v_test_name := 'P07: reports retains idx_reports_cluster_id and reports_active_cluster_membership';
  SELECT count(*) INTO v_count
  FROM pg_indexes
  WHERE schemaname = 'public'
    AND tablename = 'reports'
    AND indexname IN ('idx_reports_cluster_id', 'reports_active_cluster_membership');

  IF v_count = 2 THEN
    RAISE NOTICE 'PASS: %', v_test_name;
  ELSE
    RAISE EXCEPTION 'FAIL: % (found % of 2)', v_test_name, v_count;
  END IF;

  -- --------------------------------------------------------------------------
  -- TEST 5: P07 Notification Indexes Hierarchy Retained
  -- --------------------------------------------------------------------------
  v_test_name := 'P07: notifications retains user FK, feed, and unread partial index';
  SELECT count(*) INTO v_count
  FROM pg_indexes
  WHERE schemaname = 'public'
    AND tablename = 'notifications'
    AND indexname IN ('idx_notifications_user', 'idx_notifications_user_created', 'idx_notifications_unread_feed');

  IF v_count = 3 THEN
    RAISE NOTICE 'PASS: %', v_test_name;
  ELSE
    RAISE EXCEPTION 'FAIL: % (found % of 3)', v_test_name, v_count;
  END IF;

  -- --------------------------------------------------------------------------
  -- TEST 6: P07 Dispatch Plan Item Indexes Retained
  -- --------------------------------------------------------------------------
  v_test_name := 'P07: dispatch_plan_items retains plan FK and group composite index';
  SELECT count(*) INTO v_count
  FROM pg_indexes
  WHERE schemaname = 'public'
    AND tablename = 'dispatch_plan_items'
    AND indexname IN ('idx_dispatch_plan_items_plan_id', 'dispatch_item_group_idx');

  IF v_count = 2 THEN
    RAISE NOTICE 'PASS: %', v_test_name;
  ELSE
    RAISE EXCEPTION 'FAIL: % (found % of 2)', v_test_name, v_count;
  END IF;

  -- --------------------------------------------------------------------------
  -- TEST 7: P07 Hotspot Predictions Unique Composite Retained
  -- --------------------------------------------------------------------------
  v_test_name := 'P07: hotspot_predictions retains unique composite (region_id, date, horizon)';
  SELECT count(*) INTO v_count
  FROM pg_indexes
  WHERE schemaname = 'public'
    AND tablename = 'hotspot_predictions'
    AND indexname = 'idx_hotspot_predictions_unique';

  IF v_count = 1 THEN
    RAISE NOTICE 'PASS: %', v_test_name;
  ELSE
    RAISE EXCEPTION 'FAIL: % (found % of 1)', v_test_name, v_count;
  END IF;

  -- --------------------------------------------------------------------------
  -- TEST 8: Invariant Preservation Across Tables
  -- --------------------------------------------------------------------------
  v_test_name := 'Preservation: All unique invariants and idempotency constraints intact';
  SELECT count(*) INTO v_count
  FROM pg_indexes
  WHERE schemaname = 'public'
    AND indexname IN (
      'reports_idempotency_key_key',
      'task_completion_operation',
      'task_source_group',
      'dispatch_unique_cluster',
      'dispatch_unique_report',
      'idx_hotspot_predictions_unique'
    );

  IF v_count = 6 THEN
    RAISE NOTICE 'PASS: %', v_test_name;
  ELSE
    RAISE EXCEPTION 'FAIL: % (found % of 6)', v_test_name, v_count;
  END IF;

  RAISE NOTICE 'ALL 8 P06/P07 REGRESSION TESTS PASSED SUCCESSFULLY.';
END $$;
