-- =============================================================================
-- 0001_routing_phase0_core.up.sql
--
-- Phase 0 core tables for the Tomverse multi-provider routing control plane.
-- Baseline: docs/adr/0001-tomverse-routing-v2.1.md
--
-- Scope (ADR §16 Phase 0, items 1-6):
--   control_plane_versions      §13, §2.1, §15.4   (N10)
--   pricing_snapshots           §13
--   workspace_routing_policies  §13, §3.5, §8.4    (N6, N7)
--   routing_events              §13, §15.1         (N1, N2, N5, N11)
--   routing_attempts            §10.3, §11, §6.4   (N3, N8)
--
-- Deliberately NOT in this migration:
--   - provider adapter, penalty/softmax allocation (ADR Phase 1 / 2A)
--   - registry tables (models, providers, deployments)
--   - routing_weight_configs, routing_anchor_configs
--   - deployment_health_metrics, credential_capacity_state,
--     quality_drift_metrics, workload_output_stats
--   - workspace_provider_credentials
--   See migrations/README.md "Known gaps" for the follow-up migration plan.
-- =============================================================================

BEGIN;

CREATE SCHEMA IF NOT EXISTS routing;

COMMENT ON SCHEMA routing IS
    'Tomverse routing control plane. Baseline: docs/adr/0001-tomverse-routing-v2.1.md';

-- -----------------------------------------------------------------------------
-- Enum types
--
-- Native enums (not TEXT + CHECK) because the ADR is a frozen baseline and these
-- are closed sets. Additive evolution uses ALTER TYPE ... ADD VALUE; the new
-- value is not usable in the same transaction that adds it.
-- -----------------------------------------------------------------------------

CREATE TYPE routing.control_plane_status AS ENUM (
    'draft', 'shadow', 'canary', 'active', 'retired'
);

CREATE TYPE routing.routing_mode AS ENUM (
    'balanced', 'lowest_cost', 'lowest_latency', 'highest_availability'
);

CREATE TYPE routing.workload_class AS ENUM (
    'interactive_chat',
    'agent_tool_loop',
    'background_summary',
    'batch_offline',
    'long_context_analysis',
    'vision_or_audio'
);

CREATE TYPE routing.allocation_mode AS ENUM (
    'sequential', 'shadow', 'canary', 'active'
);

CREATE TYPE routing.seed_scope AS ENUM ('session', 'request');

CREATE TYPE routing.pin_scope AS ENUM ('provider', 'deployment');

CREATE TYPE routing.pin_fallback_policy AS ENUM ('error', 'allow');

CREATE TYPE routing.pricing_mode AS ENUM ('standard', 'batch', 'flex', 'priority');

CREATE TYPE routing.selection_reason AS ENUM (
    'sequential_priority',   -- Phase 1: static ordered fallback
    'session_affinity',      -- ADR §4.1  stateful seed resolved to the affine deployment
    'penalty_best',          -- ADR §5.1  argmin of routing_penalty
    'softmax_allocation',    -- ADR §8.2  sampled from the near-best set
    'exploration',           -- ADR §8.3  bounded explore budget
    'saturation_fallback',   -- ADR §5.4  raw_penalty used as secondary signal
    'pinned',                -- ADR §3.5  hard override
    'no_candidate'           -- every candidate rejected by a hard gate
);

-- ADR §11. NULL failure_class means the attempt succeeded.
-- Note that a safety refusal is a VALID response (ADR §11.2) and is therefore
-- recorded with failure_class = NULL, never as a failure.
CREATE TYPE routing.failure_class AS ENUM (
    'capacity_429',               -- §7.1  quota/admission. NOT a breaker input.
    'availability_5xx',           -- §7.2  breaker input
    'connection_error',           -- §7.2  breaker input
    'precommit_timeout',          -- §7.2  breaker input
    'protocol_corruption',        -- §7.3  breaker input
    'client_error',               -- 400 / unsupported request
    'capability_mismatch',        -- adapter or gate defect
    'auth_billing',               -- 401 / 403 / billing
    'malformed_output',           -- §11.1 HTTP 200 with unusable body
    'post_commit_stream_failure', -- §10.1 no automatic reroute
    'deadline_exceeded',          -- R3    request_deadline_ms exhausted
    'cancelled'                   -- client disconnected / aborted
);

