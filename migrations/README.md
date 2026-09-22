# Routing schema migrations

PostgreSQL DDL for the Tomverse routing control plane.
Baseline: [`docs/adr/0001-tomverse-routing-v2.1.md`](../docs/adr/0001-tomverse-routing-v2.1.md).

Migrations are plain SQL (`NNNN_name.up.sql` / `NNNN_name.down.sql`) so they can be
applied by any runner or by `psql` directly. The runtime will be TypeScript/Node;
picking a migration runner (`node-pg-migrate`, `dbmate`, Drizzle, …) is deferred
until the Phase 1 service exists — none of these files depend on that choice.

## Applying

```sh
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f migrations/0001_routing_phase0_core.up.sql
```

Each file is wrapped in a single `BEGIN`/`COMMIT`, so a failure leaves nothing behind.

## Testing

`tests/0001_constraints_test.sql` asserts that the schema actually enforces the ADR
invariants it claims to. It requires a **fresh** database (it inserts fixtures and is
not idempotent):

```sh
createdb tomverse_test
psql -d tomverse_test -v ON_ERROR_STOP=1 -f migrations/0001_routing_phase0_core.up.sql
psql -d tomverse_test -v ON_ERROR_STOP=1 -f migrations/tests/0001_constraints_test.sql
```

Verified against PostgreSQL 16.13: 33 assertions pass, and up → down → up is clean.

## 0001 — Phase 0 core

Covers ADR §16 Phase 0 items 1–6.

| Table | ADR | Closes |
|---|---|---|
| `control_plane_versions` | §13, §2.1, §15.4 | N10 |
| `pricing_snapshots` | §13 | C13 |
| `workspace_routing_policies` | §13, §3.5, §8.4 | N6, N7 |
| `routing_events` | §13, §15.1 | N1, N2, N5, N11 |
| `routing_attempts` | §10.3, §11, §6.4 | N3, N8 |

Plus `routing.request_cogs`, a view implementing ADR §10.3
(`request_actual_cogs = sum(attempt.actual_cost)`, failed attempts included).

### Design decisions

**`candidate_evaluations` is a JSONB column, not a table.** Per ADR §13 and §15.1 it
is the canonical frozen decision record: every candidate with its gate result and
reasons, raw and capped ratios, penalties and softmax weight, including candidates
rejected by a hard gate. Replay never joins a mutable rolling-metrics table to
reconstruct a past decision. A GIN index (`jsonb_path_ops`) supports counterfactual
replay queries that filter by deployment.

**Immutability is enforced by triggers, not convention.** `control_plane_versions`
child version columns and `pricing_snapshots` value columns reject `UPDATE`. Only
manifest `status`/`retired_at` and a snapshot's `effective_to` remain mutable. Without
this, a hotfix could silently retarget a manifest that past `routing_events` reference
and break ADR §15.4 reproducibility.

**At most one active manifest**, via a partial unique index on `status = 'active'`.
Promotion demotes the incumbent and promotes the successor in one transaction.

**Range partitioning on `created_at`** (monthly) for `routing_events` and
`routing_attempts`. These are high-volume append-only audit logs with a retention and
archival requirement; converting them to partitioned tables later needs a full rewrite.
Partition keys are therefore part of both primary keys.

**No foreign key from `routing_attempts` to `routing_events`.** A FK onto a partitioned
table requires the partition key in the referenced key, which would force
`(request_id, created_at)` to match exactly across the two tables — but an attempt can
be written in a later partition than its event (a request that spans midnight on the
1st). Both rows are written by the same code path; integrity is the writer's
responsibility here. `routing_attempts_request_idx` supports the join.

**Enums rather than `TEXT` + `CHECK`**, because the ADR is a frozen baseline and these
are closed sets. Additive evolution uses `ALTER TYPE … ADD VALUE`; note the new value
cannot be used in the same transaction that adds it.

**`decision_seed` is `TEXT`**, so any hash width or encoding replays byte-exactly
(ADR §8.3).

### Fields added beyond the ADR §13 column lists

These come from the v2.1 review items recorded in ADR appendix A, and are additive —
they record facts the runtime already has.

| Field | Table | Why |
|---|---|---|
| `affinity_deployment_id`, `affinity_epoch`, `affinity_displaced` | `routing_events` | **R1.** Session affinity must be a stored fact, not a value re-derived from the seed, or "displaced by capacity pressure" is unrepresentable and the session oscillates back on the next turn. |
| `max_attempts`, `request_deadline_ms` | `routing_events` | **R3.** Freezes the fallback budget the runtime actually had, so replay reproduces it. |
| `selection_reason`, `is_exploration` | `routing_events` | Separates exploration traffic from the primary path in analysis, and makes "why this deployment" answerable without re-deriving the decision. |
| `quota_scope_id` | `routing_attempts` | **N3.** Capacity is credential/quota-scoped; the attempt must record which bucket it consumed. |
| `pricing_snapshot_id` | `routing_attempts` | Keeps `actual_cost` reproducible after a rate-card change. |
| estimator calibration columns | `routing_attempts` | ADR §6.4 specifies these as attempt-scoped; the §13 column list omits them. `cost_estimation_error_abs`/`_pct` are `GENERATED … STORED`. |
| `explore_*` ceilings | `workspace_routing_policies` | **N7.** ADR §8.4 defines the ceilings but the §13 column list omits them. |

## Known gaps

These are deliberate and tracked, not oversights.

1. **No FK on `deployment_id`, `provider_id`, `logical_model_id`, `workspace_id`,
   `credential_id`.** The registry tables (`models`, `providers`, `deployments`,
   `workspace_provider_credentials`) land in `0002`. Add the constraints there.
2. **`pricing_catalog_version` has no owning table**, so nothing yet prevents a
   manifest referencing a catalog version that does not exist. The child-version
   registries (`routing_weight_configs`, `routing_anchor_configs`, pricing catalog,
   quality policy, version policy) should land together in `0002` and gain FKs from
   `control_plane_versions` at that point.
3. **Partition maintenance is not automated.** `0001` pre-creates 12 monthly
   partitions (2026-09 … 2027-08) plus a `DEFAULT` partition as a safety net, so an
   insert never fails if maintenance lapses. Schedule partition creation (pg_partman
   or a cron job) before the pre-created range runs out. Rows that land in `DEFAULT`
   block later creation of the partition covering their range.
4. **`w_cost + w_latency + w_health = 1.0` is not validated** (R5). It belongs on
   `routing_weight_configs`, which is not in this migration.
5. **Retention/archival policy is undefined.** Partitioning makes `DETACH` + archive
   cheap, but nobody has decided how long `routing_events` is kept — and ADR §12.4
   residency rules apply to this data too.
