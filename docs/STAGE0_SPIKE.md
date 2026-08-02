# 단계 0 기술 검증 기록

검증일: 2026-07-27  
환경: Windows, PowerShell 7.6.3

이 문서는 검증 당시의 CLI·모델·실제 공급자 E2E 결과를 보존하는 시점 기록이다. 현재 설치·인증·모델 상태는 `.\duoforge.cmd doctor --json`으로 다시 확인한다.

## 검증 범위

설치된 CLI의 버전, 도움말에 노출된 기능, 구독 로그인 상태 명령과 API 자격증명 우선 조건을 확인했다. 사용자 승인 후 공급자별 1회 실제 모델 호출도 수행해 구조화 출력과 런타임 안전 경계를 검증했다.

## Codex

- 확인 버전: `codex-cli 0.145.0`
- 구독 인증: `codex login status` 종료 코드와 `Logged in using ChatGPT`만 정규화
- 확인 기능: `--model`, `--ask-for-approval`, `--config`, `--sandbox`, `--skip-git-repo-check`, `--ephemeral`, `--ignore-user-config`, `--ignore-rules`, `--output-schema`, `--json`, `--output-last-message`
- 판단: 문서 모드용 격리 작업 폴더·읽기 전용·구조화 출력의 구현 기준선은 충족
- 모델 메뉴: CLI `app-server model/list`의 계정별 가시 모델, `isDefault`, 모델별 기본·지원 추론 정도를 프로세스마다 조회한다. 검증 당시 결과는 가시 모델 7개, `gpt-5.6-sol` 기본, `high` 지원으로 권장 표시됐으며 조회 실패 시 로컬 캐시와 제한된 내장 목록으로 폴백한다.
- 차단 사항: Windows `read-only` 격리 스파이크에서 쓰기는 거부됐지만 범위 밖 읽기와 자식 프로세스 실행이 허용되어 3A의 선제 차단 계약을 충족하지 못함

## Claude Code

- 확인 버전: `2.1.220 (Claude Code)`
- 구독 인증: `claude auth status`의 원문을 보존하지 않고 `loggedIn`, `authMethod`, `apiProvider`, `subscriptionType`만 정규화
- 확인 기능: `--model`, `--effort`, `--safe-mode`, `--strict-mcp-config`, 빈 `--tools`, `--disallowedTools`, `--no-chrome`, `--no-session-persistence`, `--permission-mode`, `--output-format`, `--json-schema`
- 설치된 2.1.220 도움말에는 온라인 CLI 문서의 `--max-turns`가 노출되지 않아 해당 플래그에 의존하지 않고 `-p` 단일 출력 호출을 사용한다.
- 판단: 문서 모드와 무도구 호출 프로필의 구현 기준선은 충족
- 모델 메뉴: 설치된 `claude --help`에서 최신 계열 별칭과 effort를 프로세스마다 다시 읽고 `default`를 함께 제공한다. 검증 당시에는 `opus|sonnet|fable|default`와 `low|medium|high|xhigh|max`를 표시했으며 `opus + high`가 실제 목록에 있을 때만 권장한다. Claude CLI에는 계정별 `/model` 전체 행을 내보내는 기계 판독 명령이 없어 별칭이 실제 버전을 런타임에 해석한다.

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
- 통과 실행의 `opus/high` 선택값과 판정은 이 문서의 시점 증거로 남기며 재호출하지 않는다. 향후 코드 변경으로 신규 실제 E2E가 필요할 때만 테스트 전용 `sonnet/low`와 새 `LIVE` 동의를 사용한다.
- 공통 안전 결과: 통과·감사 실행 합계 호출 시작 55회, 완료·단계 커밋 54회. 초기 스키마 호환성 결함 실행의 1회만 커밋되지 않았고 공급자 실패 이벤트는 0건이다. 원본 SHA-256 불변, 스냅샷 1/4/4/4개 검증, 금지 이벤트·데이터 키·문서 카나리·`provider-work` 잔여 각 0건을 확인했다.
- 라이브 과정에서 수정한 결함: 모듈 클로저가 private 공급자 함수를 해석하지 못한 문제, Codex 구조화 출력과 호환되지 않는 `uniqueItems` 키워드
- 모드 3 후속 분석에서 Minor `NEEDS_EVIDENCE` 쟁점이 이전 질문의 `blocking=true`를 유지하는 의미 결함을 확인했다. 모든 병합 뒤 중앙 심각도 규칙으로 차단 여부를 재계산하고 Minor 근거 대기가 완료 게이트를 막지 않는 회귀를 기존 68개 테스트에 추가했다.
- 수정 코드를 저장 결과에 쓰지 않고 14개 커밋 결과에 재계산한 예상 상태는 `AWAITING_USER`이며, 차단 근거 대기 0건·사용자 결정 대기 7건이다.
- 수정 전 실패 실행과 결과 원장은 당시 감사 비교에 사용했고 재작성하지 않았다. 정리 후 테스트 실행 디렉터리 자체는 유지하지 않으며, 실패 원인과 수정 후 검증 결과는 이 문서에 보존한다. 수정 후 신규 모드 3 실행은 입력 해시 불변, 스냅샷 4개, A/B 최종 파일 6개, 금지 이벤트·키·문서 카나리·공급자 작업 잔여 0건을 통과했다.

