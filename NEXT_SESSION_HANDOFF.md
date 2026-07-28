# DuoForge 다음 세션 인계

## 작업 공간과 기준점

- 작업 공간: `D:\Coding\APP-windows\DuoForge`
- 브랜치: `main`
- 문서 모델 확정 커밋: `666d58e865f789a06abc3b7db028e7c2dd30b3dc`
- 모드 확장 구현 커밋: `db5b62ae929a107fd501d5ffea85f697b6aefb2d`
- workflow-v2 실제 공급자 검증 기준 커밋: `42bc6ef`
- 이후 종료 정리 커밋은 `git log -2 --oneline`을 현재 기준으로 확인한다.
- 기준 문서: PRD v1.6, `docs\IMPLEMENTATION_PLAN.md`
- 2026-07-28 마지막 오프라인 검증: PowerShell 7 회귀 `통과 68, 실패 0`
- 2026-07-28 workflow-v2 실제 공급자 E2E: 모드 1 `13/13`, 모드 2 `13/13`, 모드 3 `14/14` 단계 커밋
- 종료 판정: 세 실행의 `AWAITING_USER`는 질문 카드 사용자 게이트까지 정상 도달한 실제 E2E 성공 체크포인트이며 추가 공급자 호출 없이 문서 모드 확장 Beta 검증을 완료한다.
- 다음 세션의 새 목표: Codex·Claude 최초 로그인, 상태 진단과 로그인 후 재검사 경로를 안정화한다.
- 2026-07-28 인증 검토는 읽기 전용으로 수행했으며 로그인·로그아웃·브라우저 실행·모델 호출은 없었다.

## 먼저 읽을 파일

1. `NEXT_SESSION_HANDOFF.md`
2. `require\PRD.md`
3. `docs\IMPLEMENTATION_PLAN.md`
4. `README.md`
5. `src\DuoForge\Private\13.CliView.ps1` — 일반 `doctor` 출력의 확정 버그
6. `src\DuoForge\Private\08.Providers.ps1` — 인증 상태 파서, 공급자 진단과 인증 게이트
7. `src\DuoForge\Private\07.Process.ps1` — CLI 실행 파일 선택과 자식 프로세스 환경
8. `src\DuoForge\Private\14.Interactive.ps1` — 안내형 로그인과 로그인 후 재검사
9. `src\DuoForge\Private\18.ProviderAdapters.ps1` — 실제 공급자 호출 환경 허용 목록
10. `src\DuoForge\Private\08.ModelSelection.ps1` — Codex 모델 조회의 사용자 프로필 해석
11. `tests\Run-Tests.ps1` — 현재 인증 회귀와 새 테스트 추가 위치

## 확정 제품 모델

| 화면 모드 | 내부 ID | 입력 | 결과 | 현재 상태 |
|---|---|---|---|---|
| 1. 컨셉으로 공동 문서 만들기 | `shared-document` | brief 또는 컨셉 C | 공동 문서 C' | 실제 공급자 13/13, 사용자 결정 대기 |
| 2. 두 문서를 하나로 합의하기 | `document-merge` | 문서 A/B | 합의 문서 C와 출처 추적표 | 실제 공급자 13/13, 사용자 결정 대기 |
| 3. 두 문서를 각각 개선하기 | `dual-document` | 문서 A/B | A'/B'와 문서별 채택 기록 | 수정 후 실제 공급자 14/14, 사용자 결정 대기 |
| 4. 두 프로젝트 비교하기 | `dual-project-audit` | 프로젝트 A/B | 비교 결과 | 격리 게이트 폐쇄 |

- A/B는 공급자나 최초 작성자가 아니라 실행 안의 안정적인 문서 계보다.
- Codex와 Claude는 교체 가능한 검토자·응답자·편집자·합성자·검증자다.
- `performedBy`는 감사용 단계 작업자이며 문서 소유권이 아니다.
- 기존 실행을 새 의미로 묵시적으로 재해석하거나 저장된 단계·산출물을 다시 쓰지 않는다.

## 새 세션의 현재 목표와 인증 검토 결과

쿠키님은 최초 Codex·Claude 로그인 과정, 특히 Codex 인증이 샌드박스 안팎에서 다르게 감지되던 문제를 안정화하도록 요청했다. 아직 코드는 수정하지 않았다.

### 확정 재현

