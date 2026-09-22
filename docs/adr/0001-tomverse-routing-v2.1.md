# Tomverse 멀티 공급자 라우팅 아키텍처 결정서 v2.1

- **상태**: 구현 기준선 (implementation baseline)
- **작성일**: 2026-09-22
- **대체 관계**: v1.0, v2.0은 superseded. 구현은 이 문서만 기준으로 합니다.
- **핵심**: Session-aware Allocation · Atomic Control Plane · Quality Drift · Multi-Provider Reliability · Replay / Shadow / Canary

---

## 0. 개정 이력 요약

v1.0 리뷰에서 C1–C15, v2.0 리뷰에서 N1–N11이 제기되어 반영되었습니다.

### v2.0 → v2.1 (N1–N11)

| ID | v2.0 문제 | v2.1 결정 |
|---|---|---|
| N1 | request 단위 softmax seed가 cache affinity를 깨뜨림 | stateful workload는 session seed, stateless는 request seed. `session_id`/`conversation_id`를 이벤트에 기록 |
| N2 | `health_snapshot_id`가 가리킬 immutable snapshot이 없음 | `candidate_evaluations JSONB`에 gate 결과 + raw/derived penalty + allocation weight를 동결 기록 |
| N3 | 429/capacity가 deployment 단위여서 BYOK 격리 실패 | capacity/admission은 `(deployment_id, credential_id)` 또는 quota scope 단위, availability health는 deployment 단위 |
| N4 | anchor 자동 재도출 시 feedback loop 가능 | `anchor_source = manual \| reference_deployment \| derived`. derived는 자동 활성화 금지 |
| N5 | ratio cap 포화 시 모든 후보 판별력 상실 | capped penalty 유지 + raw penalty 보조 정렬 + `ALL_CANDIDATES_SATURATED` alert |
| N6 | provider pin 의미론 미정의 | pin은 hard gate/override, `explore_rate=0`. 기본 pin 실패 시 silent fallback 금지 |
| N7 | explore traffic 비용/SLA 상한 없음 | `allow_exploration`, `explore_max_penalty_delta`, cost/latency ceiling 추가 |
| N8 | HTTP 200이지만 깨진 출력 분류 없음 | `malformed_output` 신설. pre-commit 동일 deployment 1회 retry, quality drift 입력 |
| N9 | quality gate가 1회성 | `stale` 상태, `gate_expires_at`, 주기적 재게이트 + drift-triggered 재검증 |
| N10 | 여러 config를 비원자적으로 읽으면 존재한 적 없는 조합 가능 | 단일 `control_plane_version` immutable manifest로 하위 config를 원자 고정 |
| N11 | softmax 최초 활성화에 안전한 전환 경로 없음 | shadow → canary → active 단계. shadow에서는 계산만 하고 Phase 1 sequential 경로 실행 |

### v2.0에서 유지되는 필수 원칙

- 목적함수는 `routing_penalty` **최소화**
- 후보군 min-max가 아닌 **fixed-anchor** 정규화
- request 시점의 output 길이를 telemetry로 추정
- cache savings를 effective cost **내부**에 반영
- 429는 quota/admission, 5xx/timeout은 availability/circuit breaker
- quality/quantization 및 model version hard gate
- 첫 user-visible chunk를 streaming commit point로 정의
- attempt-level COGS ledger
- OpenRouter emergency fallback에서 이미 실패한 provider 제외
- deterministic replay + fault injection을 구현 초기에 확보

---

## 1. 아키텍처 결정 요약

Tomverse는 사용자가 선택하는 **Logical Model**과 실제 호출되는 **Deployment**를 분리합니다. 요청 처리는 아래 여섯 계층으로 나눕니다.

1. **Atomic Config Resolve** — 요청 시작 시 하나의 `control_plane_version`과 workspace policy version을 고정
2. **Hard Gates** — capability, quality, version, residency, credential, provider/deployment pin
3. **Capacity + Health** — credential-scoped capacity와 deployment-scoped availability를 분리
4. **Economic Prediction** — expected output, cache affinity, pricing을 포함한 request-level effective cost
5. **Traffic Allocation** — fixed-anchor penalty + session-aware allocation + bounded exploration
6. **Execution Contract** — streaming commit, failure taxonomy, attempt ledger, replayable audit log

### 확정 Provider Pool

| 모델 계열 | Provider Pool |
|---|---|
| OpenAI-compatible / Open-weight | 모델 벤더 Direct, DeepInfra, Sail Research, Together, OpenRouter |
| Claude | Anthropic Direct, DeepInfra, Google Vertex AI |
| Gemini | Google Gemini API, Google Vertex AI, DeepInfra |
| OpenAI | OpenAI Direct, Azure OpenAI |

**OpenRouter 역할**: OpenAI-compatible 계열의 최종 emergency fallback. 이전 attempt에서 실패한 provider를 가능한 범위에서 `ignore` 또는 동등 exclusion으로 전달합니다.