-- =============================================================================
-- control_plane_versions  (ADR §13, §2.1, §15.4 — closes N10)
--
-- One immutable manifest pinning every child config version a request may use.
-- A request resolves exactly one of these rows and never mixes versions.
-- =============================================================================

CREATE TABLE routing.control_plane_versions (
    id                          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

    provider_registry_version   BIGINT NOT NULL,
    deployment_registry_version BIGINT NOT NULL,
    routing_weights_version     BIGINT NOT NULL,
    routing_anchors_version     BIGINT NOT NULL,
    pricing_catalog_version     BIGINT NOT NULL,
    quality_policy_version      BIGINT NOT NULL,
    version_policy_version      BIGINT NOT NULL,

    status                      routing.control_plane_status NOT NULL DEFAULT 'draft',

    notes                       TEXT,
    created_by                  TEXT,
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
    activated_at                TIMESTAMPTZ,
    retired_at                  TIMESTAMPTZ,

    CONSTRAINT control_plane_versions_active_needs_ts
        CHECK (status <> 'active'  OR activated_at IS NOT NULL),
    CONSTRAINT control_plane_versions_retired_needs_ts
        CHECK (status <> 'retired' OR retired_at IS NOT NULL)
);

-- Atomic active pointer (ADR §13): at most one row may be 'active'.
-- Promotion demotes the incumbent and promotes the successor in one transaction.
CREATE UNIQUE INDEX control_plane_versions_one_active_idx
    ON routing.control_plane_versions ((true))
    WHERE status = 'active';

CREATE INDEX control_plane_versions_status_idx
    ON routing.control_plane_versions (status, created_at DESC);

-- ADR §15.4: "해당 manifest가 참조하는 child config version은 immutable".
-- Enforced in the database so a hotfix cannot silently retarget a manifest that
-- past routing_events already reference.
CREATE FUNCTION routing.control_plane_versions_freeze()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF  NEW.provider_registry_version   IS DISTINCT FROM OLD.provider_registry_version
     OR NEW.deployment_registry_version IS DISTINCT FROM OLD.deployment_registry_version
     OR NEW.routing_weights_version     IS DISTINCT FROM OLD.routing_weights_version
     OR NEW.routing_anchors_version     IS DISTINCT FROM OLD.routing_anchors_version
     OR NEW.pricing_catalog_version     IS DISTINCT FROM OLD.pricing_catalog_version
     OR NEW.quality_policy_version      IS DISTINCT FROM OLD.quality_policy_version
     OR NEW.version_policy_version      IS DISTINCT FROM OLD.version_policy_version
    THEN
        RAISE EXCEPTION
            'control_plane_versions(id=%) child versions are immutable; create a new manifest instead',
            OLD.id
            USING ERRCODE = 'restrict_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER control_plane_versions_freeze_trg
    BEFORE UPDATE ON routing.control_plane_versions
    FOR EACH ROW EXECUTE FUNCTION routing.control_plane_versions_freeze();

COMMENT ON TABLE routing.control_plane_versions IS
    'ADR §13/§2.1/§15.4. Immutable manifest of child config versions. A request '
    'pins exactly one of these; child version columns cannot be updated.';
COMMENT ON COLUMN routing.control_plane_versions.status IS
    'ADR §15.5 promotion path: draft -> shadow -> canary -> active -> retired.';

-- =============================================================================
-- pricing_snapshots  (ADR §13)
--
-- Versioned, timestamped prices so historical COGS stays reproducible even
-- after a provider changes its rate card.
-- =============================================================================

