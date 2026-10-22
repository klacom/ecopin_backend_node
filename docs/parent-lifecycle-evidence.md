# Parent deletion and lifecycle write measurements

Run `tests/sql/parent-lifecycle-wal-regression.sql` only against the private local recovery stack. It uses `ON_ERROR_STOP`, bounded statement/lock timeouts, synthetic fixtures and one outer transaction that always rolls back on successful completion (disconnect rolls back failures). Both lifecycle indexes are restored by rollback to a savepoint; no business triggers are disabled.

The real profile and Auth parent deletions are first attempted while 50 reports remain. Both raise foreign-key violations, and all report history is preserved. Report-parent deletion then cascades 100 linked notifications while retaining 100 user-only notifications. The supported empty-profile-then-Auth deletion subsequently cascades those remaining notifications. The harness does not delete child rows manually and call that a cascade.

Measurements use sequential `pg_current_wal_insert_lsn()` captures surrounding `EXPLAIN (ANALYZE, BUFFERS, WAL, FORMAT JSON)`. Plans, node WAL, FK/business trigger timings and global insert-LSN deltas are retained. Global deltas can include concurrent background WAL; one warm-cache local run cannot establish production percentiles or prove zero unindexed FK scans. The older unordered write-CTE/`pg_current_wal_lsn()` zero-WAL results are superseded and must not be cited.

The lifecycle comparison performs the identical close transition from identical fixture state with both existing lifecycle indexes present, then absent inside a rolled-back subtransaction. All lifecycle/version/notification/audit triggers remain active. It measures the write-side cost; it does not justify removing indexes needed by read workloads. Read/write tradeoffs require the representative workload gate.

Local result, 12 October 2026: report cascade 13.277 ms / 12,512 global WAL bytes; empty profile 3.084 ms / 88 bytes; Auth cascade 2.703 ms / 8,112 bytes. Lifecycle close with indexes: 30.665 ms / 154,432 bytes; without: 21.518 ms / 123,336 bytes. Treat these as single observations with cache/order/background-WAL caveats. Full JSON: `C:/dev/App-Builders-Hackathon/.ecopin-optimization/PARENT_LIFECYCLE_WAL_VERIFICATION.json`.
