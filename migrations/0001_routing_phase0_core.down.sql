-- =============================================================================
-- 0001_routing_phase0_core.down.sql
--
-- Reverses 0001_routing_phase0_core.up.sql.
--
-- WARNING: this drops the routing audit log. routing_events and
-- routing_attempts are the only reproducible record of past routing decisions
-- and COGS (ADR §15.1); once dropped they cannot be reconstructed from the
-- rolling metrics tables. Take a dump before running this against anything
-- that has seen traffic.
-- =============================================================================

BEGIN;

DROP VIEW IF EXISTS routing.request_cogs;

-- Partitions are dropped with their parents.
DROP TABLE IF EXISTS routing.routing_attempts;
DROP TABLE IF EXISTS routing.routing_events;

DROP TABLE IF EXISTS routing.workspace_routing_policies;

DROP TRIGGER IF EXISTS pricing_snapshots_freeze_trg ON routing.pricing_snapshots;
DROP TABLE IF EXISTS routing.pricing_snapshots;
DROP FUNCTION IF EXISTS routing.pricing_snapshots_freeze();

DROP TRIGGER IF EXISTS control_plane_versions_freeze_trg ON routing.control_plane_versions;
DROP TABLE IF EXISTS routing.control_plane_versions;
DROP FUNCTION IF EXISTS routing.control_plane_versions_freeze();

DROP TYPE IF EXISTS routing.failure_class;
DROP TYPE IF EXISTS routing.selection_reason;
DROP TYPE IF EXISTS routing.pricing_mode;
DROP TYPE IF EXISTS routing.pin_fallback_policy;
DROP TYPE IF EXISTS routing.pin_scope;
DROP TYPE IF EXISTS routing.seed_scope;
DROP TYPE IF EXISTS routing.allocation_mode;
DROP TYPE IF EXISTS routing.workload_class;
DROP TYPE IF EXISTS routing.routing_mode;
DROP TYPE IF EXISTS routing.control_plane_status;

DROP SCHEMA IF EXISTS routing;

COMMIT;
