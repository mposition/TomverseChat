# 구현 이관 문서 (Phase 0 이후)

이 문서는 로컬 Claude Code 세션이 이어받아 구현을 진행하기 위한 인수인계 문서입니다.
원격 세션에서 ADR 확정과 Phase 0 스키마까지 완료했고, **TypeScript 런타임 구현은 여기서부터**입니다.

## 1. 현재 상태

- **레포**: `mposition/TomverseChat`
- **브랜치**: `claude/loving-heisenberg-y0bxyh` (`d3cdbca`)
- **런타임 스택 결정**: TypeScript / Node 22+
- **구현 기준선**: [`docs/adr/0001-tomverse-routing-v2.1.md`](./adr/0001-tomverse-routing-v2.1.md) — **v1.0/v2.0은 superseded, 참조 금지**

### 완료된 것

| 커밋 | 내용 |
|---|---|
| `e548008` | ADR v2.1 전문 + 부록 A (구현 시점 결정 항목 R1–R6) |
| `d3cdbca` | Phase 0 스키마 — 5개 테이블 + `request_cogs` 뷰, 제약 스모크 테스트 33종 |

`migrations/0001_routing_phase0_core.up.sql`은 PostgreSQL 16.13에서 검증되었습니다
(33 assertion 통과, up → down → up 클린). `migrations/README.md`에 설계 근거와
**known gaps 5건**이 기록되어 있으니 먼저 읽으십시오.

### 완료되지 않은 것

런타임 코드가 **전혀 없습니다.** `package.json`도 없는 상태입니다. 레포에는
`README.md`, `docs/`, `migrations/`만 있습니다.

## 2. ADR 리뷰 이력 — 반드시 유지할 결정

세 차례 리뷰(C1–C15 → N1–N11 → R1–R6)를 거쳐 확정된 사항입니다. 구현 중 "더 간단한
방법"으로 되돌리기 쉬운 것들이므로, 아래를 어기는 코드는 리뷰에서 반려해야 합니다.

1. **목적함수는 `routing_penalty` 최소화.** `score`, `best score` 같은 방향이 모호한
   이름을 쓰지 않습니다. (C1)
2. **후보군 min-max 정규화 금지.** fixed anchor만 사용합니다. (C2)
3. **429는 circuit breaker를 열지 않습니다.** capacity/admission 경로이고,
   `(deployment_id, credential_id)` 또는 `quota_scope_id` 단위입니다. availability
   health는 deployment 단위입니다. 이 둘의 key scope가 다릅니다. (C5, N3)
4. **정상 safety refusal을 다른 provider로 재시도하지 않습니다.** failure가 아니라
   valid response이며 `failure_class = NULL`로 기록됩니다. (C7 원칙)
5. **quality_tier / quantization / model version은 hard gate.** 비용 최적화가 이것을
   우회할 수 없습니다. (C7, C8)
6. **commit point = 첫 user-visible chunk flush.** 이후 자동 reroute 금지. (C11)
7. **COGS는 attempt 단위.** 실패한 attempt도 과금될 수 있습니다. (C11)
8. **한 요청은 정확히 하나의 `control_plane_version`을 사용합니다.** 요청 중간에
   config가 승격되어도 섞이지 않습니다. (N10)
9. **stateful workload는 session seed, stateless는 request seed.** exploration cohort도
   세션 단위입니다. 이걸 request 단위로 되돌리면 cache affinity가 깨집니다. (N1)
10. **dynamic allocation은 즉시 켜지 않습니다.** sequential → shadow → canary → active. (N11)

### 부록 A (R1–R6) — 구현 중 확정할 항목

| ID | 내용 | 확정 시점 |
|---|---|---|
| **R1** | session affinity를 seed에서 유도하지 말고 `affinity_deployment_id` + `affinity_epoch`를 **저장 상태**로 유지. capacity로 밀려났을 때 hold-down을 적용해 D→E→D 왕복 진동을 막을 것 | Phase 1 |
| **R2** | bounded exploration을 Phase 2C가 아니라 **Phase 1–2A로 전진**. 그러지 않으면 shadow가 prior/stale 지표로 점수를 매김. shadow의 TTFT/failure/cache/malformed는 **관측 불가(counterfactual)** 임을 문서화 | Phase 1 / 2A |
| **R3** | `max_attempts_per_request`, `request_deadline_ms` 구현. **`Retry-After`는 이후 요청의 capacity state만 갱신하고, 현재 요청은 즉시 다음 후보로 이동** (절대 블로킹 대기 금지) | Phase 1 |
| **R4** | `deployments`에 `supports_prompt_cache`, `cache_min_prefix_tokens`, `cache_ttl_seconds` 추가. stateful 1턴째의 amortized cost 반영 | Phase 1 / 2C |
| **R5** | `w_cost + w_latency + w_health == 1.0`을 manifest 승격 시 검증 | Phase 2A |
| **R6** | `failure_domain_tags`를 primary 선택이 아니라 **fallback chain 구성**에 적용하거나 Phase 3로 명시 | Phase 3 |