---

## 2. 전체 시스템 구조

### 2.1 Runtime plane과 control plane

- **Runtime plane**: 한 요청에서 resolve → gate → estimate → allocate → attempt → fallback을 수행합니다.
- **Control plane**: provider registry, pricing catalog, anchors, weights, quality rules, version pins를 immutable manifest로 묶습니다.
- 요청이 시작되면 active manifest를 **한 번만** 읽고 `control_plane_version`을 고정합니다. 요청 중간에 config가 승격되어도 해당 요청의 결정에는 섞이지 않습니다.
- workspace policy도 동일 DB transaction/consistent read 안에서 한 버전을 고정하여 `workspace_policy_version`으로 기록합니다.

---

## 3. 라우팅 불변조건과 Hard Gates

Penalty 계산 **전에** 적용합니다. 하나라도 실패하면 해당 deployment는 후보가 아닙니다.

### 3.1 Capability gate

- `max_context`, `max_output_tokens`
- tools / parallel tool calls
- streaming / streaming + tools 동시 지원
- structured output: `none | json_mode | strict_schema`
- input/output image
- input/output audio
- provider별 quirks

### 3.2 Quality equivalence gate

```
required_quality_tier == deployment.quality_tier
AND deployment.quality_gate_status == "passed"
AND now < deployment.quality_gate_expires_at
```

최소 metadata: `quality_tier`, `quantization`, `tokenizer_revision`, `quality_benchmark_version`, `quality_gate_status = pending | passed | failed | stale`, `quality_gate_expires_at`, `quality_last_verified_at`.

`stale`은 기본적으로 production ineligible입니다. 긴급 운영 override는 별도 감사 로그를 남깁니다.

### 3.3 Model version gate

- deployment별 `model_version` 또는 immutable revision pin
- `allow_version_drift = false` 기본
- `version_pin_strength = strong | weak | alias_only`
- 같은 equivalence group에서만 자동 fallback

### 3.4 Data governance gate

```
provider.data_processing_policy
+ deployment.endpoint_region
+ deployment.retention_policy
+ workspace.data_policy
+ credential_scope
```

### 3.5 Provider / Deployment Pin hard gate

Pin은 routing mode가 아니라 **hard override**입니다.

- `pin_scope = provider | deployment`
- pin이 있으면 후보 집합을 pin target으로 제한
- `explore_rate = 0`
- capability/quality/version/residency/credential gate는 pin에도 그대로 적용
- 기본 `pin_fallback_policy = error` — pin target이 ineligible/실패했다고 다른 provider로 몰래 이동하지 않음
- 명시적 `pin_fallback_policy = allow`인 경우에만 일반 pool로 fallback

이 의미론으로 "Pinned Provider" 고객이 탐색 트래픽 때문에 다른 provider로 전송되는 일을 방지합니다.

---

## 4. 요청별 라우팅 결정 흐름

### 4.1 Workload class와 seed policy

| Workload | Allocation seed | Cache affinity |
|---|---|---|
| `interactive_chat` | `hash(session_id + control_plane_version + allocation_salt)` | 세션 동안 안정적으로 유지 |
| `agent_tool_loop` | `hash(session_id + control_plane_version + allocation_salt)` | tool loop가 같은 deployment에 붙도록 함 |
| `background_summary` | `hash(request_id + control_plane_version)` | stateless |
| `batch_offline` | `hash(request_id + control_plane_version)` | stateless |
| `long_context_analysis` | session이 있으면 session seed, 없으면 request seed | 비용/캐시 정책에 따라 |
| `vision_or_audio` | session 유무에 따라 위 규칙 적용 | capability gate 우선 |

`session_id`는 **내부 opaque ID**를 사용합니다. 필요하면 외부 conversation ID는 별도 `conversation_id`로 보관하며, PII가 들어간 원문 식별자는 사용하지 않습니다.

### 4.2 Exploration cohort도 session-aware

Stateful workload에서 explore 여부까지 request별로 다시 추첨하면 cache가 다시 깨집니다.

```
explore_cohort_seed = hash(session_id + control_plane_version + "explore")
```

- 한 세션이 exploration cohort에 들어가면 그 세션 동안 **동일 exploratory deployment**에 유지
- stateless workload는 request 단위 exploration 가능
- control-plane version이 바뀌면 새로운 cohort가 될 수 있으나, 이미 진행 중인 장기 세션에 대해서는 optional `affinity_epoch`를 별도로 고정할 수 있음

---

## 5. Penalty 함수, Anchor, Saturation

### 5.1 목적함수

```
routing_penalty =
      w_cost    * capped_cost_ratio
    + w_latency * capped_latency_ratio
    + w_health  * capped_failure_risk_ratio
    + explicit_penalties

LOWER IS BETTER
```