- 일반 호스트 PowerShell 7에서는 `codex login status`가 종료 코드 0으로 ChatGPT 구독 로그인을 확인했다.
- 같은 호스트의 `claude auth status`도 종료 코드 0이며 `claude.ai` 구독 로그인으로 확인됐다.
- 호스트에서 `duoforge doctor --json`은 두 공급자를 모두 구독 인증으로 판정하고 `readyForDocumentModes=true`를 반환했다.
- Codex 샌드박스에서는 `USERPROFILE=C:\Users\user`지만 .NET 사용자 프로필이 `C:\Users\CodexSandboxOffline`로 해석되고 `CODEX_HOME`은 비어 있었다. 이 상태의 `codex login status`는 종료 코드 1, DuoForge는 Codex를 미로그인으로 오판했다.
- 샌드박스 자식 프로세스에 `CODEX_HOME=C:\Users\user\.codex`를 임시 지정하면 상태 조회는 성공하지만 `.codex\tmp` 쓰기 제한 경고가 발생했다. 따라서 인증 파일이 보인다는 이유만으로 샌드박스 내 실제 모델 호출까지 준비됐다고 판정하지 않는다.

### 확정 결함과 테스트 공백

1. **P0 — 최초 로그인 화면과 일반 `doctor` 출력 중단**
   - `src\DuoForge\Private\13.CliView.ps1:52-55`의 `Write-DuoForgeDoctorReport`가 매개변수에 없는 `$Validation.contextPlan`을 참조한다.
   - 모듈의 `StrictMode Latest` 때문에 `duoforge doctor`는 `The variable '$Validation' cannot be retrieved because it has not been set.`으로 종료 코드 1을 반환했다.
   - 로그인이 준비되지 않은 최초 설정 화면은 로그인 선택지를 출력하기 전에 같은 렌더러에서 중단될 수 있다.
   - JSON 진단은 이 렌더러를 거치지 않아 동작한다.
2. **High — 인증 실행 컨텍스트 불일치**
   - 상태 진단은 `Resolve-DuoForgeCommandInvocation`이 Application인 `codex.cmd`를 우선한다.
   - 안내형 로그인은 `& codex login`을 직접 호출해 현재 PowerShell에서는 `codex.ps1`이 선택될 수 있다.
   - doctor, 안내형 로그인, 모델 조회와 실제 공급자 호출이 동일한 CLI 해석·인증 홈 계약을 공유하지 않는다.
3. **High — 상태 실패 원인 손실**
   - Codex 상태 실패, 타임아웃, 접근 거부와 샌드박스 프로필 불일치가 모두 단순 미로그인으로 접혀 재로그인만 권한다.
   - 샌드박스나 비대화형 환경에서는 브라우저 로그인을 시작하지 말고 인증 컨텍스트를 확인할 수 없는 상태와 실제 미로그인을 구분해야 한다.
4. **회귀 테스트 공백**
   - 현재 68개 테스트는 인증 성공 파싱, 개인정보 제거, 일부 API 환경 변수 차단, 가짜 인증 게이트를 검증한다.
   - 일반 doctor 렌더링, 최초 로그인 메뉴, 로그인 후 재검사, `USERPROFILE`/`.NET UserProfile`/`CODEX_HOME` 불일치, 동일 실행 파일 사용과 접근 거부 분류는 검증하지 않는다.

### 안전한 수정 방향

- `Write-DuoForgeDoctorReport`에서 잘못 들어간 문맥 배치 블록을 제거하고, 필요하면 `Write-DuoForgeExecutionPlan`으로 옮긴다.
- 인증 상태 조회와 안내형 로그인에 사용할 CLI 실행 파일·인증 홈·자식 환경을 하나의 공통 계약으로 만든다. 명시적인 `CODEX_HOME`은 존중하고 부모 프로세스 환경을 전역 변경하지 않는다.
- 일반 호스트 PowerShell과 Codex 샌드박스를 구분한다. 샌드박스에서는 인증 파일 조회 성공만으로 라이브 실행을 허용하지 말고, 안전한 호스트 PowerShell 7에서 다시 실행할 명령을 안내한다.
- 실제 브라우저 로그인 없이 process runner 또는 상태 결과를 주입할 수 있게 하여 성공·취소·상태 미확인·한쪽만 성공·재검사 흐름을 오프라인 테스트한다.
- Codex/Claude 상태 파서의 미로그인·API 방식·형식 변경·비영 종료 코드·손상 JSON 행렬과 여섯 API 우선 환경 변수 전체를 회귀로 고정한다.
- 진단과 테스트에서는 이메일, 조직 ID, 토큰, API 키, 인증 파일 내용과 원문 상태 JSON을 출력하거나 저장하지 않는다.

## 완료된 작업

