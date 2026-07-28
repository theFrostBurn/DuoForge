# DuoForge 다음 세션 인계

## 작업 공간과 현재 기준점

- 작업 공간: `D:\Coding\APP-windows\DuoForge`
- 브랜치: `main`
- 현재 HEAD: `bcd9d89 공급자 인증 흐름과 환경 진단을 안정화함`
- 작업 트리: 이 handoff 갱신 전 깨끗했고 `main...origin/main` 동기화 상태였다.
- 기준 문서: `require\PRD.md`, `docs\IMPLEMENTATION_PLAN.md`, `README.md`
- 현재 모듈 버전: `0.8.0`
- 2026-07-28 마지막 전체 오프라인 회귀: `통과 78, 실패 0`
- 이번 인계의 목표: Codex/Claude 문서 소유 모델에서 A/B 문서 계보 모델로 바꾼 마이그레이션의 남은 결함과 계약 공백을 테스트 우선으로 수정한다.

인증 안정화와 일반 `doctor`/최초 로그인 `$Validation` 예외 수정은 `bcd9d89`에서 완료됐다. 이번 세션은 인증을 다시 설계하는 작업이 아니라 A/B 마이그레이션 정합성 보강이 중심이다.

## 먼저 읽을 파일

1. `NEXT_SESSION_HANDOFF.md`
2. `require\PRD.md` — 특히 10.4~10.5, FR-COM-067~073, 17.1, 출시·완료 게이트
3. `docs\IMPLEMENTATION_PLAN.md`
4. `README.md`
5. `src\DuoForge\Private\09.Requests.ps1` — A/B 입력과 레거시 별칭 경계
6. `src\DuoForge\Private\10.StateStore.ps1` — 매니페스트·상태·인벤토리 역할
7. `src\DuoForge\Private\15.StageEngine.ps1` — v1/v2 그래프와 편집자 교대
8. `src\DuoForge\Private\16.StageContract.ps1` — 단계 결과·내부 계보 검증
9. `src\DuoForge\Private\17.PromptBuilder.ps1` — v1/v2 프롬프트와 `issueKey`
10. `src\DuoForge\Private\19.ArtifactRenderer.ps1` — 쟁점·판단·채택 병합과 최종 파일
11. `src\DuoForge\Private\20.RunCoordinator.ps1`, `13.ProgressView.ps1` — v1 재개 전 그래프 복원
12. `src\DuoForge\Private\24.Evidence.ps1` — A/B 추가 근거 확정 결함
13. `schemas\stage-result-v2.schema.json`, `schemas\issue.schema.json`
14. `tests\Run-Tests.ps1`, `tests\Test-WorkflowV2LiveRun.ps1`

## 확정 제품 모델과 보존 경계

- A/B는 공급자나 최초 작성자가 아니라 실행 안의 안정적인 문서 계보다.
- Codex와 Claude는 교체 가능한 검토자·응답자·편집자·합성자·검증자다.
- `performedBy`는 감사용 단계 작업자이며 문서 소유권이 아니다.
- 신규 실행은 `workflow-v2`로 만들고, 버전이 없는 저장 실행은 `workflow-v1`로 해석한다.
- v1의 `roles.codex/claude`, `owner-response`, `owned-document-revision`, `ownerDecisions`, `codex-final.md`, `claude-final.md` 의미와 저장 원본을 v2로 묵시 승격하거나 재작성하지 않는다.
- v2는 A/B 계보, `targetDocumentId`, `sourceDocumentIds`, `performedBy`, `editorialDecisions`, `reviewerVerdicts`, `adoptions`를 서로 다른 축으로 보존해야 한다.
- 모드 4 `dual-project-audit`의 `DF-PREFLIGHT-3A-ISOLATION` 게이트는 계속 닫아 둔다.

## 이번 세션에서 완료한 읽기 전용 검토

- 구현·PRD·handoff·스키마·테스트와 저장 실행 메타데이터를 대조했다.
- PowerShell 7 전체 회귀를 다시 실행해 `통과 78, 실패 0`을 확인했다.
- 저장된 workflow-v2 세 실행을 현재 강화 검증기로 다시 검사했다.
  - `run-20260728-033711-fad8f8`: `shared-document`, `13/13`, `AWAITING_USER`
  - `run-20260728-040441-2cb68c`: `document-merge`, `13/13`, `AWAITING_USER`
  - `run-20260728-095906-127f6d`: `dual-document`, `14/14`, `AWAITING_USER`
- 세 실행 모두 입력·스냅샷 해시, 상위 단계의 provider/performedBy/target/sources, 최종 파일과 이벤트·로그 비노출 검증을 통과했다.
- 최신 `dual-document` 저장 그래프는 R1 `Codex→A / Claude→B`, R2 `Claude→A / Codex→B`, 마지막 편집자의 반대 공급자 검증으로 실제 작업자·계보 분리를 확인했다.
- 기존 v1 완료 실행 `run-20260727-155148-7617d3`은 12/12 단계, 공급자 역할, 레거시 단계와 `codex-final.md`/`claude-final.md`를 그대로 유지한다.
- 저장된 v2 쟁점 원장에는 레거시 `ownerDecisions`가 없지만, 세 실행 모두 `reviewerVerdicts` 항목 수가 0이었다.
- 파일 수정, 실제 공급자 호출, 저장 실행 재개, 사용자 질문 답변은 하지 않았다.

