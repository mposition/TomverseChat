-- =============================================================================
-- Smoke test for 0001_routing_phase0_core.
--
-- Asserts that the schema enforces the ADR invariants it claims to enforce.
-- Run against a scratch database that has 0001 applied:
--   psql -d tomverse -v ON_ERROR_STOP=1 -f migrations/tests/0001_constraints_test.sql
-- Prints 'ALL SCHEMA CONSTRAINT TESTS PASSED' on success; raises otherwise.
-- =============================================================================

\set ON_ERROR_STOP on

-- Asserts that `stmt` fails. Fails the test run if the statement succeeds.
CREATE OR REPLACE FUNCTION pg_temp.must_fail(label TEXT, stmt TEXT)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    BEGIN
        EXECUTE stmt;
    EXCEPTION WHEN others THEN
        RAISE NOTICE 'ok   %  (rejected: %)', label, left(SQLERRM, 70);
        RETURN;
    END;
    RAISE EXCEPTION 'FAILED: % — statement was accepted but should have been rejected', label;
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp.must_pass(label TEXT, stmt TEXT)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    EXECUTE stmt;
    RAISE NOTICE 'ok   %', label;
END;
$$;

-- -----------------------------------------------------------------------------
-- Fixtures
-- -----------------------------------------------------------------------------

INSERT INTO routing.control_plane_versions (
    provider_registry_version, deployment_registry_version,
    routing_weights_version, routing_anchors_version,
    pricing_catalog_version, quality_policy_version, version_policy_version,
    status, activated_at
) VALUES (1, 1, 1, 1, 1, 1, 1, 'active', now());

INSERT INTO routing.workspace_routing_policies (workspace_id, version)
VALUES ('ws_test', 1);

INSERT INTO routing.pricing_snapshots (
    pricing_catalog_version, deployment_id,
    input_per_1m, cached_input_per_1m, output_per_1m, effective_from
) VALUES (1, 'dep_deepinfra_x', 0.27, 0.027, 0.85, now());

-- -----------------------------------------------------------------------------
-- control_plane_versions — ADR §13, §15.4 (N10)
-- -----------------------------------------------------------------------------

SELECT pg_temp.must_fail(
    'only one manifest may be active',
    $$INSERT INTO routing.control_plane_versions (
          provider_registry_version, deployment_registry_version,
          routing_weights_version, routing_anchors_version,
          pricing_catalog_version, quality_policy_version, version_policy_version,
          status, activated_at)
      VALUES (2,2,2,2,2,2,2,'active', now())$$);

SELECT pg_temp.must_pass(
    'a non-active manifest may coexist',
    $$INSERT INTO routing.control_plane_versions (
          provider_registry_version, deployment_registry_version,
          routing_weights_version, routing_anchors_version,
          pricing_catalog_version, quality_policy_version, version_policy_version,
          status)
      VALUES (2,2,2,2,2,2,2,'canary')$$);

SELECT pg_temp.must_fail(
    'manifest child versions are immutable',
    $$UPDATE routing.control_plane_versions SET pricing_catalog_version = 99 WHERE id = 1$$);

SELECT pg_temp.must_pass(
    'manifest status may still be changed',
    $$UPDATE routing.control_plane_versions SET status = 'shadow' WHERE id = 2$$);

SELECT pg_temp.must_fail(
    'active manifest requires activated_at',
    $$INSERT INTO routing.control_plane_versions (
          provider_registry_version, deployment_registry_version,
          routing_weights_version, routing_anchors_version,
          pricing_catalog_version, quality_policy_version, version_policy_version,
          status)
      VALUES (3,3,3,3,3,3,3,'active')$$);

-- -----------------------------------------------------------------------------
-- pricing_snapshots — ADR §13, §6.3
-- -----------------------------------------------------------------------------

SELECT pg_temp.must_fail(
    'price values are immutable',
    $$UPDATE routing.pricing_snapshots SET input_per_1m = 1.0 WHERE id = 1$$);

SELECT pg_temp.must_pass(
    'effective_to may be closed by a successor',
    $$UPDATE routing.pricing_snapshots SET effective_to = now() + interval '1 day' WHERE id = 1$$);

SELECT pg_temp.must_fail(
    'cached input price above uncached price is rejected',
    $$INSERT INTO routing.pricing_snapshots (
          pricing_catalog_version, deployment_id,
          input_per_1m, cached_input_per_1m, output_per_1m, effective_from)
      VALUES (1, 'dep_bad_cache', 0.27, 0.50, 0.85, now())$$);