CREATE TABLE routing.pricing_snapshots (
    id                      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    pricing_catalog_version BIGINT NOT NULL,

    -- FK deferred: routing.deployments arrives with the registry migration.
    deployment_id           TEXT NOT NULL,

    input_per_1m            NUMERIC(20, 10) NOT NULL,
    cached_input_per_1m     NUMERIC(20, 10),
    output_per_1m           NUMERIC(20, 10) NOT NULL,

    modality_pricing        JSONB NOT NULL DEFAULT '{}'::jsonb,
    fixed_fees              JSONB NOT NULL DEFAULT '{}'::jsonb,

    pricing_mode            routing.pricing_mode NOT NULL DEFAULT 'standard',
    currency                CHAR(3) NOT NULL DEFAULT 'USD',

    effective_from          TIMESTAMPTZ NOT NULL,
    effective_to            TIMESTAMPTZ,
    captured_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    source_url              TEXT,

    CONSTRAINT pricing_snapshots_catalog_deployment_mode_uniq
        UNIQUE (pricing_catalog_version, deployment_id, pricing_mode),

    CONSTRAINT pricing_snapshots_input_nonneg  CHECK (input_per_1m  >= 0),
    CONSTRAINT pricing_snapshots_output_nonneg CHECK (output_per_1m >= 0),
    CONSTRAINT pricing_snapshots_cached_nonneg
        CHECK (cached_input_per_1m IS NULL OR cached_input_per_1m >= 0),
    -- A cached-input rate above the uncached rate would make expected_cache_savings
    -- (ADR §6.3) negative, which the estimator has no meaning for.
    CONSTRAINT pricing_snapshots_cached_not_above_input
        CHECK (cached_input_per_1m IS NULL OR cached_input_per_1m <= input_per_1m),
    CONSTRAINT pricing_snapshots_range
        CHECK (effective_to IS NULL OR effective_to > effective_from),
    CONSTRAINT pricing_snapshots_modality_is_object
        CHECK (jsonb_typeof(modality_pricing) = 'object'),
    CONSTRAINT pricing_snapshots_fees_is_object
        CHECK (jsonb_typeof(fixed_fees) = 'object'),
    CONSTRAINT pricing_snapshots_currency_iso
        CHECK (currency ~ '^[A-Z]{3}$')
);

CREATE INDEX pricing_snapshots_deployment_idx
    ON routing.pricing_snapshots (deployment_id, effective_from DESC);
CREATE INDEX pricing_snapshots_catalog_idx
    ON routing.pricing_snapshots (pricing_catalog_version);

-- A snapshot is a record of what a price WAS. Only effective_to may be set later,
-- when a successor snapshot closes the interval.
CREATE FUNCTION routing.pricing_snapshots_freeze()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF  NEW.pricing_catalog_version IS DISTINCT FROM OLD.pricing_catalog_version
     OR NEW.deployment_id           IS DISTINCT FROM OLD.deployment_id
     OR NEW.input_per_1m            IS DISTINCT FROM OLD.input_per_1m
     OR NEW.cached_input_per_1m     IS DISTINCT FROM OLD.cached_input_per_1m
     OR NEW.output_per_1m           IS DISTINCT FROM OLD.output_per_1m
     OR NEW.modality_pricing        IS DISTINCT FROM OLD.modality_pricing
     OR NEW.fixed_fees              IS DISTINCT FROM OLD.fixed_fees
     OR NEW.pricing_mode            IS DISTINCT FROM OLD.pricing_mode
     OR NEW.currency                IS DISTINCT FROM OLD.currency
     OR NEW.effective_from          IS DISTINCT FROM OLD.effective_from
     OR NEW.captured_at             IS DISTINCT FROM OLD.captured_at
    THEN
        RAISE EXCEPTION
            'pricing_snapshots(id=%) is immutable except effective_to; insert a new snapshot instead',
            OLD.id
            USING ERRCODE = 'restrict_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER pricing_snapshots_freeze_trg
    BEFORE UPDATE ON routing.pricing_snapshots
    FOR EACH ROW EXECUTE FUNCTION routing.pricing_snapshots_freeze();

COMMENT ON TABLE routing.pricing_snapshots IS
    'ADR §13. Versioned price records. Write path exists from Phase 0 so that '
    'routing_events logged before dynamic scoring still have reproducible COGS.';