- PRD, 구현 계획, README와 UI 용어를 네 화면 모드 및 A/B 계보로 정렬했다.
- 신규 실행은 `workflow-v2`, `DocumentA/DocumentB`, 정규 `inputs.documentA/documentB`만 저장한다.
- 레거시 `CodexDocument/ClaudeDocument`, `--codex/--claude` 입력은 A/B로 변환하고 경고하며, 정규 입력과 충돌하면 실패 폐쇄한다.
- `workflowVersion`이 없는 실행은 `workflow-v1`로 읽고 기존 단계 그래프, 프롬프트, 파일 의미와 저장 원본을 보존한다.
- 모드 2는 독립 병합 후보, 교차 검토·응답, 합성·검증을 거쳐 합의 문서와 `source-trace.md`를 만든다.
- 모드 3은 두 공급자가 A/B 모두를 검토하고 라운드별 편집자를 교대하며 A'/B' 및 문서별 채택 기록을 만든다.
- v2 결과는 `performedBy`, 대상 문서, 출처 문서 집합, 증거 위치·해시와 채택 판단을 엄격히 검증한다.
- 진행 이벤트는 메타데이터만 싣고 원문 공급자 출력, 프롬프트·문서·컨텍스트 내용과 비밀값을 싣지 않는 회귀를 고정했다.
- 모드 4는 `DF-PREFLIGHT-3A-ISOLATION`으로 모델 호출 전에 계속 차단한다.
- 중립 A/B 라이브 픽스처, 정확한 `LIVE` 동의 실행기와 메타데이터 전용 검증기를 추가했다.
- workflow-v2 실제 공급자 E2E에서 모드 1은 Codex 7회·Claude 6회, 모드 2는 7회·6회, 모드 3은 7회·7회로 계획과 일치했다.
- 세 실행 모두 입력 SHA-256 불변, 스냅샷 해시, 단계 스키마·계보, 최종 파일, 이벤트·로그 비노출과 빈 `provider-work`를 통과했다.
- 라이브에서 발견한 모듈 클로저의 private 함수 해석 문제와 Codex 구조화 출력 스키마의 `uniqueItems` 호환성 문제를 수정하고 68개 회귀를 다시 통과했다.
- 모드 3 실제 결과에서 Minor 근거 대기 쟁점이 잘못 차단 상태로 남는 의미 결함을 발견했다. 렌더러가 모든 병합 뒤 중앙 심각도 규칙으로 차단 여부를 다시 계산하도록 수정하고, 강화 검증기가 수정 전 실행을 거부하는 회귀를 추가했다.
- 수정 코드를 기존 14개 커밋 결과에 비변경 재계산한 예상 상태는 `AWAITING_USER`이며, 차단 근거 대기 0건·사용자 결정 대기 7건이다.
- 수정 후 신규 실행 `run-20260728-095906-127f6d`는 14/14 단계, Codex 7회·Claude 7회, `AWAITING_USER`로 강화 검증을 통과했다. 입력 해시·스냅샷 4개·A/B 최종 파일·비노출 경계가 모두 유효하고 Critical/Major 사용자 결정 차단 4건과 상태가 일치한다.
- 세 통과 실행의 질문은 테스트 픽스처가 사용자 게이트를 검증하며 생성한 결과다. 임의의 권장 답변으로 `COMPLETED`를 만들지 않고 `AWAITING_USER`를 성공 증거로 보존하기로 확정했다.
- 모드 2 최종 C는 공통 문서 유형 파일명 계약을 사용한다. PRD 입력의 안정 동작은 `final\PRD.md`이며 PRD의 `merged-final.md` 표기를 이 계약에 맞췄다.
- 모든 실제 공급자 E2E 실행기는 테스트 전용 Claude 설정 `sonnet/low`와 정확한 `LIVE` 동의를 요구하도록 통일했다.

## 현재 경계와 주의사항

