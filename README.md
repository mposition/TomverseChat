# TomverseChat — placeholder

이 저장소는 **개발 루트가 아닙니다.** 여기에 코드를 추가하지 마십시오.

Tomverse Chat의 구현 source of truth는 아래 저장소입니다.

### → <https://github.com/mposition/Tomverse>

Tomverse Chat은 별도 스택이 아니라 공유 Tomverse 플랫폼 위의 product surface이며,
계정·크레딧·model catalog·provider adapter를 Review / Code / Studio와 공유합니다.

관련 문서는 모두 정식 저장소에 있습니다.

- `docs/policy/tomverse-chat-delivery-plan.md` — v1 범위와 delivery plan
- `docs/release-gates/tomverse-chat-v1.yaml` — canonical release gate

근거: delivery plan §1 — *"The existing `ai-chat-hub` repository is the
implementation source of truth. The empty `TomverseChat` placeholder repository
is archived or made read-only with a redirect to the canonical repository before
implementation begins. It must not become a second development root or duplicate
platform logic."*

코딩 에이전트용 지침은 [`AGENTS.md`](AGENTS.md)에 있습니다.