동시에 디버깅/포화 처리용으로 cap 전 값을 보존합니다.

```
raw_penalty =
      w_cost    * raw_cost_ratio
    + w_latency * raw_latency_ratio
    + w_health  * raw_failure_risk_ratio
    + explicit_penalties
```

### 5.2 Fixed-anchor ratio

```
raw_cost_ratio         = estimated_effective_cost / cost_anchor
raw_latency_ratio      = predicted_latency        / latency_slo_anchor
raw_failure_risk_ratio = predicted_failure_risk   / failure_risk_anchor
capped_*_ratio         = clamp(raw_*_ratio, 0, ratio_cap)
```

**후보군 min-max 정규화는 금지합니다.**

### 5.3 Anchor source와 승격

`routing_anchor_configs`는 `anchor_source = manual | reference_deployment | derived`를 명시합니다.

- `manual` — 사업/SLO 목표를 사람이 설정. **기본 권장**
- `reference_deployment` — 특정 Direct/reference deployment의 버전된 가격/SLO snapshot을 기준으로 사용
- `derived` — telemetry로 계산된 제안값. **자동 production 활성화 금지**

derived anchor는 Draft → Offline Replay → Shadow/Canary → Production 승격 절차를 거칩니다. 라우팅된 실트래픽의 평균값이 active anchor를 자동으로 밀어내는 피드백 루프를 허용하지 않습니다.

### 5.4 Saturation 처리

`ratio_cap`은 정상 상태에서 outlier가 목적함수를 지배하지 않도록 유지합니다. 그러나 모든 후보가 cap에 붙으면 capped penalty만으로는 판별력이 사라집니다.

1. 각 후보의 `raw_*_ratio`와 `raw_penalty`를 **항상** 기록
2. `all_candidates_saturated` 조건을 탐지하고 alert 발생
3. 정상 상태에서는 capped `routing_penalty`로 near-best 계산
4. near-best의 penalty가 cap 때문에 동률/근접 동률이면 `raw_penalty`를 secondary ordering/allocation signal로 사용
5. 포화 상태에서는 **exploration을 일시 중단**하고 degraded-routing event를 남김

운영 alert: `ROUTING_ALL_CANDIDATES_SATURATED` — 단순 라우팅 문제가 아니라 가격 급등, 전체 latency 악화, widespread provider incident 가능성을 의미합니다.

### 5.5 초기 모드별 가중치

| 모드 | Cost | Latency | Failure Risk | 비고 |
|---|---|---|---|---|
| Balanced | 0.35 | 0.25 | 0.40 | 기본 |
| Lowest Cost | 0.60 | 0.10 | 0.30 | 품질/버전 hard gate 유지 |
| Lowest Latency | 0.15 | 0.55 | 0.30 | interactive 중심 |
| Highest Availability | 0.10 | 0.15 | 0.75 | failure-domain penalty 추가 가능 |

Pin은 이 모드와 별개의 hard override입니다.

---

## 6. Request-level Effective Cost와 Cache Affinity

### 6.1 Output 길이 추정

```
output_tokens_distribution(
    logical_model_id,
    workload_class,
    max_output_bucket,
    optional_feature_bucket
)
```

최소 저장값: rolling `p50`, `p75`, `p95`, EWMA mean, sample count, `last_updated_at`.

### 6.2 예상 원가

```
estimated_cost_without_cache =
      uncached_input_tokens       * input_price
    + expected_cached_input_tokens * cached_input_price
    + expected_output_tokens       * output_price
    + modality_charges
    + request_fixed_fees
    + aggregator_or_credit_fees
```

### 6.3 Session-aware cache savings

```
expected_cache_savings =
      P(cache_hit | session_id, deployment_id)
    * reusable_input_tokens
    * (uncached_input_price - cached_input_price)

estimated_effective_cost =
      estimated_cost_without_cache - expected_cache_savings
```

핵심은 **estimator와 allocator가 같은 affinity 단위를 사용하는 것**입니다. `interactive_chat`과 `agent_tool_loop`는 session seed를 사용하므로 한 deployment에서 cache가 실제로 warm될 기회를 갖습니다.

`P(cache_hit | session, deployment)` 추정 신호:

- 해당 session의 직전 successful deployment
- provider cache identifier/prefix cache signal
- reusable prefix token 추정량
- deployment 변경 이후 경과 턴 수
- 실제 cached input token 비율 telemetry

### 6.4 Estimator calibration

Attempt마다 기록: `estimated_output_tokens`, `actual_output_tokens`, `estimated_cost`, `actual_cost`, `estimated_cache_savings`, `actual_cached_input_tokens`, `cost_estimation_error_abs`, `cost_estimation_error_pct`.

`(model, workload, deployment)`별 calibration drift를 추적합니다.

---

## 7. Capacity와 Health는 서로 다른 Key Scope를 사용