현재 재검증 경로는 `tests\Invoke-WorkflowV2LiveE2E.ps1`, 저장 결과 강화 검증기는 `tests\Test-WorkflowV2LiveRun.ps1`이다. 둘 다 실제 공급자 호출과 테스트 전용 설정을 사용하므로 새로운 정확한 `LIVE` 동의가 있을 때만 실행한다. 대체된 workflow-v1 라이브 실행기와 과거 테스트 결과 디렉터리는 유지하지 않으며, workflow-v1 호환성은 오프라인 직렬화 fixture 회귀로 보호한다.

## 진행 heartbeat 및 복합 재개 복구 스파이크

검증일: 2026-07-31

- 실제 프로세스 callback seam에서 `PROVIDER_TICK` 경과 시간 `0,1,2`와 서로 다른 스피너 프레임을 확인했다. module-private observer 진입점은 이름 재해석 대신 캡처하고, observer·프레임 오류는 고정 코드와 안전한 횟수만 한 번 기록한다.
- `run-20260730-021613-3e022b`는 동일 볼륨 forensic 사본과 작업 복제본에서 정규 파일 46개, 주요 저장 항목 52개, NTFS ADS 4개와 해시를 먼저 검증했다. 작업 복제본의 10개 복원·4개 재실행 예정·공급자 0-call·`PAUSED_USER`가 통과한 뒤에만 원본에 같은 0-call 복구를 적용했다.
- 복구 후 원본은 10개 `COMMITTED`, 4개 `PENDING`, 누적 실제 호출 15, 현재 입력 세대 호출 10, 미답변 질문 0, Codex·Claude 잔여 단계 각 2개이며 `PAUSED_USER`에 있다. 원본 LIVE 재개는 수행하지 않았다.
- PowerShell 7 전체 오프라인 회귀는 `162개 통과, 0개 실패`다. 정의/참조 쟁점 대상 분리, 산출물 복구 원인 분리, 입력 세대 시도와 누적 호출 분리, 재시도 소진 `FAILED_STAGE`, observer 안전 폴백, 공급자 프로세스 안전 분류와 실행 컨텍스트 동일성을 포함한다.

### 저비용 실제 진행판 E2E

- 최초 승인으로 새 `shared-document` 실행 `run-20260731-061220-d351c6`을 만들었고, 별도 승인한 재시험은 `run-20260731-115418-ffd19c`, 비관리자 호스트 재검증은 `run-20260731-142621-3d2365`, 재부팅 후 재검증은 `run-20260731-163804-17c44b`이다. 네 실행 모두 Codex `gpt-5.6-luna/low`, Claude `sonnet/low`로 고정했다. 실제 카탈로그 출처는 각각 `codex-app-server`, `claude-cli-help`였으며 다른 모델로 대체하지 않았다.
- 네 실행 모두 Codex 첫 호출 1회가 동일한 `DF-PROVIDER-PROCESS`, 종료 코드 1, timeout 없음, stdout 0바이트, stderr 163바이트로 실패해 상태는 `RESUMABLE_ERROR`가 되었다. 각 실행의 Claude 호출은 0회이고 공급자 작업 잔여와 금지 이벤트·진단 키는 0건이다. 세 번째와 네 번째 실행의 stderr는 메모리 안전 분류에서 알려진 계열에 일치하지 않아 `UNKNOWN`으로 처리하고 원문을 즉시 버렸다.
- 호출 전에 실제 PowerShell 7 전체화면 진행판 진입은 확인했지만 호출이 즉시 실패해 같은 공급자 호출 중 경과 시간과 스피너가 여러 프레임으로 변하는 장시간 시각 증거, 첫 Codex·Claude 장벽 뒤 `PAUSED_USER`, 정상 2회 호출 기준은 확인하지 못했다.
- 허용 범위를 다른 모델, 상위 모델 또는 `fable`로 자동 대체하지 않았고 실패 후 새 실행이나 원본 실행을 자동 재개하지 않았다. 원시 stdout·stderr, 프롬프트, 문서 및 모델 응답은 화면·이벤트·진단·이 문서에 남기지 않았다.

### Codex 공급자 프로세스 결함 후속 진단