-- =============================================================================
-- workspace_routing_policies  (ADR §13, §3.5, §8.4 — closes N6, N7)
--
-- Append-only, versioned. A request freezes (workspace_id, version) at start.
-- =============================================================================

CREATE TABLE routing.workspace_routing_policies (
    workspace_id                     TEXT   NOT NULL,
    version                          BIGINT NOT NULL,

    routing_mode                     routing.routing_mode NOT NULL DEFAULT 'balanced',

    -- ADR §8.4 (N7): exploration opt-out and ceilings.
    allow_exploration                BOOLEAN NOT NULL DEFAULT true,
    explore_max_penalty_delta        NUMERIC(10, 6),
    explore_max_cost_multiplier      NUMERIC(10, 6),
    explore_max_estimated_cost_delta NUMERIC(20, 10),
    explore_latency_ceiling_ms       INTEGER,

    -- ADR §3.4 data governance gate inputs owned by the workspace.
    allowed_regions                  TEXT[] NOT NULL DEFAULT '{}',
    retention_policy                 TEXT,
    max_retention_days               INTEGER,

    -- ADR §3.5 (N6): pin is a hard override, not a routing mode.
    pin_scope                        routing.pin_scope,
    pinned_provider_id               TEXT,
    pinned_deployment_id             TEXT,
    pin_fallback_policy              routing.pin_fallback_policy NOT NULL DEFAULT 'error',

    budget_policy                    JSONB NOT NULL DEFAULT '{}'::jsonb,

    created_by                       TEXT,
    created_at                       TIMESTAMPTZ NOT NULL DEFAULT now(),

    PRIMARY KEY (workspace_id, version),

    -- pin_scope determines exactly which target column must be populated.
    CONSTRAINT workspace_routing_policies_pin_target_chk CHECK (
           (pin_scope IS NULL
                AND pinned_provider_id   IS NULL
                AND pinned_deployment_id IS NULL)
        OR (pin_scope = 'provider'
                AND pinned_provider_id   IS NOT NULL
                AND pinned_deployment_id IS NULL)
        OR (pin_scope = 'deployment'
                AND pinned_deployment_id IS NOT NULL
                AND pinned_provider_id   IS NULL)
    ),
    -- ADR §3.5: "provider/deployment pin이면 explore 금지".
    CONSTRAINT workspace_routing_policies_pin_no_explore_chk
        CHECK (pin_scope IS NULL OR allow_exploration = false),

    CONSTRAINT workspace_routing_policies_budget_is_object
        CHECK (jsonb_typeof(budget_policy) = 'object'),
    CONSTRAINT workspace_routing_policies_retention_nonneg
        CHECK (max_retention_days IS NULL OR max_retention_days >= 0),
    CONSTRAINT workspace_routing_policies_explore_ceilings_nonneg CHECK (
            (explore_max_penalty_delta        IS NULL OR explore_max_penalty_delta        >= 0)
        AND (explore_max_cost_multiplier      IS NULL OR explore_max_cost_multiplier      >= 1)
        AND (explore_max_estimated_cost_delta IS NULL OR explore_max_estimated_cost_delta >= 0)
        AND (explore_latency_ceiling_ms       IS NULL OR explore_latency_ceiling_ms       >  0)
    )
);

CREATE INDEX workspace_routing_policies_latest_idx
    ON routing.workspace_routing_policies (workspace_id, version DESC);

COMMENT ON TABLE routing.workspace_routing_policies IS
    'ADR §13/§3.5/§8.4. Append-only versioned workspace policy. A request pins '
    'one version for its whole lifetime (workspace_policy_version).';
COMMENT ON COLUMN routing.workspace_routing_policies.pin_fallback_policy IS
    'ADR §3.5 (N6). Default ''error'': a pinned target that is ineligible or '
    'failing must NOT silently fall back to the general pool.';