### 7.1 Credential-scoped capacity/admission

429, local token bucket, concurrency quota는 다음 key로 관리합니다.

```
(deployment_id, credential_id)
```

Provider가 project/org 단위로 quota를 공유한다면 credential metadata의 `quota_scope_id`를 사용하여 실제 shared bucket을 표현합니다.

관리 대상: `rate_429`, `retry_after_until`, `local_token_bucket`, `concurrency_limit`, `concurrency_in_use`, `deprioritize_until`, `quota_scope_id`.

따라서 한 workspace BYOK가 포화되어도 Tomverse-managed credential이나 다른 BYOK workspace의 동일 deployment를 전체적으로 강등하지 않습니다.

### 7.2 Deployment-scoped availability health

5xx, connection reset, DNS/TLS, pre-commit timeout은 실제 serving deployment의 공유 인프라 문제이므로 deployment 단위로 관리합니다.

```
raw_failure_risk =
      (1.0*N_5xx + 1.2*N_timeout + 1.0*N_connection_error)
    / max(N_eligible_attempts, 1)

shrunk_failure_risk =
      (n_eff * raw_failure_risk + k * prior_failure_risk)
    / (n_eff + k)
```

예시 prior: `prior_failure_risk = 0.005`, `k = 200` equivalent samples.

**429와 `malformed_output`은 이 availability failure risk에 섞지 않습니다.**

### 7.3 Circuit breaker

Breaker 대상: 5xx, connection/reset/DNS/TLS failure, pre-commit timeout, transport/protocol corruption.

`malformed_output`은 quality drift signal이며 기본 availability breaker 대상이 아닙니다.

상태: `CLOSED -> OPEN -> HALF_OPEN -> CLOSED`

---

## 8. Traffic Allocation: Session Affinity, Herding 방지, Bounded Exploration

### 8.1 Near-best set

```
near_best = deployments where
    routing_penalty <= best_penalty + near_best_delta
```

### 8.2 Softmax allocation

```
weight_i = exp(-allocation_penalty_i / temperature)
         / sum_j exp(-allocation_penalty_j / temperature)
```

`allocation_penalty_i`는 보통 capped `routing_penalty`이며, cap 포화로 판별력이 사라진 경우 raw penalty 기반 secondary signal을 사용합니다.

### 8.3 Seed 규칙

- **stateful**: `hash(session_id + control_plane_version + allocation_salt)`
- **stateless**: `hash(request_id + control_plane_version)`
- event에는 `decision_seed`, `seed_scope = session | request`, `session_id`를 기록

이로써 replay 결정론과 cache affinity를 동시에 보장합니다.

### 8.4 Explore budget 안전장치

Exploration은 hard gate를 통과한 deployment만 대상으로 하며 다음을 **모두** 만족해야 합니다.

```
workspace.allow_exploration == true
AND request.routing.allow_exploration != false
AND candidate.routing_penalty   <= best_penalty + explore_max_penalty_delta
AND candidate.estimated_cost    <= best_estimated_cost * explore_max_cost_multiplier
AND candidate.predicted_latency <= explore_latency_ceiling
```

추가 규칙:

- provider/deployment pin이면 explore 금지
- SLA workspace는 기본 `allow_exploration=false`로 설정 가능
- `long_context_analysis`처럼 절대 비용이 큰 workload는 `explore_max_estimated_cost_delta`도 설정 가능
- stateful workload는 session exploration cohort로 배정하여 턴별 provider split을 금지
- quality tier/version/data policy는 exploration에서도 **절대 우회하지 않음**

### 8.5 Load guard

Softmax 전/후 credential capacity와 deployment load 신호를 확인합니다. 순간 포화는 weight 감쇠로 처리하며, 전체 트래픽을 한 번에 다음 provider로 이동시키지 않습니다.

---

## 9. 품질 등가성, Drift 감지, 재게이트

### 9.1 Production quality gate

| 지표 | 역할 |
|---|---|
| Structured format pass | JSON/schema 준수 |
| Tool-call exactness | tool name/args 정확도 |
| Representative task pass | workload별 품질 parity |
| Tokenizer/stop parity | truncation/stop mismatch 탐지 |
| Streaming/protocol validity | chunk/event contract 준수 |

### 9.2 Gate expiry

`quality_gate_status: pending | passed | failed | stale`

필드: `quality_last_verified_at`, `quality_gate_expires_at`, `quality_benchmark_version`.

Expiry에 도달하면 `stale`로 전환하고 기본 production routing에서 제외합니다.

### 9.3 Drift-triggered revalidation

다음 신호가 threshold를 넘으면 만료일 전이라도 재게이트를 예약합니다.

- `malformed_output_rate` 급증
- structured format pass 하락
- tool-call parse/exactness 하락
- `finish_reason` 구성의 통계적 변화
- output token 분포의 큰 shift
- provider가 quantization/tokenizer/model revision을 변경했다고 보고
- unexpected truncation/stop pattern 증가

