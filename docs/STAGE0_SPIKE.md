# 단계 0 기술 검증 기록

검증일: 2026-07-27  
환경: Windows, PowerShell 7.6.3

## 검증 범위

설치된 CLI의 버전, 도움말에 노출된 기능, 구독 로그인 상태 명령과 API 자격증명 우선 조건을 확인했다. 사용자 승인 후 공급자별 1회 실제 모델 호출도 수행해 구조화 출력과 런타임 안전 경계를 검증했다.

## Codex

- 확인 버전: `codex-cli 0.145.0`
- 구독 인증: `codex login status` 종료 코드와 `Logged in using ChatGPT`만 정규화
- 확인 기능: `--model`, `--ask-for-approval`, `--config`, `--sandbox`, `--skip-git-repo-check`, `--ephemeral`, `--ignore-user-config`, `--ignore-rules`, `--output-schema`, `--json`, `--output-last-message`
- 판단: 문서 모드용 격리 작업 폴더·읽기 전용·구조화 출력의 구현 기준선은 충족
- 모델 메뉴: CLI `app-server model/list`의 계정별 가시 모델, `isDefault`, 모델별 기본·지원 추론 정도를 프로세스마다 조회한다. 현재 결과는 가시 모델 7개, `gpt-5.6-sol` 기본, `high` 지원으로 권장 표시되며 조회 실패 시 로컬 캐시와 제한된 내장 목록으로 폴백한다.
- 차단 사항: Windows `read-only` 격리 스파이크에서 쓰기는 거부됐지만 범위 밖 읽기와 자식 프로세스 실행이 허용되어 3A의 선제 차단 계약을 충족하지 못함

## Claude Code

- 확인 버전: `2.1.220 (Claude Code)`
- 구독 인증: `claude auth status`의 원문을 보존하지 않고 `loggedIn`, `authMethod`, `apiProvider`, `subscriptionType`만 정규화
- 확인 기능: `--model`, `--effort`, `--safe-mode`, `--strict-mcp-config`, 빈 `--tools`, `--disallowedTools`, `--no-chrome`, `--no-session-persistence`, `--permission-mode`, `--output-format`, `--json-schema`
- 설치된 2.1.220 도움말에는 온라인 CLI 문서의 `--max-turns`가 노출되지 않아 해당 플래그에 의존하지 않고 `-p` 단일 출력 호출을 사용한다.
- 판단: 문서 모드와 무도구 호출 프로필의 구현 기준선은 충족
- 모델 메뉴: 설치된 `claude --help`에서 최신 계열 별칭과 effort를 프로세스마다 다시 읽고 `default`를 함께 제공한다. 현재는 `opus|sonnet|fable|default`와 `low|medium|high|xhigh|max`를 표시하며 `opus + high`가 실제 목록에 있을 때만 권장한다. Claude CLI에는 계정별 `/model` 전체 행을 내보내는 기계 판독 명령이 없어 별칭이 실제 버전을 런타임에 해석한다.

## 인증 안전

- `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`과 공급자 우회 변수가 프로세스 환경에 존재하면 변수 이름만 표시하고 실패 폐쇄한다.
- 환경 변수 값, 이메일, 조직 ID, 토큰과 공급자 인증 파일은 상태·로그·매니페스트에 저장하지 않는다.
- 환경 변수 삭제나 공급자 로그아웃은 자동 수행하지 않는다.

## 결론

- `shared-document`, `dual-document`: 공통 기반 구현을 진행할 수 있음
- `dual-project-audit`: `DF-PREFLIGHT-3A-ISOLATION`으로 차단
- 공급자별 라이브 스모크: `run-20260727-142342-87cca1`에서 Codex `gpt-5.6-sol/high`, Claude `opus/high`를 각 1회 호출해 구조화 `independent-draft` 성공
- 라이브 안전 결과: 실제 이벤트 스트림의 금지 도구 이벤트 0건, 공급자 임시 작업 파일 0개, 호출 후 두 구독 인증 유지
- 라이브 과정에서 수정한 결함: PowerShell 래퍼의 종료 코드 손실, 승인 환경의 `Path` 누락, Codex 엄격 JSON Schema의 상수 타입 누락
- 전체 단계 E2E: `run-20260727-142702-0eeb82`에서 2라운드 13/13 단계 커밋, 라운드 장벽·상호 비평·응답·교대 합성·최종 검증과 최종 파일 5개 생성 확인
- 전체 단계 안전 결과: 원본 SHA-256 동일, 공급자 임시 파일 0개, 저장 파일의 비밀 패턴 0건, 호출 후 두 구독 인증 유지
- E2E 과정에서 수정한 추가 결함: 비밀 제거 결과의 빈·단일·다중 배열이 두 번째 PowerShell 정규화에서 붕괴하던 문제
- 독립 문서 전체 단계 E2E: `run-20260727-155148-7617d3`에서 Codex `gpt-5.6-sol/high`, Claude `opus/high`로 2라운드 12/12 단계와 최종 파일 6개 생성 후 사용자 결정 8건을 반영해 `COMPLETED`
- 독립 문서 안전 결과: 양쪽 원본 SHA-256 동일, 금지 도구 이벤트 0건, 공급자 작업 파일 0개, 미해결 질문 0개, 호출 후 두 구독 인증 유지
- 독립 문서 누적 모델 실행 시간: 형식 계약 복구와 결정 반영 재실행을 포함해 2,121.408초로 90분 상한 이내
- 독립 문서 E2E에서 수정한 결함: Codex 엄격 스키마의 선택 속성 거부, 여러 사용자 답변의 최신값 집계, 반복 무효화 감사 이력 배열, 이미 답한 과거 질문의 최종 병합 재등장
- 결정 반영 검증: 두 최신 공급자 결과가 결정 8건의 반영을 명시했고, 최종 렌더러가 결정 원장을 적용해 과거 질문을 확정 처리한 뒤 모델 재호출 없이 `AWAITING_USER`에서 `COMPLETED`로 전환
- 3A OS 격리 스파이크: 범위 밖 표식 읽기와 중첩 `cmd.exe` 실행은 종료 코드 0으로 성공했고, 쓰기만 접근 거부와 전후 SHA-256 동일을 확인해 3A 게이트를 계속 닫음
- 3A 상세 근거: [3A_ISOLATION_SPIKE.md](3A_ISOLATION_SPIKE.md)