-- =============================================================================
-- routing_events  (ADR §13, §15.1 — closes N1, N2, N5, N11)
--
-- One row per request: the frozen decision snapshot. Range-partitioned on
-- created_at because this is a high-volume append-only audit log with a
-- retention/archival requirement.
-- =============================================================================

CREATE TABLE routing.routing_events (
    request_id                    TEXT        NOT NULL,
    created_at                    TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- ADR §4.1 (N1). session_id is an internal opaque id, never a PII-bearing
    -- external identifier; conversation_id holds the external id when needed.
    session_id                    TEXT,
    conversation_id               TEXT,

    workspace_id                  TEXT NOT NULL,
    logical_model_id              TEXT NOT NULL,
    workload_class                routing.workload_class NOT NULL,
    routing_mode                  routing.routing_mode   NOT NULL,

    -- ADR §2.1/§15.4 (N10). Exactly one manifest per request.
    control_plane_version         BIGINT NOT NULL,
    workspace_policy_version      BIGINT NOT NULL,
    resolved_config_versions      JSONB  NOT NULL DEFAULT '{}'::jsonb,

    -- ADR §13 (N2). Canonical frozen record of every candidate: gate result and
    -- reasons, raw and capped ratios, penalties, softmax weight. Rejected
    -- candidates are included so "why was it excluded" is answerable without
    -- joining any mutable metrics table (ADR §15.1).
    candidate_evaluations         JSONB NOT NULL,

    selected_deployment_id        TEXT,
    selection_reason              routing.selection_reason,
    shadow_selected_deployment_id TEXT,
    allocation_mode               routing.allocation_mode NOT NULL,

    -- ADR §8.3 (N1). decision_seed is stored as text so any hash width or
    -- encoding replays byte-exactly.
    decision_seed                 TEXT NOT NULL,
    seed_scope                    routing.seed_scope NOT NULL,

    -- R1 (ADR appendix A). Session affinity must be a stored fact, not a value
    -- re-derived from the seed, so that "displaced by capacity pressure" is
    -- representable and does not oscillate back on the next turn.
    affinity_deployment_id        TEXT,
    affinity_epoch                INTEGER,
    affinity_displaced            BOOLEAN NOT NULL DEFAULT false,

    is_exploration                BOOLEAN NOT NULL DEFAULT false,

    estimated_output_tokens       INTEGER,
    estimated_effective_cost      NUMERIC(20, 10),

    -- ADR §5.4 (N5). Drives ROUTING_ALL_CANDIDATES_SATURATED.
    all_candidates_saturated      BOOLEAN NOT NULL DEFAULT false,

    -- R3 (ADR appendix A). Frozen per-request bounds, so a replay reproduces the
    -- same fallback budget the runtime actually had.
    max_attempts                  SMALLINT NOT NULL DEFAULT 3,
    request_deadline_ms           INTEGER,

    PRIMARY KEY (request_id, created_at),

    CONSTRAINT routing_events_candidates_is_array
        CHECK (jsonb_typeof(candidate_evaluations) = 'array'),
    CONSTRAINT routing_events_resolved_versions_is_object
        CHECK (jsonb_typeof(resolved_config_versions) = 'object'),
    -- ADR §8.3: a session-scoped seed is meaningless without a session.
    CONSTRAINT routing_events_session_seed_needs_session
        CHECK (seed_scope <> 'session' OR session_id IS NOT NULL),
    -- ADR §16 Phase 2A: a shadow pick only exists once the dynamic router runs.
    CONSTRAINT routing_events_shadow_requires_dynamic
        CHECK (allocation_mode <> 'sequential' OR shadow_selected_deployment_id IS NULL),
    -- A selection implies a reason; 'no_candidate' implies nothing was selected.
    CONSTRAINT routing_events_selection_reason_presence CHECK (
           (selected_deployment_id IS NOT NULL
                AND selection_reason IS NOT NULL
                AND selection_reason <> 'no_candidate')
        OR (selected_deployment_id IS NULL
                AND (selection_reason IS NULL OR selection_reason = 'no_candidate'))
    ),
    CONSTRAINT routing_events_exploration_requires_selection
        CHECK (is_exploration = false OR selected_deployment_id IS NOT NULL),
    CONSTRAINT routing_events_affinity_epoch_nonneg
        CHECK (affinity_epoch IS NULL OR affinity_epoch >= 0),
    CONSTRAINT routing_events_max_attempts_positive
        CHECK (max_attempts >= 1),
    CONSTRAINT routing_events_deadline_positive
        CHECK (request_deadline_ms IS NULL OR request_deadline_ms > 0),
    CONSTRAINT routing_events_estimates_nonneg CHECK (
            (estimated_output_tokens  IS NULL OR estimated_output_tokens  >= 0)
        AND (estimated_effective_cost IS NULL OR estimated_effective_cost >= 0)
    ),

    CONSTRAINT routing_events_control_plane_fk
        FOREIGN KEY (control_plane_version)
        REFERENCES routing.control_plane_versions (id),
    CONSTRAINT routing_events_workspace_policy_fk
        FOREIGN KEY (workspace_id, workspace_policy_version)
        REFERENCES routing.workspace_routing_policies (workspace_id, version)
) PARTITION BY RANGE (created_at);

