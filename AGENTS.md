# 이 저장소는 개발 루트가 아닙니다

**Tomverse Chat 구현은 이 저장소에서 하지 않습니다.**

- 정식 구현 저장소 (source of truth): <https://github.com/mposition/Tomverse>
  (`package.json`의 name은 `ai-chat-hub`)
- 이 저장소(`mposition/TomverseChat`)는 비어 있는 placeholder이며,
  정식 저장소로 향하는 redirect 역할만 합니다.

정식 저장소의 `docs/policy/tomverse-chat-delivery-plan.md` §1에 확정된 결정입니다.

> The existing `ai-chat-hub` repository is the implementation source of truth.
> The empty `TomverseChat` placeholder repository is archived or made read-only
> with a redirect to the canonical repository before implementation begins.
> It must not become a second development root or duplicate platform logic.

## 에이전트가 지켜야 할 것

1. **이 저장소에 제품 코드를 만들지 마십시오.** 스캐폴딩, 빌드 설정,
   패키지 초기화도 포함됩니다. 두 번째 개발 루트를 만드는 순간 계획 위반입니다.
2. **Tomverse Chat 관련 질문·설계·구현 요청을 받으면 정식 저장소를 먼저 읽으십시오.**
   이 저장소만 보고 답하면 반드시 틀린 답이 나옵니다. 이 저장소에는 아무것도 없습니다.

   ```bash
   GIT_LFS_SKIP_SMUDGE=1 git clone --depth 1 https://github.com/mposition/Tomverse
   ```

3. **플랫폼 로직을 여기에 복제하지 마십시오.** 계정, 크레딧, 모델 카탈로그,
   provider adapter는 모두 공유 플랫폼에 이미 있습니다.

## 제품 맥락

Tomverse는 **Branded House**입니다. Tomverse Chat은 별도 브랜드 스택도 아니고
Tomverse Review의 fork도 아니며, **공유 Tomverse 플랫폼 위의 product surface**입니다.

Review / Chat / Code / Studio가 공유하는 것:

- 계정과 identity linkage
- projects, conversation ownership
- model catalog, provider adapters
- credits, reservation, settlement, reconciliation, payment history
- safety, privacy, audit, data lifecycle

Tomverse Chat v1이 더하는 것: 모바일 우선 단일 답변 chat 경험, 현재 task에 가장
적합한 허용 모델을 자동 선택하는 Auto Router, versioned Prompt Planner.
long-term memory는 별도 Release B 승인 이후에만 포함됩니다.

## 정식 저장소의 1차 문서

작업 전에 아래를 읽으십시오. 경로는 모두 `mposition/Tomverse` 기준입니다.

| 경로 | 내용 |
| --- | --- |
| `AGENTS.md` | 저장소 공통 코딩 에이전트 규칙 (`CLAUDE.md`가 이 파일을 참조) |
| `docs/policy/tomverse-chat-delivery-plan.md` | v1 범위, 아키텍처, phase, swimlane, 저장소 전략 |
| `docs/release-gates/tomverse-chat-v1.yaml` | canonical release gate |
| `docs/policy/tomverse-chat-routing.md` | Auto Router, RoutingRun / Attempt / ContextManifest |
| `docs/policy/tomverse-chat-mobile-authentication.md` | 모바일 token, OAuth/PKCE, native 경계 |
| `docs/policy/tomverse-chat-data-domain-registry.yaml` | 계정 삭제·통합 export용 data-domain registry |
| `docs/policy/tomverse-chat-model-capability-inventory.md` | provider/model capability, tokenizer, 한도, 가격 |
| `docs/policy/tomverse-chat-context-window-register.yaml` | context window register |
| `docs/policy/shared-packages.md` | `chat-core` / `chat-ui` / `api-client` 경계 |
| `docs/ops/tomverse-chat-*.md` | router rollout, fallback drill, 평가 세트, store review 운영 |
| `docs/ui-contracts/` | 위반 시 릴리스 블로커인 UI 불변식 |

**숫자의 유일한 출처는 release gate YAML입니다.** 산문 문서는 결정의 배경을
설명할 수 있지만 임계값을 재정의할 수 없습니다. 이 문서도 마찬가지입니다.

## 소통 언어

정식 저장소의 규칙을 그대로 따릅니다.

- 사용자와의 모든 대화는 **한국어**로 합니다. 사용자가 영어로 물어도 별도
  요청이 없으면 한국어로 답합니다.
- 저장소에 남기는 것은 기존 영어 관례를 따릅니다 — code identifier, 파일명,
  `data-testid`, test 제목, 소스 코드 주석, commit message, PR 제목과 본문.
- 사용자에게 보이는 제품 문구는 `locales/*.ts`가 언어별로 관리합니다.