## 확정 결함 — 먼저 수정

### P0 — A/B 문서 모드의 추가 근거 연결 실패와 고아 파일

- `10.StateStore.ps1`은 모드 2·3 인벤토리를 `roles.documents.A/B`로 만든다.
- `24.Evidence.ps1:65-71`은 비공동 문서 실행에서 여전히 `roles.codex/claude.context`를 갱신한다.
- StrictMode에서 없는 역할의 `.context` 대입이 실패한다.
- 근거 스냅샷을 먼저 복사하므로 실패 뒤 인벤토리에 없는 `E000001.md`가 남고, 재시도는 `DF-EVIDENCE-SNAPSHOT-EXISTS`로 막힐 수 있다.
- 현재 근거 추가 회귀는 `shared-document`만 다룬다.
- 수정은 파일 복사·인벤토리·매니페스트·쟁점·단계 무효화를 하나의 실패 원자적 흐름으로 만들고, 모드 2·3 각각 성공·실패·재시도·고아 0건을 검증해야 한다.

### P0 — 검토자 평가와 실제 편집 판단이 섞임

- v2 그래프의 `review-response`는 A/B 전체 검토에 대한 응답이고, 실제 문서 편집은 뒤의 `document-revision`이 담당한다.
- `19.ArtifactRenderer.ps1:236-266`은 모든 v2 `issueResponses`를 `editorialDecisions`로 기록하고 해결 상태까지 바꾼다.
- `reviewerVerdicts`는 초기화만 되고 채우는 경로가 없다.
- 편집 판단 레코드에는 문서 대상과 `performedBy`가 충분히 남지 않는다.
- `review-response`는 검토자 평가 축으로, 대상 문서의 실제 채택·편집 판단은 `document-revision`/`adoptions` 축으로 분리하고, 실제 반영 없이 `RESOLVED`가 되지 않도록 테스트한다.

### P0 — 내부 A/B 계보와 상위 단계 계약의 교차 검증 누락

- `16.StageContract.ps1`은 상위 `performedBy`, `targetDocumentId`, `sourceDocumentIds`를 예상 단계와 대조한다.
- 내부 `issues.targetDocumentId`, 증거의 `sourceDocumentId`, `adoptions.targetDocumentId/sourceDocumentId`는 전역 enum만 확인한다.
- 문서 A 개정 단계에 B 또는 `merged` 대상의 쟁점·채택, 허용 출처 밖 근거를 넣어도 수동 검증을 통과할 수 있다.
- 단계별 허용 행렬을 정의하고 검증한다. 예: `document-review`의 쟁점 대상은 A/B, `document-revision(target=A)`의 편집·채택 대상은 A, `document-validation(target=A)`의 신규 쟁점 대상도 A다.

### P0 — `issueKey` 참조 무결성과 충돌 방지 누락

- 프롬프트의 권장 키는 공급자·라운드만 포함하고 단계·문서 대상이 없다.
- 원장 병합은 `issueKey` 전역 문자열만으로 응답·채택·질문을 연결한다.
- 같은 키의 A/B 쟁점을 합성하면 한 문서의 응답이 다른 문서 쟁점에 연결되는 현상을 오프라인으로 재현했다.
- 키 생성에 단계/대상 또는 실행 내 안정 식별자를 포함하고, 중복 키·dangling 참조·대상 불일치를 저장 전에 실패 폐쇄하는 테스트를 추가한다.

## 중요 계약 공백 — P0 수정 뒤 정리

1. **신규 저장 계약 불일치**
   - PRD는 신규 매니페스트에 `inputs.documentA/documentB`, `roles.documents.A/B`, 상태에 `workflowVersion`을 요구한다.
   - 실제 매니페스트에는 `inputs`와 `roles`가 없고, 역할은 `inputs/inventory.json`에만 있으며 `state.json`에도 버전이 없다.
   - 원문 경로 최소 저장 원칙과 외부 소비자 계약을 함께 검토해 한 구조를 권위 계약으로 확정하고 PRD·코드·테스트를 일치시킨다.
2. **v2 쟁점 원장 버전 부재**
   - `schemas/issue.schema.json`은 여전히 v1의 `target` 계약이고, v2 `issues.json`도 `schemaVersion=1`이다.
   - v2 전용 원장 스키마나 명확한 버전 표지를 도입하고 `target`/`ownerDecisions` 혼입을 차단한다.
3. **공개 요청 검증 우회**
   - 요청 생성기와 CLI는 정규·레거시 경로 충돌을 차단하지만, 직접 만든 `IDictionary`를 `Test-DuoForgeStartRequest`에 전달하면 레거시 충돌·미지 필드가 남을 수 있다.
   - 공개 검증 경계에서도 재정규화하거나 허용 필드 외 입력을 실패 폐쇄한다.