COMMENT ON TABLE routing.routing_events IS
    'ADR §13/§15.1. Frozen per-request decision snapshot. Append-only; never '
    'reconstruct a past decision by joining mutable rolling metrics tables.';
COMMENT ON COLUMN routing.routing_events.candidate_evaluations IS
    'ADR §13 (N2). Canonical record (not a separate table): array of candidate '
    'objects including gate_result, gate_reasons, raw_* and capped_* ratios, '
    'routing_penalty, raw_penalty, softmax_weight, exploration_eligible. '
    'Rejected candidates are included with their rejection reasons.';
COMMENT ON COLUMN routing.routing_events.affinity_deployment_id IS
    'R1. Stored session affinity target. NULL for stateless workloads.';

-- =============================================================================
-- routing_attempts  (ADR §10.3, §11, §6.4 — closes N3, N8)
--
-- One row per upstream attempt. Failed attempts can still be billed, so COGS is
-- summed here, never at request level (ADR §10.3).
-- =============================================================================

CREATE TABLE routing.routing_attempts (
    request_id                TEXT        NOT NULL,
    attempt_number            SMALLINT    NOT NULL,
    created_at                TIMESTAMPTZ NOT NULL DEFAULT now(),

    deployment_id             TEXT NOT NULL,

    -- ADR §7.1/§12.3 (N3). Capacity is credential/quota scoped, so the attempt
    -- must record which credential and quota bucket it consumed.
    credential_id             TEXT,
    quota_scope_id            TEXT,

    -- Which price priced this attempt, so actual_cost stays reproducible.
    pricing_snapshot_id       BIGINT REFERENCES routing.pricing_snapshots (id),

    started_at                TIMESTAMPTZ NOT NULL,
    first_token_at            TIMESTAMPTZ,
    stream_committed_at       TIMESTAMPTZ,
    ended_at                  TIMESTAMPTZ,

    -- ADR §11. NULL = success. A safety refusal is a valid response and is
    -- recorded as success, never as a failure (ADR §11.2).
    failure_class             routing.failure_class,
    validation_error_code     TEXT,
    http_status               SMALLINT,
    finish_reason             TEXT,
    provider_request_id       TEXT,
    retry_after_ms            INTEGER,

    input_tokens              INTEGER,
    cached_input_tokens       INTEGER,
    output_tokens             INTEGER,

    -- ADR §6.4. Estimator calibration is attempt-scoped: each attempt hits a
    -- different deployment with a different price.
    estimated_output_tokens   INTEGER,
    estimated_cost            NUMERIC(20, 10),
    estimated_cache_savings   NUMERIC(20, 10),
    actual_cost               NUMERIC(20, 10),

    cost_estimation_error_abs NUMERIC(20, 10)
        GENERATED ALWAYS AS (actual_cost - estimated_cost) STORED,
    cost_estimation_error_pct NUMERIC(20, 10)
        GENERATED ALWAYS AS (
            CASE
                WHEN estimated_cost IS NULL OR estimated_cost = 0 THEN NULL
                ELSE (actual_cost - estimated_cost) / estimated_cost * 100
            END
        ) STORED,

    PRIMARY KEY (request_id, attempt_number, created_at),

    CONSTRAINT routing_attempts_number_positive
        CHECK (attempt_number >= 1),
    CONSTRAINT routing_attempts_first_token_after_start
        CHECK (first_token_at IS NULL OR first_token_at >= started_at),
    CONSTRAINT routing_attempts_ended_after_start
        CHECK (ended_at IS NULL OR ended_at >= started_at),
    -- ADR §10.1: the commit point is the first user-visible chunk flush, so it
    -- cannot precede the first token.
    CONSTRAINT routing_attempts_commit_requires_first_token
        CHECK (stream_committed_at IS NULL
               OR (first_token_at IS NOT NULL AND stream_committed_at >= first_token_at)),
    -- ADR §10.1: post-commit failure is the only failure class allowed after the
    -- commit point; everything else must have failed before it.
    CONSTRAINT routing_attempts_postcommit_class
        CHECK (stream_committed_at IS NULL
               OR failure_class IS NULL
               OR failure_class IN ('post_commit_stream_failure', 'malformed_output', 'cancelled')),
    -- ADR §7.1: Retry-After is a capacity signal and only accompanies a 429.
    CONSTRAINT routing_attempts_retry_after_only_on_429
        CHECK (retry_after_ms IS NULL OR failure_class = 'capacity_429'),
    -- ADR §11.1: validation_error_code describes an unusable body.
    CONSTRAINT routing_attempts_validation_code_scope
        CHECK (validation_error_code IS NULL
               OR failure_class IN ('malformed_output', 'client_error')),
    CONSTRAINT routing_attempts_tokens_nonneg CHECK (
            (input_tokens            IS NULL OR input_tokens            >= 0)
        AND (cached_input_tokens     IS NULL OR cached_input_tokens     >= 0)
        AND (output_tokens           IS NULL OR output_tokens           >= 0)
        AND (estimated_output_tokens IS NULL OR estimated_output_tokens >= 0)
    ),
    CONSTRAINT routing_attempts_cached_within_input
        CHECK (cached_input_tokens IS NULL
               OR input_tokens IS NULL
               OR cached_input_tokens <= input_tokens),
    CONSTRAINT routing_attempts_costs_nonneg CHECK (
            (estimated_cost          IS NULL OR estimated_cost          >= 0)
        AND (actual_cost             IS NULL OR actual_cost             >= 0)
        AND (estimated_cache_savings IS NULL OR estimated_cache_savings >= 0)
    ),
    CONSTRAINT routing_attempts_http_status_range
        CHECK (http_status IS NULL OR http_status BETWEEN 100 AND 599)
) PARTITION BY RANGE (created_at);