SELECT pg_temp.must_fail(
    'one price row per (catalog, deployment, mode)',
    $$INSERT INTO routing.pricing_snapshots (
          pricing_catalog_version, deployment_id,
          input_per_1m, output_per_1m, effective_from)
      VALUES (1, 'dep_deepinfra_x', 0.30, 0.90, now())$$);

-- -----------------------------------------------------------------------------
-- workspace_routing_policies — ADR §3.5 (N6), §8.4 (N7)
-- -----------------------------------------------------------------------------

SELECT pg_temp.must_fail(
    'pin_scope=provider requires a pinned provider',
    $$INSERT INTO routing.workspace_routing_policies
          (workspace_id, version, pin_scope, allow_exploration)
      VALUES ('ws_pin', 1, 'provider', false)$$);

SELECT pg_temp.must_fail(
    'a pinned workspace may not enable exploration',
    $$INSERT INTO routing.workspace_routing_policies
          (workspace_id, version, pin_scope, pinned_provider_id, allow_exploration)
      VALUES ('ws_pin', 1, 'provider', 'prv_anthropic', true)$$);

SELECT pg_temp.must_pass(
    'a pinned workspace with exploration off is accepted',
    $$INSERT INTO routing.workspace_routing_policies
          (workspace_id, version, pin_scope, pinned_provider_id, allow_exploration)
      VALUES ('ws_pin', 1, 'provider', 'prv_anthropic', false)$$);

DO $$
BEGIN
    IF (SELECT pin_fallback_policy FROM routing.workspace_routing_policies
        WHERE workspace_id = 'ws_pin' AND version = 1) <> 'error' THEN
        RAISE EXCEPTION 'pin_fallback_policy default is not error';
    END IF;
    RAISE NOTICE 'ok   pin_fallback_policy defaults to error';
END $$;

-- -----------------------------------------------------------------------------
-- routing_events — ADR §8.3 (N1), §13 (N2), §16 (N11)
-- -----------------------------------------------------------------------------

SELECT pg_temp.must_pass(
    'a well-formed routing event is accepted',
    $$INSERT INTO routing.routing_events (
          request_id, session_id, workspace_id, logical_model_id, workload_class,
          routing_mode, control_plane_version, workspace_policy_version,
          candidate_evaluations, selected_deployment_id, selection_reason,
          allocation_mode, decision_seed, seed_scope,
          affinity_deployment_id, affinity_epoch,
          estimated_output_tokens, estimated_effective_cost, max_attempts)
      VALUES (
          'req_1', 'ses_1', 'ws_test', 'mdl_llama', 'interactive_chat',
          'balanced', 1, 1,
          '[{"deployment_id":"dep_deepinfra_x","gate_result":"eligible","routing_penalty":0.71}]'::jsonb,
          'dep_deepinfra_x', 'session_affinity',
          'sequential', 'a1b2c3', 'session',
          'dep_deepinfra_x', 0, 512, 0.00042, 3)$$);

SELECT pg_temp.must_fail(
    'a session-scoped seed requires a session_id',
    $$INSERT INTO routing.routing_events (
          request_id, workspace_id, logical_model_id, workload_class, routing_mode,
          control_plane_version, workspace_policy_version, candidate_evaluations,
          allocation_mode, decision_seed, seed_scope)
      VALUES ('req_2', 'ws_test', 'mdl_llama', 'interactive_chat', 'balanced',
              1, 1, '[]'::jsonb, 'sequential', 'seed', 'session')$$);

SELECT pg_temp.must_fail(
    'candidate_evaluations must be a JSON array',
    $$INSERT INTO routing.routing_events (
          request_id, workspace_id, logical_model_id, workload_class, routing_mode,
          control_plane_version, workspace_policy_version, candidate_evaluations,
          allocation_mode, decision_seed, seed_scope)
      VALUES ('req_3', 'ws_test', 'mdl_llama', 'batch_offline', 'balanced',
              1, 1, '{"not":"an array"}'::jsonb, 'sequential', 'seed', 'request')$$);