- 모드 1~3의 2라운드 가짜 공급자 E2E, 실제 공급자 전체 단계 E2E와 전체 오프라인 회귀는 완료됐다.
- 기존 라이브 결과는 `workflow-v1 shared-document/dual-document`의 역사적 증거일 뿐이다. 신규 `document-merge`나 `workflow-v2 dual-document`의 라이브 완료로 간주하지 않는다.
- 신규 라이브 통과 증거는 `run-20260728-033711-fad8f8`(`shared-document`, `AWAITING_USER`), `run-20260728-040441-2cb68c`(`document-merge`, `AWAITING_USER`), `run-20260728-095906-127f6d`(`dual-document`, `AWAITING_USER`)이다. 수정 전 `run-20260728-043711-14a4b7`은 상태 의미 검증 실패 감사 증거로만 보존한다. 어느 실행도 `COMPLETED` 증거로 과장하지 않는다.
- 세 통과 실행에는 Claude `opus/high`가 저장되어 있다. 이 선택 계보와 결과는 재작성하지 않으며, 해당 실행을 추가 공급자 호출로 재개하지 않는다.
- `AWAITING_USER` 질문 33개는 감사 결과로 보존하되 제품 검증을 위해 임의로 답하지 않는다. 그중 차단 질문이 있다는 사실은 사용자 게이트가 의도대로 작동했다는 증거이며 미완료 구현을 뜻하지 않는다.
- 이후 실제 공급자 E2E가 새 코드 변경 때문에 다시 필요할 때는 기존 실행 재개가 아니라 새 실행을 만들고 `tests\workflow-v2-live-settings.json`의 Claude `sonnet/low`를 사용한다.
- 실제 공급자 호출은 사용자가 새 호출 범위와 예상 호출 수를 확인하고 다시 정확히 `LIVE`라고 동의한 뒤에만 시작한다. 현재 종료 정리에는 새 공급자 호출이 필요하지 않다.
- 제품의 일반 모델 선택 화면과 이미 저장된 실행의 선택값은 변경하지 않는다.
- 실패한 사전 실행 `run-20260728-033334-e6eb4a`, `run-20260728-033532-b5bde7`은 각각 private 함수 해석과 공급자 스키마 호환성 결함의 감사 증거로 보존한다.
- 모드 4의 기능 플래그나 격리 게이트를 열지 않는다.
- 원문 공급자 출력, stdout·stderr, 프롬프트·문서·컨텍스트 내용, 생성 중 텍스트와 비밀값을 로그·진행 이벤트에 추가하지 않는다.
- Git이 사용자 프로필의 전역 ignore 파일을 읽을 때 권한 경고를 낼 수 있으나 현재 저장소 검증과 커밋에는 영향을 주지 않았다.

## 검증 명령과 마지막 결과

시작 전과 주요 구현·검증 슬라이스마다 다음 기준 테스트를 실행한다.

```powershell
& 'C:\Program Files\PowerShell\7\pwsh.exe' -NoProfile -File '.\tests\Run-Tests.ps1'
```

마지막 결과:

- 회귀 테스트: `통과 68, 실패 0` (약 30초)
- workflow-v2 실제 공급자 실행: 호출 시작 55회, 완료·단계 커밋 54회. 초기 스키마 호환성 결함 실행의 1회만 커밋되지 않았고 공급자 실패 이벤트는 0건
- 라이브 검증기: 모드 1·2와 수정 후 모드 3 통과, 수정 전 모드 3은 `WAITING_STATUS_WITHOUT_BLOCKING_ISSUE`로 정확히 거부
- 공통 안전 검증: 입력 해시 불변, 스냅샷 `1/4/4/4`개 검증, 금지 이벤트·데이터 키·문서 카나리·공급자 작업 잔여 각 0건
- `git diff --check`: 통과
- 신규 v2 스키마 포함 JSON 파싱: 통과
- PowerShell 구문 검사: 오류 0
- 제품 코드 비밀 패턴 점검: 후보 0
- 종료 정리 중 실제 공급자 추가 호출: 0회

## 다음 작업

1. `git status --short`, `git log -3 --oneline`과 이 인계 문서를 확인한다. handoff 갱신 외 예상하지 못한 변경이 있으면 먼저 쿠키님께 알린다.
2. 기준 테스트를 실행해 수정 전 `통과 68, 실패 0`을 재현한다.
3. 실제 로그인·로그아웃 없이 `duoforge doctor`의 `$Validation` 예외를 재현하는 회귀 테스트를 먼저 추가하고 렌더러를 수정한다.
4. 인증 실행 컨텍스트를 공통화하고 샌드박스 프로필 불일치와 실제 미로그인을 구분한다. 안내형 로그인은 대화형 호스트에서만 허용한다.
5. 가짜 프로세스 결과로 로그인 성공·취소·상태 미확인·해당 공급자 재검사와 한쪽 성공 보존을 테스트한다.
6. 전체 오프라인 회귀, 일반/JSON doctor와 PowerShell 구문 검사를 실행한다. 일반 호스트 상태 비교는 `codex login status`, `claude auth status`, `duoforge doctor --json`의 종료 코드와 정제된 필드만 사용한다.
7. 인증 안정화에는 모델 호출이 필요하지 않다. 실제 공급자 E2E가 필요하다고 판단되면 실행하지 말고 Claude `sonnet/low`, 공급자별 예상 호출 수와 새 `LIVE` 동의를 먼저 요청한다.
8. 기존 workflow-v2 통과 실행을 재개하거나 질문에 답하지 않고, 모드 4 격리 게이트와 모든 비노출 경계를 유지한다.

## 추천 스킬

- 인증 안정화 구현에는 별도 스킬이 필요하지 않다. 저장소 코드, 공식 공급자 CLI 계약과 PowerShell 테스트를 기준으로 한다.
- 작업 종료 후 다시 새 세션으로 넘길 때 `handoff` 스킬을 사용해 수정 파일, 테스트 수와 남은 위험만 갱신한다.