COMMENT ON TABLE routing.routing_attempts IS
    'ADR §10.3/§11/§6.4. One row per upstream attempt. Failed attempts are still '
    'billable, so request COGS = sum(actual_cost) over this table. No foreign key '
    'to routing_events: both are range-partitioned on created_at and an attempt '
    'may be written in a later partition than its event.';
COMMENT ON COLUMN routing.routing_attempts.failure_class IS
    'ADR §11. NULL means success. A normal safety refusal is a valid response '
    'and is stored as success (ADR §11.2) — never route around it.';

-- =============================================================================
-- Partitions
--
-- Monthly range partitions plus a DEFAULT so an insert never fails if partition
-- maintenance lapses. Automate creation (pg_partman or a scheduled job) before
-- the pre-created range runs out; see migrations/README.md.
-- =============================================================================

DO $$
DECLARE
    tbl    TEXT;
    m      DATE;
    lo     DATE;
    hi     DATE;
BEGIN
    FOREACH tbl IN ARRAY ARRAY['routing_events', 'routing_attempts'] LOOP
        EXECUTE format(
            'CREATE TABLE routing.%I_default PARTITION OF routing.%I DEFAULT',
            tbl, tbl
        );
        FOR i IN 0..11 LOOP
            m  := date_trunc('month', DATE '2026-09-01')::date + (i || ' months')::interval;
            lo := m;
            hi := (m + INTERVAL '1 month')::date;
            EXECUTE format(
                'CREATE TABLE routing.%I_%s PARTITION OF routing.%I FOR VALUES FROM (%L) TO (%L)',
                tbl, to_char(m, 'YYYYMM'), tbl, lo, hi
            );
        END LOOP;
    END LOOP;