SELECT pg_temp.must_fail(
    'sequential allocation cannot carry a shadow selection',
    $$INSERT INTO routing.routing_events (
          request_id, workspace_id, logical_model_id, workload_class, routing_mode,
          control_plane_version, workspace_policy_version, candidate_evaluations,
          allocation_mode, decision_seed, seed_scope, shadow_selected_deployment_id)
      VALUES ('req_4', 'ws_test', 'mdl_llama', 'batch_offline', 'balanced',
              1, 1, '[]'::jsonb, 'sequential', 'seed', 'request', 'dep_x')$$);

SELECT pg_temp.must_fail(
    'an unknown workspace policy version is rejected',
    $$INSERT INTO routing.routing_events (
          request_id, workspace_id, logical_model_id, workload_class, routing_mode,
          control_plane_version, workspace_policy_version, candidate_evaluations,
          allocation_mode, decision_seed, seed_scope)
      VALUES ('req_5', 'ws_test', 'mdl_llama', 'batch_offline', 'balanced',
              1, 999, '[]'::jsonb, 'sequential', 'seed', 'request')$$);

SELECT pg_temp.must_fail(
    'an unknown control_plane_version is rejected',
    $$INSERT INTO routing.routing_events (
          request_id, workspace_id, logical_model_id, workload_class, routing_mode,
          control_plane_version, workspace_policy_version, candidate_evaluations,
          allocation_mode, decision_seed, seed_scope)
      VALUES ('req_6', 'ws_test', 'mdl_llama', 'batch_offline', 'balanced',
              999, 1, '[]'::jsonb, 'sequential', 'seed', 'request')$$);

SELECT pg_temp.must_fail(
    'a selected deployment cannot be labelled no_candidate',
    $$INSERT INTO routing.routing_events (
          request_id, workspace_id, logical_model_id, workload_class, routing_mode,
          control_plane_version, workspace_policy_version, candidate_evaluations,
          selected_deployment_id, selection_reason,
          allocation_mode, decision_seed, seed_scope)
      VALUES ('req_7', 'ws_test', 'mdl_llama', 'batch_offline', 'balanced',
              1, 1, '[]'::jsonb, 'dep_x', 'no_candidate',
              'sequential', 'seed', 'request')$$);

SELECT pg_temp.must_pass(
    'a fully gated-out request is recorded as no_candidate',
    $$INSERT INTO routing.routing_events (
          request_id, workspace_id, logical_model_id, workload_class, routing_mode,
          control_plane_version, workspace_policy_version, candidate_evaluations,
          selection_reason, allocation_mode, decision_seed, seed_scope)
      VALUES ('req_8', 'ws_test', 'mdl_llama', 'batch_offline', 'balanced',
              1, 1, '[{"deployment_id":"dep_x","gate_result":"rejected","gate_reasons":["quality_gate_stale"]}]'::jsonb,
              'no_candidate', 'sequential', 'seed', 'request')$$);

-- -----------------------------------------------------------------------------
-- routing_attempts — ADR §7.1 (N3), §10.1, §11 (N8), §6.4
-- -----------------------------------------------------------------------------

SELECT pg_temp.must_pass(
    'a successful attempt records calibration inputs',
    $$INSERT INTO routing.routing_attempts (
          request_id, attempt_number, deployment_id, credential_id, quota_scope_id,
          pricing_snapshot_id, started_at, first_token_at, stream_committed_at, ended_at,
          http_status, finish_reason, input_tokens, cached_input_tokens, output_tokens,
          estimated_output_tokens, estimated_cost, estimated_cache_savings, actual_cost)
      VALUES (
          'req_1', 1, 'dep_deepinfra_x', 'cred_tomverse', 'qs_org_1',
          1, now(), now() + interval '600 ms', now() + interval '650 ms', now() + interval '4 s',
          200, 'stop', 4200, 3800, 480, 512, 0.00042, 0.00009, 0.00051)$$);

SELECT pg_temp.must_fail(
    'retry_after_ms only accompanies a 429',
    $$INSERT INTO routing.routing_attempts (
          request_id, attempt_number, deployment_id, started_at,
          failure_class, retry_after_ms)
      VALUES ('req_1', 2, 'dep_y', now(), 'availability_5xx', 1500)$$);

SELECT pg_temp.must_pass(
    'a 429 attempt may carry retry_after_ms',
    $$INSERT INTO routing.routing_attempts (
          request_id, attempt_number, deployment_id, credential_id, started_at,
          failure_class, http_status, retry_after_ms)
      VALUES ('req_1', 3, 'dep_y', 'cred_byok_ws', now(), 'capacity_429', 429, 1500)$$);