Quality drift는 availability health와 **별도 계열로 집계**합니다.

---

## 10. Streaming과 Commit Contract

### 10.1 Commit point

**첫 user-visible content chunk를 client에 flush하는 순간**을 commit point로 정의합니다.

- commit **전** 실패: 다른 deployment로 자동 fallback 가능
- commit **후** 실패: 자동 provider reroute 금지

Commit 후 upstream 실패: partial response + `finish_reason = "upstream_error"`.

### 10.2 Pre-commit buffer

`precommit_buffer_ms` 동안 첫 chunk를 짧게 보류하여 무료 fallback 구간을 넓힐 수 있습니다. latency mode별로 다르게 설정하고 TTFT 영향은 replay/canary에서 검증합니다.

### 10.3 Attempt-level ledger

```
request_actual_cogs = sum(attempt.actual_cost)
```

실패한 attempt도 과금될 수 있으므로 **반드시 모두 기록**합니다.

---

## 11. Failure Classification과 Malformed Output

### 11.1 `malformed_output` 정의

HTTP 200이라도 다음은 정상 성공으로 집계하지 않습니다.

- strict schema 위반
- tool-call JSON parse 실패
- tool call required인데 malformed/누락
- finish reason/event sequence가 contract에 맞지 않음
- provider-specific parser가 복구하지 못한 truncation/corruption

처리:

- **pre-commit**: 동일 deployment 1회 retry 허용. retry도 실패하면 다른 eligible deployment로 fallback 가능
- **post-commit**: 자동 reroute 금지. partial/structured error 반환
- availability breaker에는 기본 미포함
- `quality_drift_metrics` 및 gate 재검증 trigger에 포함

### 11.2 분류 표

| 결과 유형 | 처리 | Breaker |
|---|---|---|
| 429 / capacity | Retry-After + token bucket, deprioritize, 다음 후보 | **아니오** |
| 5xx / connect / pre-commit timeout | failure risk 갱신, circuit breaker, half-open probe | 예 |
| 400 / unsupported | adapter/capability 수정. blind retry 금지 | 아니오 |
| 401 / 403 / billing | credential scope 비활성화 + alert + 다음 후보 | 아니오 |
| Safety / 정상 거절 | 그대로 반환. **provider hopping 금지** | 아니오 |
| `malformed_output` | pre-commit 1회 동종 retry, quality drift 집계 | 아니오 |
| post-commit stream failure | partial 반환, `finish_reason=upstream_error`, 자동 reroute 금지 | 아니오 |

---

## 12. 보안, Credential, Multi-tenancy

### 12.1 Secret storage

- 실제 key는 application DB에 평문 저장하지 않음
- KMS/Secret Manager/Vault에 저장, DB에는 `secret_ref`
- `created_at`, `last_rotated_at`, `expires_at`, `status` 추적

### 12.2 Billing owner

```
billing_owner = "tomverse" | "workspace"
```

### 12.3 BYOK와 quota isolation

- `workspace_provider_credentials`
- credential마다 `quota_scope_id`를 둘 수 있음
- capacity/admission은 credential/quota scope 단위
- deployment availability는 shared deployment 단위

### 12.4 Data residency hard gate

```
provider.data_processing_policy
+ deployment.endpoint_region
+ deployment.retention_policy
+ workspace.data_policy
+ subprocessor_chain
```

---

## 13. 권장 데이터 모델 v2.1

### `control_plane_versions`

한 버전이 실제 routing runtime에서 사용할 하위 config 집합을 immutable하게 고정합니다.

`id` (monotonic/versioned), `provider_registry_version`, `deployment_registry_version`, `routing_weights_version`, `routing_anchors_version`, `pricing_catalog_version`, `quality_policy_version`, `version_policy_version`, `created_at`, `status = draft | shadow | canary | active | retired`

Active pointer는 **원자적으로** 교체합니다.

### `models`

`id`, `family`, `canonical_name`, `display_name`, `status`, `default_quality_tier`, `default_allow_version_drift`

### `providers`

`id`, `name`, `type = direct | cloud | partner | aggregator`, `data_processing_regions`, `retention_policy`, `training_policy`, `failure_domain_tags`, `status`

### `deployments`

`id`, `model_id`, `provider_id`, `upstream_model_name`, `model_version`, `model_revision`, `version_pin_strength`, `allow_version_drift`, `endpoint_region`, `quality_tier`, `quantization`, `tokenizer_revision`, `quality_benchmark_version`, `quality_gate_status`, `quality_last_verified_at`, `quality_gate_expires_at`, `supports_tools`, `supports_parallel_tool_calls`, `supports_streaming`, `supports_streaming_tools`, `structured_output_mode`, `supports_input_image`, `supports_output_image`, `supports_input_audio`, `supports_output_audio`, `max_context`, `max_output_tokens`, `quirks JSONB`, `enabled`