## 3. 권장 작업 순서

원격 세션에서 등록한 20개 작업입니다. 순서대로 진행하는 것을 권장합니다.

### Phase 0 잔여 (ADR §16 Phase 0 items 7–9 + 선행 작업)

1. **TypeScript 스켈레톤** — tsconfig(strict), vitest, eslint, `pg`, 로컬 Postgres 기동
   스크립트, 마이그레이션 러너. 마이그레이션은 현재 순수 SQL이므로 러너는 자유롭게
   선택하되 파일 형식(`NNNN_name.up.sql` / `.down.sql`)은 유지할 것
2. **`0002` registry + config 마이그레이션** — `models`, `providers`, `deployments`,
   `workspace_provider_credentials`, `routing_weight_configs`, `routing_anchor_configs`,
   `deployment_health_metrics`, `credential_capacity_state`, `quality_drift_metrics`,
   `workload_output_stats`. **여기서 `0001`의 known gap 1·2(FK 누락, pricing catalog
   소유 테이블 부재)를 닫을 것.** R4 필드도 `deployments`에 포함
3. **원자적 control-plane config resolver** — ADR §2.1/§15.4
4. **텔레메트리 write path** — `candidate_evaluations` 동결 기록 + attempt ledger
5. **메트릭 집계** — health(shrinkage 포함) / capacity / quality drift / output stats.
   429와 `malformed_output`을 availability에 섞지 말 것
6. **credential resolver + BYOK/secret-ref** — 평문 키 DB 저장 금지
7. **결정론적 replay + fault injection 하네스** — ADR §15.3의 주입 12종과
   **invariant 7종을 테스트로 구현**. 이후 모든 튜닝의 안전망이므로 축소하지 말 것

### Phase 1 (8–15)

8. Provider adapter 인터페이스 + ADR §11 failure classifier
9. 구체 adapter 4종 (OpenAI-compat / Anthropic / Gemini / OpenRouter).
   OpenRouter는 **failed-provider exclusion 필수**
10. deployment pool 해석 + hard gates (capability/quality/version/residency/pin)
11. capacity admission (429 / token bucket / Retry-After) — R3 준수
12. circuit breaker (deployment 단위, CLOSED/OPEN/HALF_OPEN + probe budget)
13. sequential fallback 엔진 + deadline / max-attempts
14. streaming commit contract + malformed-output 동일 deployment 1회 retry
15. session affinity store — R1

### Phase 2A–2C (16–20)

16. cost estimator (output 길이 p50/p75/p95 + session-aware cache savings + calibration)
17. fixed-anchor penalty + saturation 처리 + R5 검증
18. session-aware softmax allocator + bounded exploration (ceiling 4종, load guard)
19. shadow mode 통합 — 실행은 sequential 유지, 계산만. R2의 관측/추정 구분 명시
20. canary 램프(1→5→25→50→100%) + rollback trigger 5종 + active 전환

### Phase 3

ADR §16 Phase 3. workspace policy UI는 프론트엔드 영역이므로 백엔드 범위
(SLA-aware routing, budget ceiling, dedicated endpoint, maintenance window,
customer-specific quality tier)와 분리해 착수할 것.

## 4. 작업 규약

- **브랜치**: `claude/loving-heisenberg-y0bxyh`에 계속 쌓거나, 원하면 Phase별 브랜치로 분리
- **커밋**: 한 작업 단위 = 한 커밋. 본문에 ADR 조항(§)과 리뷰 ID(C/N/R)를 인용할 것
- **테스트**: 스키마 변경은 `migrations/tests/`에 제약 테스트를 함께 추가.
  런타임 로직은 vitest. **ADR §15.3 invariant 7종은 통합 테스트로 상시 유지**
- **PR**: 명시적 요청이 있을 때만 생성

## 5. 미해결/주의 사항

1. **`migrations/README.md`의 known gaps 5건**을 `0002`에서 최소 1·2·4번은 닫을 것
2. **파티션 유지보수 자동화 미구현** — `0001`이 2026-09 ~ 2027-08 12개월분 + DEFAULT를
   선생성했습니다. DEFAULT에 행이 들어가면 해당 구간 파티션을 나중에 만들 수 없으므로
   pg_partman 또는 스케줄 작업을 프로덕션 트래픽 전에 붙일 것
3. **보존/아카이브 정책 미정** — `routing_events` 보관 기간이 결정되지 않았고,
   ADR §12.4 residency 규칙이 이 데이터에도 적용됩니다
4. **독립 검토** — 원격 세션에서는 cursor CLI를 사용할 수 없었습니다(네트워크 정책이
   `cursor.com`을 차단, `CURSOR_API_KEY` 미설정). 따라서 **이 레포의 코드는 아직 어떤
   독립 검토도 받지 않았습니다.** 로컬에서 cursor 검토를 돌릴 수 있다면 최소한
   `migrations/0001_routing_phase0_core.up.sql`부터 한 번 받아보는 것을 권장합니다