SELECT pg_temp.must_fail(
    'the commit point cannot precede the first token',
    $$INSERT INTO routing.routing_attempts (
          request_id, attempt_number, deployment_id, started_at, stream_committed_at)
      VALUES ('req_1', 4, 'dep_y', now(), now() + interval '1 s')$$);

SELECT pg_temp.must_fail(
    'a pre-commit failure class cannot appear after commit',
    $$INSERT INTO routing.routing_attempts (
          request_id, attempt_number, deployment_id, started_at,
          first_token_at, stream_committed_at, failure_class)
      VALUES ('req_1', 5, 'dep_y', now(),
              now() + interval '1 s', now() + interval '2 s', 'precommit_timeout')$$);

SELECT pg_temp.must_pass(
    'a post-commit stream failure after commit is accepted',
    $$INSERT INTO routing.routing_attempts (
          request_id, attempt_number, deployment_id, started_at,
          first_token_at, stream_committed_at, failure_class, finish_reason)
      VALUES ('req_1', 6, 'dep_y', now(),
              now() + interval '1 s', now() + interval '2 s',
              'post_commit_stream_failure', 'upstream_error')$$);

SELECT pg_temp.must_fail(
    'validation_error_code is scoped to body-level failures',
    $$INSERT INTO routing.routing_attempts (
          request_id, attempt_number, deployment_id, started_at,
          failure_class, validation_error_code)
      VALUES ('req_1', 7, 'dep_y', now(), 'auth_billing', 'schema_violation')$$);

SELECT pg_temp.must_pass(
    'malformed_output carries a validation_error_code',
    $$INSERT INTO routing.routing_attempts (
          request_id, attempt_number, deployment_id, started_at,
          http_status, failure_class, validation_error_code)
      VALUES ('req_1', 8, 'dep_y', now(), 200, 'malformed_output', 'tool_call_json_parse_error')$$);

SELECT pg_temp.must_fail(
    'cached input tokens cannot exceed input tokens',
    $$INSERT INTO routing.routing_attempts (
          request_id, attempt_number, deployment_id, started_at,
          input_tokens, cached_input_tokens)
      VALUES ('req_1', 9, 'dep_y', now(), 100, 200)$$);

-- -----------------------------------------------------------------------------
-- Derived values
-- -----------------------------------------------------------------------------

DO $$
DECLARE err_abs NUMERIC; err_pct NUMERIC; cogs NUMERIC; attempts INT; failed INT;
BEGIN
    SELECT cost_estimation_error_abs, cost_estimation_error_pct
      INTO err_abs, err_pct
      FROM routing.routing_attempts WHERE request_id = 'req_1' AND attempt_number = 1;
    IF err_abs IS DISTINCT FROM 0.00009000 THEN
        RAISE EXCEPTION 'cost_estimation_error_abs = %, expected 0.00009', err_abs;
    END IF;
    IF round(err_pct, 4) IS DISTINCT FROM round(0.00009 / 0.00042 * 100, 4) THEN
        RAISE EXCEPTION 'cost_estimation_error_pct = %', err_pct;
    END IF;
    RAISE NOTICE 'ok   estimator calibration columns are computed (abs=%, pct=%)',
        err_abs, round(err_pct, 3);

    SELECT request_actual_cogs, attempt_count, failed_attempt_count
      INTO cogs, attempts, failed
      FROM routing.request_cogs WHERE request_id = 'req_1';
    IF cogs IS DISTINCT FROM 0.00051000 THEN
        RAISE EXCEPTION 'request_actual_cogs = %, expected 0.00051', cogs;
    END IF;
    RAISE NOTICE 'ok   request_cogs view sums attempts (cogs=%, attempts=%, failed=%)',
        cogs, attempts, failed;
END $$;

-- Partition routing: the event must live in the month partition, not DEFAULT.
DO $$
DECLARE part TEXT;
BEGIN
    SELECT tableoid::regclass::text INTO part
      FROM routing.routing_events WHERE request_id = 'req_1';
    IF part = 'routing.routing_events_default' THEN
        RAISE EXCEPTION 'event landed in the DEFAULT partition; monthly partition is missing';
    END IF;
    RAISE NOTICE 'ok   routing_events partition routing (landed in %)', part;
END $$;

SELECT 'ALL SCHEMA CONSTRAINT TESTS PASSED' AS result;