## workflow-v2 실제 공급자 E2E

검증일: 2026-07-28
모델: Codex `gpt-5.6-sol/high`, Claude `opus/high`

- 중립 A/B 픽스처와 메타데이터 전용 검증기를 사용했다. 검증 출력에는 원문 공급자 출력, stdout·stderr, 프롬프트·문서·컨텍스트 내용, 생성 중 텍스트와 비밀값을 포함하지 않았다.
- `run-20260728-033711-fad8f8`: `workflow-v2 shared-document`, 13/13 단계, Codex 7회·Claude 6회, `AWAITING_USER`, 강화 검증 통과
- `run-20260728-040441-2cb68c`: `workflow-v2 document-merge`, 13/13 단계, Codex 7회·Claude 6회, `AWAITING_USER`, 강화 검증 통과
- `run-20260728-043711-14a4b7`: `workflow-v2 dual-document`, 14/14 단계, Codex 7회·Claude 7회. 입력·스냅샷 해시, 단계 계약, A/B 최종 파일과 비노출 검사는 통과했지만 상태 의미 검증은 `WAITING_STATUS_WITHOUT_BLOCKING_ISSUE`로 실패
- `run-20260728-095906-127f6d`: 수정 후 `workflow-v2 dual-document`, 14/14 단계, Codex 7회·Claude 7회, `AWAITING_USER`, Critical/Major 사용자 결정 차단 4건과 상태가 일치해 강화 검증 통과
- 위 세 통과 실행의 `AWAITING_USER`는 전체 단계 커밋, 최종 산출물 생성과 질문 카드 사용자 게이트가 정상 동작한 실제 E2E 성공 체크포인트다. 테스트 픽스처의 질문을 임의로 답해 `COMPLETED`까지 재호출하는 작업은 이 검증의 완료 조건이 아니다.
- 통과 실행의 저장된 `opus/high` 선택값은 감사 계보로 보존하고 재호출하지 않는다. 향후 코드 변경으로 신규 실제 E2E가 필요할 때만 테스트 전용 `sonnet/low`와 새 `LIVE` 동의를 사용한다.
- 공통 안전 결과: 통과·감사 실행 합계 호출 시작 55회, 완료·단계 커밋 54회. 초기 스키마 호환성 결함 실행의 1회만 커밋되지 않았고 공급자 실패 이벤트는 0건이다. 원본 SHA-256 불변, 스냅샷 1/4/4/4개 검증, 금지 이벤트·데이터 키·문서 카나리·`provider-work` 잔여 각 0건을 확인했다.
- 라이브 과정에서 수정한 결함: 모듈 클로저가 private 공급자 함수를 해석하지 못한 문제, Codex 구조화 출력과 호환되지 않는 `uniqueItems` 키워드
- 모드 3 후속 분석에서 Minor `NEEDS_EVIDENCE` 쟁점이 이전 질문의 `blocking=true`를 유지하는 의미 결함을 확인했다. 모든 병합 뒤 중앙 심각도 규칙으로 차단 여부를 재계산하고 Minor 근거 대기가 완료 게이트를 막지 않는 회귀를 기존 68개 테스트에 추가했다.
- 수정 코드를 저장 결과에 쓰지 않고 14개 커밋 결과에 재계산한 예상 상태는 `AWAITING_USER`이며, 차단 근거 대기 0건·사용자 결정 대기 7건이다.
- 수정 전 실패 실행과 결과 원장은 감사 증거로 보존하며 재작성하지 않는다. 수정 후 신규 모드 3 실행은 입력 해시 불변, 스냅샷 4개, A/B 최종 파일 6개, 금지 이벤트·키·문서 카나리·공급자 작업 잔여 0건을 통과했다.

## 공식 기준

- [OpenAI Codex CLI 명령 참조](https://developers.openai.com/codex/cli/reference)
- [Claude Code 인증](https://code.claude.com/docs/en/authentication)
- [Claude Code CLI 참조](https://code.claude.com/docs/en/cli-usage)
- [Claude Code API 키 환경 변수 우선순위](https://support.claude.com/en/articles/12304248-manage-api-key-environment-variables-in-claude-code)