END
$$;

-- -----------------------------------------------------------------------------
-- Indexes (created on the partitioned parents; propagate to every partition)
-- -----------------------------------------------------------------------------

CREATE INDEX routing_events_workspace_idx
    ON routing.routing_events (workspace_id, created_at DESC);
-- Session lookup drives cache-affinity estimation (ADR §6.3) and R1 hold-down.
CREATE INDEX routing_events_session_idx
    ON routing.routing_events (session_id, created_at DESC)
    WHERE session_id IS NOT NULL;
CREATE INDEX routing_events_selected_deployment_idx
    ON routing.routing_events (selected_deployment_id, created_at DESC)
    WHERE selected_deployment_id IS NOT NULL;
CREATE INDEX routing_events_control_plane_idx
    ON routing.routing_events (control_plane_version, created_at DESC);
CREATE INDEX routing_events_allocation_mode_idx
    ON routing.routing_events (allocation_mode, created_at DESC);
-- ADR §5.4 (N5): degraded-routing alerting and post-incident queries.
CREATE INDEX routing_events_saturated_idx
    ON routing.routing_events (created_at DESC)
    WHERE all_candidates_saturated;
CREATE INDEX routing_events_exploration_idx
    ON routing.routing_events (created_at DESC)
    WHERE is_exploration;
-- Counterfactual replay (ADR §15.2) filters candidates by deployment.
CREATE INDEX routing_events_candidates_gin
    ON routing.routing_events USING GIN (candidate_evaluations jsonb_path_ops);

CREATE INDEX routing_attempts_deployment_idx
    ON routing.routing_attempts (deployment_id, created_at DESC);
-- ADR §7.1 (N3): 429 pressure is analysed per credential / quota scope.
CREATE INDEX routing_attempts_credential_idx
    ON routing.routing_attempts (credential_id, created_at DESC)
    WHERE credential_id IS NOT NULL;
CREATE INDEX routing_attempts_quota_scope_idx
    ON routing.routing_attempts (quota_scope_id, created_at DESC)
    WHERE quota_scope_id IS NOT NULL;
-- ADR §7.2/§9.3: availability health and quality drift are computed from here
-- and must stay separable by failure_class.
CREATE INDEX routing_attempts_failure_idx
    ON routing.routing_attempts (failure_class, deployment_id, created_at DESC)
    WHERE failure_class IS NOT NULL;
CREATE INDEX routing_attempts_request_idx
    ON routing.routing_attempts (request_id);

-- =============================================================================
-- Helper view: request-level COGS (ADR §10.3)
-- =============================================================================

CREATE VIEW routing.request_cogs AS
SELECT
    request_id,
    min(created_at)                                        AS first_attempt_at,
    max(coalesce(ended_at, created_at))                    AS last_attempt_at,
    count(*)::int                                          AS attempt_count,
    count(*) FILTER (WHERE failure_class IS NOT NULL)::int AS failed_attempt_count,
    sum(actual_cost)                                       AS request_actual_cogs,
    sum(input_tokens)                                      AS total_input_tokens,
    sum(cached_input_tokens)                               AS total_cached_input_tokens,
    sum(output_tokens)                                     AS total_output_tokens
FROM routing.routing_attempts
GROUP BY request_id;

COMMENT ON VIEW routing.request_cogs IS
    'ADR §10.3. request_actual_cogs = sum(attempt.actual_cost), including failed '
    'attempts. User billing policy is decided separately from internal COGS.';

COMMIT;