- 현재 설치 버전은 `codex-cli 0.146.0`이고 원본 성공 실행 매니페스트는 `codex-cli 0.145.0`을 기록한다. 현재 사용자 기본 설정은 `gpt-5.6-sol/high`지만 DuoForge는 저장된 모델·추론 정도를 명시하고 `--ignore-user-config`를 사용하므로 대화형 세션과 동일 호출 프로필이 아니다.
- 실제 `codex debug models` 카탈로그는 `gpt-5.6-sol`의 `high`, `gpt-5.6-luna`의 `low`·`medium`을 모두 허용한다. Sol/high, Luna/low, Luna/medium과 Luna/low 단계 스키마의 전체 전역·`exec` 인자 배열에 `--help`만 추가한 네 parse-only 검사는 모두 종료 코드 0이었고 모델 호출은 없었다. 모델 이름·추론 문자열·인자 순서는 유효하며, 이것만으로 실제 서비스 요청 성공을 증명하지는 않는다.
- doctor·모델 카탈로그·단계 호출이 모두 같은 `node.exe`와 `codex.js`, 계산된 인증 home과 정제된 자식 환경을 사용하도록 통합했다. 기존처럼 doctor·단계는 `codex.cmd`, 카탈로그는 직접 `node.exe codex.js`를 사용하는 구조적 차이를 제거했다.
- 카탈로그의 모델 노출은 실제 호출 가능성을 증명하지 않는다. doctor는 실제 호출 가능성을 `UNVERIFIED`로 표시하며 새 승인 LIVE 성공 전에는 `gpt-5.6-luna/low` 사용 가능성을 확정하지 않는다.
- 종료 코드가 0이 아닌 경우 stderr를 메모리에서 `MODEL_UNAVAILABLE`, `AUTH`, `INVALID_OPTION`, `SCHEMA_REJECTED`, `NETWORK`, `REASONING_UNAVAILABLE`, `MODEL_CONFIGURATION_UNAVAILABLE` 등 고정 안전 사유로 분류하고 즉시 버린다. stderr가 알려진 사유를 주지 못한 Codex 실패에만 stdout JSONL의 공식 fatal `error.message`와 `turn.failed.error.message`를 같은 고정 사유로 축약한다. `item.*`, 비공식 이벤트와 비JSON 내용은 무시하며 두 원시 버퍼 모두 반환 전에 비운다. 합성 canary fixture로 화면·로그·진단·예외 비노출을 검증했다.
- CUA에서 재현한 PowerShell 7은 `ADMIN`이었고 프로필은 일치했다. 일반 비관리자 PowerShell의 CUA 백그라운드 생성은 정책으로 차단되어 별도 실제 증거를 얻지 못했다. 전용 LIVE 실행기는 `STANDARD`만 허용하고 `ADMIN`·`UNKNOWN`을 공급자 호출 전에 차단한다.
- 제한 토큰으로 분리한 PowerShell 7은 `STANDARD`, 프로필 일치, `ConsoleHost`, 입출력 비리디렉션, `120×30`으로 확인했다. 이 환경에서 승인된 `run-20260731-142621-3d2365`도 동일한 163바이트 실패를 재현했으므로 관리자 권한이나 프로필 불일치는 단독 원인이 아니다. 실행은 Codex 1회에서 실패 폐쇄했고 Claude 0회, 모델 대체 0회, 자동 재시도 0회, 공급자 작업 잔여 0건이었다.
- 재부팅 후 8501 리스너와 Python 프로세스가 모두 0인 상태에서 같은 제한 토큰 PowerShell 7을 다시 증명했다. `run-20260731-163804-17c44b`도 Codex 1회에서 같은 안전 메타데이터로 실패했으므로 Streamlit/Uvicorn 서버 역시 단독 원인이 아니다. Claude 호출, 모델 대체, 자동 재시도와 공급자 작업 잔여는 모두 0건이었다.
- 원본 `run-20260730-021613-3e022b`는 `PAUSED_USER`를 유지하며 이 진단에서 재개하거나 공급자를 호출하지 않았다.
- 전용 `tests\Invoke-CodexInvocationMatrix.ps1`은 새 정확한 `LIVE`가 있을 때만 Sol/high 기본 호출을 양성 대조군으로 먼저 실행하고, 성공할 때 Luna/low 기본 호출과 Luna/medium 기본 호출로 모델·추론 경계를 이동한다. Luna/low 기본 호출까지 성공한 경우에만 같은 조합에 정확한 단계 스키마를 적용한다. 예상 3회, 조건 충족 시 4회, 절대 상한 4회이며 Claude·다른 모델·자동 대체·원본 실행 재개는 없다.

## 공식 기준

- [OpenAI Codex 비대화형 실행 참조](https://learn.chatgpt.com/docs/developer-commands#codex-exec)
- [OpenAI Codex 구성 및 상태 위치](https://learn.chatgpt.com/docs/config-file/config-advanced#config-and-state-locations)
- [Claude Code 인증](https://code.claude.com/docs/en/authentication)
- [Claude Code CLI 참조](https://code.claude.com/docs/en/cli-usage)
- [Claude Code API 키 환경 변수 우선순위](https://support.claude.com/en/articles/12304248-manage-api-key-environment-variables-in-claude-code)