### `pricing_snapshots`

`id`, `pricing_catalog_version`, `deployment_id`, `input_per_1m`, `cached_input_per_1m`, `output_per_1m`, `modality_pricing JSONB`, `fixed_fees JSONB`, `pricing_mode`, `currency`, `effective_from`, `effective_to`, `captured_at`

### `routing_weight_configs`

`id`, `routing_mode`, `logical_model_id`, `workload_class`, `region_class`, `w_cost`, `w_latency`, `w_health`, `near_best_delta`, `softmax_temperature`, `explore_rate`, `explore_max_penalty_delta`, `explore_max_cost_multiplier`, `explore_max_estimated_cost_delta`, `explore_latency_ceiling`, `ratio_cap`, `created_at`

### `routing_anchor_configs`

`id`, `logical_model_id`, `workload_class`, `routing_mode`, `region_class`, `cost_anchor`, `latency_slo_anchor`, `failure_risk_anchor`, `anchor_source`, `reference_deployment_id` (nullable), `derivation_metadata JSONB` (nullable), `effective_from`

### `deployment_health_metrics`

429/capacity를 **제외한** shared deployment health입니다.

`deployment_id`, `window`, `sample_count`, `ttft_p50`, `ttft_p95`, `tokens_per_sec_p50`, `tokens_per_sec_p95`, `rate_5xx`, `timeout_rate`, `connection_error_rate`, `shrunk_failure_risk`, `updated_at`

### `credential_capacity_state`

`deployment_id`, `credential_id`, `quota_scope_id`, `rate_429`, `retry_after_until`, `concurrency_limit`, `concurrency_in_use`, `token_bucket_remaining`, `deprioritize_until`, `updated_at`

### `quality_drift_metrics`

`deployment_id`, `window`, `sample_count`, `malformed_output_rate`, `structured_output_failure_rate`, `tool_call_parse_failure_rate`, `finish_reason_distribution JSONB`, `output_length_distribution JSONB`, `drift_score`, `updated_at`

### `workload_output_stats`

`logical_model_id`, `workload_class`, `max_output_bucket`, `sample_count`, `output_tokens_p50`, `output_tokens_p75`, `output_tokens_p95`, `ewma_output_tokens`, `updated_at`

### `workspace_provider_credentials`

`id`, `workspace_id`, `provider_id`, `secret_ref`, `billing_owner`, `credential_scope`, `quota_scope_id`, `last_rotated_at`, `expires_at`, `status`

### `workspace_routing_policies`

`workspace_id`, `version`, `routing_mode`, `allow_exploration`, `allowed_regions`, `retention_policy`, `pin_scope`, `pinned_provider_id`, `pinned_deployment_id`, `pin_fallback_policy`, `budget_policy JSONB`, `created_at`

### `routing_events`

Request 단위 **결정 스냅샷**입니다.

`request_id`, `session_id` (nullable), `conversation_id` (nullable), `workspace_id`, `logical_model_id`, `workload_class`, `routing_mode`, `control_plane_version`, `workspace_policy_version`, `resolved_config_versions JSONB`, `candidate_evaluations JSONB`, `selected_deployment_id`, `shadow_selected_deployment_id` (nullable), `allocation_mode = sequential | shadow | canary | active`, `decision_seed`, `seed_scope = session | request`, `estimated_output_tokens`, `estimated_effective_cost`, `all_candidates_saturated`, `created_at`

`candidate_evaluations`는 gate에서 탈락한 deployment도 포함합니다.

```json
[
  {
    "deployment_id": "dep_deepinfra_x",
    "gate_result": "eligible",
    "gate_reasons": [],
    "credential_id": "cred_opaque_id",
    "estimated_effective_cost": 0.00042,
    "predicted_latency_ms": 640,
    "predicted_failure_risk": 0.003,
    "raw_cost_ratio": 0.70,
    "raw_latency_ratio": 0.80,
    "raw_failure_risk_ratio": 0.60,
    "capped_cost_ratio": 0.70,
    "routing_penalty": 0.71,
    "raw_penalty": 0.71,
    "softmax_weight": 0.61,
    "exploration_eligible": true
  },
  {
    "deployment_id": "dep_provider_y",
    "gate_result": "rejected",
    "gate_reasons": ["quality_gate_stale"],
    "softmax_weight": 0.0
  }
]
```

이 필드는 별도 mutable health table join 없이 "왜 선택됐는가 / 왜 제외됐는가"를 재현합니다.

### `routing_attempts`

`request_id`, `attempt_number`, `deployment_id`, `credential_id`, `started_at`, `first_token_at`, `ended_at`, `stream_committed_at`, `failure_class`, `validation_error_code` (nullable), `http_status`, `input_tokens`, `cached_input_tokens`, `output_tokens`, `actual_cost`, `retry_after_ms`, `finish_reason`, `provider_request_id`

