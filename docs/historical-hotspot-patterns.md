# PDT-19 deployment and API contract

See the complete [history/forecast contract, rules and rollout notes](../../ecopin-web/docs/historical-hotspot-patterns.md).

New migration: `20261029070000_hotspot_pattern_history.sql`, after PDT-08 reconciliation and the forward-zone baseline. New protected read: `GET /api/spatial-forecast/patterns` (alias `/api/spatial/patterns`), officer/admin only. The backend and Python service require the same server-only `SPATIAL_ANALYTICS_TOKEN`. The service-only SQL RPC includes precise report locations for ML computation; only sanitized aggregated output reaches the browser. No live migration or deployment has been performed for PDT-19.