4. **컨텍스트 레거시 별칭 누락**
   - PRD의 `--codex-context/--claude-context` 변환·경고 계약이 구현되지 않았고 현재 CLI에서 조용히 무시될 수 있다.
   - 지원할 계약이면 A/B로 변환·경고하고, 폐기할 계약이면 PRD를 고치고 unknown 옵션을 오류 처리한다.
5. **v1 재개 전 표시와 프롬프트 보존**
   - `steps.json`이 없는 v1 실행에서 `20.RunCoordinator.ps1`과 `13.ProgressView.ps1`이 버전을 넘기지 않아 v2 기본 그래프를 만들 수 있다.
   - 같은 `duoforge-stage-v2` 이름 아래 v1 프롬프트 DATA에 v2 상위 필드가 추가된 상태다.
   - 완전한 비민감 v1 fixture로 manifest→inventory→steps→artifact→ledger→final 조회·재개·재렌더링과 저장 해시 불변을 고정한다.
6. **버전·스키마 교차 검증**
   - manifest/steps/stage result/ledger/state의 버전 불일치와 v2에서 버전 표지가 사라진 경우를 공급자 호출 전에 차단한다.
7. **실제 E2E 증거 범위**
   - 저장된 v2 세 실행은 모두 `AWAITING_USER`이며 사용자 결정 뒤 `COMPLETED`까지의 라이브 증거는 아니다.
   - 우선 가짜 공급자 E2E로 모드 2·3의 결정→선택 무효화→재개→완료를 검증한다. 실제 호출은 별도 동의 없이는 하지 않는다.

## 권장 구현 순서

1. 현재 상태와 기준 테스트 `78/78`을 재현한다.
2. 추가 근거 P0에 대한 실패 회귀를 모드 2·3으로 먼저 만들고 최소 수정한다.
3. 쟁점 원장의 `reviewerVerdicts`/`editorialDecisions`/`adoptions` 의미와 레코드 필드를 PRD 기준으로 확정한 뒤 실패 회귀와 구현을 추가한다.
4. 단계별 내부 A/B 허용 행렬과 `issueKey` 참조 무결성을 실패 폐쇄한다.
5. 공개 입력·레거시 컨텍스트 별칭·unknown 옵션 경계를 정리한다.
6. manifest/state/inventory/ledger의 권위 저장 계약과 버전을 정렬한다.
7. v1 전체 fixture와 v2 모드 2·3 사용자 결정 후 완료 E2E를 추가한다.
8. 전체 회귀, 구문·JSON·diff 검사와 저장 실행 메타데이터 검증을 수행한다.

## 검증 명령

기준 및 각 구현 슬라이스 후:

```powershell
& 'C:\Program Files\PowerShell\7\pwsh.exe' -NoProfile -File '.\tests\Run-Tests.ps1'
```

저장된 v2 메타데이터 재검증만 필요할 때:

```powershell
& 'C:\Program Files\PowerShell\7\pwsh.exe' -NoProfile -File '.\tests\Test-WorkflowV2LiveRun.ps1' -RunId 'run-20260728-033711-fad8f8' -Mode 'shared-document'
& 'C:\Program Files\PowerShell\7\pwsh.exe' -NoProfile -File '.\tests\Test-WorkflowV2LiveRun.ps1' -RunId 'run-20260728-040441-2cb68c' -Mode 'document-merge'
& 'C:\Program Files\PowerShell\7\pwsh.exe' -NoProfile -File '.\tests\Test-WorkflowV2LiveRun.ps1' -RunId 'run-20260728-095906-127f6d' -Mode 'dual-document'
```

마지막 공통 검사:

```powershell
git diff --check
git status --short
```

## 작업 중 안전 경계

- 실제 로그인·로그아웃·브라우저·모델 호출 없이 오프라인 회귀와 정제된 저장 메타데이터만 사용한다.
- 이메일, 조직 ID, 인증 원문, 토큰, API 키와 인증 파일 내용을 출력하거나 저장하지 않는다.
- 기존 `AWAITING_USER` 실행을 재개하거나 질문에 답하지 않는다.
- 저장된 v1/v2 실행 원본을 수정하거나 마이그레이션하지 않는다. 재현은 테스트용 임시 fixture에서 수행한다.
- 실제 공급자 호출이 정말 필요하면 실행 전에 Claude `sonnet/low`, 공급자별 예상 호출 수와 새롭고 정확한 `LIVE` 동의를 요청한다.
- 모드 4 격리 게이트와 원문 공급자 출력·문서·프롬프트·컨텍스트 비노출 경계를 유지한다.

## 추천 스킬

- 별도의 구현 스킬은 필요하지 않다. PowerShell 코드와 PRD, 저장 형식, 테스트를 직접 대조하는 것이 가장 정확하다.
- 다음 작업 종료 시 `handoff` 스킬로 수정 파일, 새 테스트 수, 남은 위험과 커밋 상태만 갱신한다.