---

## 14. Provider Pool 정책

### 14.1 OpenAI-compatible / Open-weight

Pool: Vendor Direct / DeepInfra / Sail Research / Together / OpenRouter

- **Direct** — 기준 deployment 및 vendor-native 기능
- **DeepInfra** — 범용 low-cost candidate
- **Sail Research** — background/flexible workload candidate
- **Together** — independent fallback/open-weight pool
- **OpenRouter** — emergency aggregator, failed-provider exclusion 필수

### 14.2 Claude

Pool: Anthropic Direct / DeepInfra / Google Vertex AI

- quality/version/capability equivalence가 확인된 deployment만 자동 fallback
- Anthropic-native 기능이 필요하면 Direct hard requirement 가능
- Vertex는 GCP/IAM/region 정책에 따라 primary 가능

### 14.3 Gemini

Pool: Gemini API / Google Vertex AI / DeepInfra

Gemini API와 Vertex는 quota/control plane이 다르지만 Google ecosystem 공통 의존성이 있으므로 failure-domain diversity는 **제한적으로** 평가합니다.

### 14.4 OpenAI

Pool: OpenAI Direct / Azure OpenAI

Marketing name이 같아도 revision/availability가 다를 수 있으므로 version equivalence gate를 강제합니다.

---

## 15. Deterministic Replay, Atomic Config, Testing

### 15.1 Exact decision replay

과거 routing decision을 정확히 재현하려면 `routing_events` 자체에 다음을 동결합니다.

- `control_plane_version`
- `workspace_policy_version`
- `resolved_config_versions`
- `candidate_evaluations`의 gate/metrics/penalty/weight
- `decision_seed`, `seed_scope`
- selected 및 shadow-selected deployment

**Mutable rolling metrics table을 과거 시점 snapshot처럼 취급하지 않습니다.**

### 15.2 Counterfactual replay

"그 당시 request에 새 weight/anchor를 적용했다면?"을 분석할 때는 event의 raw candidate inputs를 이용해 새 config로 penalty/allocation을 재계산합니다.

### 15.3 Fault injection

최소 주입 항목: primary 5xx spike, latency 2x/5x, credential-specific 429 saturation, BYOK credential expiration, region/retention policy 변경, pricing 급변, cache hit rate 변화, quality gate stale/fail, malformed output spike, model version drift, pre-commit/post-commit stream failure, all-candidates-saturated 상태.

### 15.4 Config invariant

- 한 request는 정확히 하나의 `control_plane_version`을 사용
- 해당 manifest가 참조하는 child config version은 immutable
- workspace policy version도 request 시작 시 고정
- 동일 frozen candidate evaluation + 동일 seed는 동일 allocation 결과 재현

### 15.5 승격 절차

```
Config Draft
  -> Offline Replay
  -> Fault Simulation
  -> Shadow
  -> Small Canary
  -> Wider Canary
  -> Active
```

---

## 16. 구현 우선순위 v2.1

### Phase 0 — Auditability, Atomic Config, Security, Replay

1. `routing_events` + `routing_attempts` 스키마를 **맨 먼저** 구현
2. `session_id`/`conversation_id` 전달 경로 확보
3. `candidate_evaluations` frozen decision snapshot 구현
4. `control_plane_versions` immutable manifest + atomic active pointer
5. workspace policy versioning
6. pricing snapshot write path
7. TTFT/TPS/5xx/429/malformed/cost 수집 파이프라인
8. secret reference/BYOK credential abstraction
9. deterministic replay + fault injection harness

### Phase 1 — Reliable Sequential Multi-Provider Core

- Provider Adapter
- Logical Model → Deployment Registry
- Capability/Quality/Version/Residency/Pin hard gates
- credential resolver
- credential-scoped 429/admission/token bucket
- deployment-scoped health + circuit breaker
- sequential fallback
- streaming commit contract
- malformed-output classification + same-deployment one retry
- attempt ledger
- OpenRouter failed-provider exclusion
- quality gate expiry/stale 상태
- basic health/capacity/quality dashboard

### Phase 2A — Dynamic Router Shadow Mode

실제 실행은 **Phase 1 sequential order를 유지**하면서 아래를 계산만 합니다.

- output estimator + cache-savings estimator
- fixed-anchor capped/raw penalty
- session-aware softmax
- explore eligibility/ceiling
- saturation detection
- `shadow_selected_deployment_id` 기록

비교 항목: 예상 COGS 차이, TTFT/SLO 차이, failure risk 차이, cache hit 변화, provider concentration, quality/malformed rate.

### Phase 2B — Canary Allocation

`allocation_mode=canary`, 권장 승격: `1% -> 5% -> 25% -> 50% -> 100%`

각 단계 rollback trigger: COGS regression, TTFT/SLO regression, malformed/quality regression, provider saturation/herding, cache-hit collapse.

### Phase 2C — Active Dynamic Allocation

- near-best softmax production 활성화
- session exploration cohort
- bounded exploration
- saturation fallback/alert
- anchor tuning은 derived proposal만 생성하고 자동 승격 금지

### Phase 3 — Enterprise Control Plane

workspace policy UI, contract/SLA-aware routing, dedicated/provisioned endpoints, budget ceiling/spend forecast, region/residency templates, maintenance windows, customer-specific quality tiers/benchmarks

---

## 17. 구현 기준 체크리스트

### Correctness

- [ ] penalty 최소화 방향 단일화
- [ ] fixed anchors, 후보 min-max 금지
- [ ] anchor source 명시 및 derived 자동 활성화 금지
- [ ] output 길이 추정/비용 calibration
- [ ] cache savings와 session-aware allocator 정합
- [ ] pin = hard gate, exploration 0
- [ ] ratio saturation 감지 + raw penalty fallback
- [ ] 429 capacity와 5xx availability key scope 분리
- [ ] malformed output 분류 및 품질 drift 연결
- [ ] quality gate expiry/stale/revalidation
- [ ] streaming commit point 및 attempt COGS

### Allocation Safety

- [ ] stateful session seed / stateless request seed
- [ ] session-level exploration cohort
- [ ] exploration opt-out
- [ ] penalty/cost/latency exploration ceiling
- [ ] Phase 2 shadow → canary → active

### Reproducibility

- [ ] 단일 immutable `control_plane_version`
- [ ] workspace policy version 고정
- [ ] candidate별 gate/raw/derived/weight frozen snapshot
- [ ] gate에서 탈락한 후보와 사유도 기록
- [ ] exact replay와 counterfactual replay 분리

### Security / Multi-tenancy

- [ ] secrets는 vault/KMS reference
- [ ] billing owner/BYOK 구분
- [ ] capacity state는 credential/quota scope 단위
- [ ] residency/retention/subprocessor hard gate

---

## 18. 최종 결정

Tomverse의 라우팅 핵심 경로는 다음과 같이 확정합니다.

```
Atomic control-plane snapshot
  -> hard correctness / pin gates
  -> credential-scoped capacity
  -> deployment-scoped health
  -> session-aware cost + cache prediction
  -> capped penalty + saturation fallback
  -> session-aware bounded allocation
  -> explicit streaming/failure contract
  -> attempt-level accounting
  -> frozen candidate decision log
  -> replay / shadow / canary promotion
```

v2.1에서 가장 중요한 변화는 **"분산 라우팅"과 "캐시 affinity"를 같은 session key로 결합**하고, **capacity, health, quality, config snapshot이 각각 올바른 scope와 lifetime을 갖도록 분리**한 것입니다. 또한 dynamic allocation은 즉시 production에 켜지 않고 shadow와 canary를 거치므로, 라우터 자체가 새로운 장애 원인이 되는 위험을 줄입니다.

이 문서를 구현 기준선으로 사용하고, v1.0과 v2.0은 superseded 상태로 취급합니다.

---

## 부록 A. 구현 중 확정할 미결 항목 (v2.1 리뷰, R1–R6)

v2.1을 기준선으로 확정하면서, 문서 개정이 아니라 **구현 시점에 결정**하기로 한 항목입니다.

| ID | 항목 | 결정 시점 |
|---|---|---|
| R1 | session affinity가 seed에서 *유도*되므로 "capacity로 밀려남"을 표현 못 함. `affinity_deployment_id` + `affinity_epoch`를 세션 상태로 **저장**하고 변위 시 hold-down 적용 | Phase 1 |
| R2 | bounded exploration이 Phase 2C에 있어 Phase 2A shadow가 prior/stale 지표로 점수를 매김. exploration을 Phase 1–2A로 전진 필요. 또한 shadow의 TTFT/failure/cache/malformed는 **관측 불가(counterfactual)** 임을 명시 | Phase 1 / 2A |
| R3 | `max_attempts_per_request`, `request_deadline_ms` 부재. `Retry-After`는 **이후 요청의 capacity state만 갱신**하고 현재 요청은 즉시 다음 후보로 이동함을 명시 | Phase 1 |
| R4 | `deployments`에 `supports_prompt_cache`, `cache_min_prefix_tokens`, `cache_ttl_seconds` 부재. stateful 1턴째 결정의 amortized cost 반영 | Phase 1 / 2C |
| R5 | `w_cost + w_latency + w_health == 1.0` 불변조건이 미명시. manifest 승격 시 검증 | Phase 2A |
| R6 | `failure_domain_tags`가 penalty에 반영되지 않음. primary 선택이 아니라 **fallback chain 구성**에 적용하거나 Phase 3로 명시 | Phase 3 |
