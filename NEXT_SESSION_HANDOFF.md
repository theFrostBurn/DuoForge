# DuoForge 다음 세션 인계

## 작업 공간과 현재 상태

- 작업 공간: `D:\Coding\APP-windows\DuoForge`
- 기준 브랜치: `main`
- 기준 커밋: `37fab921d3c5cf5336083c573833368f21e92971` (`검증된 토론 진행을 풀스크린으로 확인할 수 있게 함`)
- 이 인계 작성 전 작업 트리는 깨끗했다. 이번 세션에서는 모드 확장 코드를 수정하지 않았고 이 파일만 새로 만들었다.
- 현재 구현은 PRD v1.5의 `shared-document`, `dual-document` Core Beta다. `dual-project-audit`는 Windows 격리 실패로 비활성화되어 있다.
- 기본 결과 루트 `D:\Coding\APP-windows\DuoForge\results`와 원본 불변·출력 경계 정책은 유지한다.

## 먼저 읽을 파일

1. 이 파일
2. `require\PRD.md`
3. `docs\IMPLEMENTATION_PLAN.md`
4. `src\DuoForge\Private\09.Requests.ps1`
5. `src\DuoForge\Private\10.StateStore.ps1`
6. `src\DuoForge\Private\15.StageEngine.ps1`
7. `src\DuoForge\Private\17.PromptBuilder.ps1`
8. `src\DuoForge\Private\19.ArtifactRenderer.ps1`
9. `src\DuoForge\Private\14.Interactive.ps1`, `src\DuoForge\Public\Cli.ps1`
10. `tests\Run-Tests.ps1`

## 현재 목표와 사용자 확정 사항

문서 모드를 다음 네 가지로 재정의하고 구현한다.

| 화면 번호 | 사용자 목적 | 입력 | 최종 결과 | 권장 내부 ID |
|---|---|---|---|---|
| 모드 1 | 컨셉으로 공동 문서 만들기 | 간략한 컨셉 문서 C 1개 | 합의 문서 C' 1개 | 기존 `shared-document` 유지 |
| 모드 2 | 두 문서를 하나로 합의하기 | 문서 A와 B, 각 문서 폴더의 보조 Markdown | 새 합의 문서 C 1개 | 새 `document-merge` 추가 |
| 모드 3 | 두 문서를 각각 개선하기 | 문서 A와 B, 각 문서 폴더의 보조 Markdown | 개선 문서 A'와 B' 2개 | 기존 `dual-document` 유지 |
| 모드 4 | 두 프로젝트 비교하기 | 프로젝트 A와 B | 비교 결과 | 기존 `dual-project-audit` 유지, 비활성 표시 |

핵심 교정 사항은 다음과 같다.

- 문서를 `Codex 문서`와 `Claude 문서`로 모델링하지 않는다. 입력과 문서 계보는 **문서 A/B**다.
- Codex와 Claude는 문서 소유자가 아니라 교체 가능한 검토자·편집자·합성자·검증자다.
- 모드 3에서도 A/B의 문서 정체성과 계보만 유지한다. 특정 AI가 특정 문서를 영구 소유하지 않는다.
- 모드 2는 A/B를 동등한 출처로 취급하여 C를 만든다. 어느 공급자의 문서를 기준본으로 암묵 지정하지 않는다.
- 화면의 번호는 프레젠테이션 개념이다. 기존 내부 ID와 완료·재개 가능한 실행 기록은 가능한 한 보존한다.

## 현재 코드와 목표 사이의 차이

현재 `dual-document`는 다음 위치에서 문서와 공급자를 강하게 결합한다.

- 요청 필드: `CodexDocument`, `ClaudeDocument`, `inputs.codexDocument`, `inputs.claudeDocument`
- 검증·인벤토리 역할: `inputs.codex/claude`, `roles.codex/claude`
- CLI: `--codex`, `--claude`
- 메뉴 문구: `Codex 측`, `Claude 측`
- 단계: `owner-response`, `owned-document-revision`
- 프롬프트: `자신이 소유한 문서`
- 결과: `codex-final.md`, `claude-final.md`
- 쟁점·채택 기록: `ownerDecisions`, `sourceProvider`

따라서 메뉴 이름만 바꾸면 안 된다. 요청, 스냅샷 역할, 단계 그래프, 프롬프트 계약, 결과 스키마, 렌더러, 재개 호환성을 함께 변경해야 한다.

## 권장 도메인 모델

새 실행의 정규형은 공급자와 문서를 분리한다.

```text
documents:
  brief                         # 모드 1
  A: primary + context[]        # 모드 2·3
  B: primary + context[]        # 모드 2·3

stage assignment:
  performedBy: codex | claude
  targetDocumentId: A | B | merged | null
  sourceDocumentIds: [A, B] | [brief]
```

권장 필드 이름:

- 요청: `DocumentA`, `DocumentB`; JSON은 `inputs.documentA`, `inputs.documentB`
- 인벤토리: `roles.documents.A`, `roles.documents.B`
- 프롬프트 역할: `document-a-primary`, `document-a-context`, `document-b-primary`, `document-b-context`
- 단계 할당: `targetDocumentId`, `performedBy`
- 채택 출처: `sourceDocumentId`와 `proposedByProvider`를 분리
- 편집 판단: `editorialDecisions` 또는 `documentDecisions`; 신규 스키마에서 `ownerDecisions` 용어를 사용하지 않는다.

`performedBy`는 감사 추적용이며 문서 소유권을 뜻하지 않는다. A/B는 파일명이나 작성 주체가 아니라 한 실행 안의 안정적인 문서 계보 ID다.

## 모드별 권장 단계 그래프

### 모드 1: `shared-document`

현재 검증된 그래프를 유지한다.

1. brief 고정
2. 두 공급자가 독립 전체 초안 작성
3. 양쪽 초안 완료 후 교차 검토
4. 작성자 응답
5. 합성 담당이 공동 문서 생성
6. 2~3라운드에서 공동 문서 검토·응답·교대 합성
7. 마지막 합성자가 아닌 공급자가 최종 검증

첫 두 초안은 임시 경쟁 초안이며 최종 산출물은 하나다.

### 모드 2: `document-merge`

모드 1과 같은 수렴 엔진을 재사용하되 첫 단계와 출처 추적을 분리한다.

라운드 1:

1. 문서 A/B와 각 보조 문맥을 같은 시점에 고정
2. 두 공급자가 모두 A/B를 보고 각각 완성된 병합 후보 C를 작성 (`independent-merge-draft` 권장)
3. 두 후보가 모두 끝난 뒤 교차 검토
4. 각 공급자가 받은 지적에 응답
5. 합성 담당이 A/B 출처와 채택·거부 이유를 보존하면서 공동 문서 C v1 생성

라운드 2~3:

1. 현재 C와 A/B 출처 추적표를 고정
2. 두 공급자가 독립 검토
3. 검토 응답
4. 합성 담당 교대 후 C 다음 버전 생성
5. 마지막 합성자가 아닌 공급자가 최종 검증

필수 결과:

- 최종 합의 문서 1개
- A/B 요구사항·아이디어의 채택, 부분 채택, 거부, 미결정과 반영 위치를 보여주는 출처 추적표
- 토론 요약, 사용자 결정, 열린 질문

### 모드 3: `dual-document`

특정 공급자와 문서를 고정 연결하지 않는 새 그래프를 사용한다.

각 라운드:

1. 현재 A와 B를 동시에 고정
2. Codex와 Claude가 **각자 A와 B 모두를 검토**하고 쟁점을 `targetDocumentId=A|B`로 분류 (`document-review`)
3. 양쪽 검토가 모두 끝난 뒤 서로의 쟁점에 응답 (`review-response`)
4. 문서 A와 B에 대해 한 번씩 `document-revision` 수행. 두 수정 단계는 양쪽 응답에 의존하고 둘 다 끝나야 다음 라운드로 이동
5. 편집 담당은 라운드마다 교대한다. 예: R1 Codex→A, Claude→B; R2 Claude→A, Codex→B; R3 다시 교대. 이는 작업 할당이지 소유권이 아니다.

마지막 라운드 뒤에는 각 문서를 마지막 편집자가 아닌 공급자가 검증하는 `document-validation` 두 단계를 추가하는 것을 권장한다. 검증 쟁점이 사용자 결정으로 해결되면 해당 문서의 마지막 개정과 검증만 의존성에 따라 재실행한다.

필수 결과:

- `document-A-final.md`
- `document-B-final.md`
- 비교 요약
- 문서별 채택·거부·반영 위치 기록
- 열린 질문

서로 다른 타당한 대안은 유지하며 A'와 B'를 억지로 같게 만들지 않는다.

### 모드 4: `dual-project-audit`

- 메뉴에는 `[4] 두 프로젝트 비교하기 — 비활성화`처럼 명확히 표시한다.
- 선택하면 현재 격리 실패 이유와 필요한 안전 게이트를 설명하고 모델 호출 전에 종료한다.
- `docs\3A_ISOLATION_SPIKE.md`의 실패 판정을 변경하거나 안전을 약화하지 않는다.

## 호환성 및 마이그레이션 계획

### 내부 ID와 CLI

- 기존 `shared-document`, `dual-document`, `dual-project-audit` ID는 유지한다.
- 새 모드 2에만 `document-merge`를 추가한다.
- 새 정규 CLI는 모드 2·3에서 `--document-a`, `--document-b`를 사용한다.
- 기존 `dual-document --codex ... --claude ...`는 당장 제거하지 않는다. 각각 A/B로 변환하고 사용 중단 예정 경고를 반환하는 호환 별칭으로 둔다.
- 새 매니페스트에는 정규 필드만 기록한다. 비밀값이나 원본 공급자 응답은 추가로 기록하지 않는다.

### 기존 실행 재개

기존 실행을 새 그래프로 묵시적으로 재해석하면 안 된다.

- 새 매니페스트에 `workflowVersion`을 추가한다.
- 기존 필드가 없는 실행은 `workflow-v1`로 간주하여 기존 `dual-document` 그래프와 `codex/claude` 역할을 그대로 읽는다.
- 새 실행은 `workflow-v2`와 A/B 역할을 사용한다.
- `New-DuoForgeStageGraph`, 라운드 추가, 사용자 결정 후 단계 초기화는 `workflowVersion`으로 레거시/신규 그래프를 분기한다.
- 기존 완료 산출물을 새 이름으로 재작성하지 않는다.
- 현재 `duoforge-stage-v2` 프롬프트 정책 실행의 재개를 보존하면서 신규 실행은 `duoforge-stage-v3` 등 새 계약으로 분리한다. 기존 실행을 일괄 승격하지 않는다.

### 스키마

안전한 선택은 신규 워크플로용 단계 결과 스키마를 별도로 두고 매니페스트 버전으로 선택하는 것이다.

- 기존 `stage-result.schema.json` 계약은 레거시 실행에 유지하거나 명시적 v1 파일로 고정
- 신규 스키마는 `targetDocumentId`, `sourceDocumentId`, `proposedByProvider`를 표현
- 신규 단계 enum에 `independent-merge-draft`, `document-review`, `document-revision`, `document-validation` 추가
- 신규 쟁점 원장에서는 `ownerDecisions` 대신 문서별 편집 결정을 사용
- 읽기 경계에서 레거시 결과를 정규형으로 변환하고 저장 원본은 보존

스키마부터 바꾸고 렌더러를 나중에 고치면 중간 상태가 위험하므로, 단계 계약·어댑터·렌더러 테스트를 한 구현 슬라이스로 처리한다.

## 구현 순서

### 1. 요구사항과 용어 고정

- `require\PRD.md`를 4개 모드 구조로 개정
- 모드 2 새 절, 모드 3의 AI 소유권 표현 제거, 기존 3A를 화면 모드 4로 정리
- 공통 프로토콜, 기능 요구사항, 상태 예시, 파일 구조, CLI 예시, 수용 시나리오, 위험·완료 정의까지 번호와 용어를 일관되게 갱신
- `docs\IMPLEMENTATION_PLAN.md`에 이번 확장 슬라이스와 게이트 추가
- 문서 정적 검색으로 남은 `Codex 측 문서`, `Claude 측 문서`, `소유 문서` 표현을 분류. 공급자 의견을 뜻하는 정상 용례는 유지

### 2. 정규 입력 모델과 레거시 어댑터

- 모드 목록과 공개 함수 `ValidateSet`에 `document-merge` 추가
- `DocumentA/B`, `documentA/B`, A/B 인벤토리 도입
- 모드 2·3에 같은 비중첩 폴더·Markdown 자동 포함·출력 경계 검증 적용
- 레거시 `CodexDocument/ClaudeDocument`, `--codex/--claude` 변환과 경고 추가
- 컨텍스트 배치가 A/B의 주 문서와 보조 문맥을 중복 없이 포함하는지 검증

### 3. 버전된 실행·스냅샷 호환성

- `workflowVersion`과 새 프롬프트 계약 버전 기록
- 신규 `roles.documents.A/B` 작성
- 레거시 인벤토리와 단계 그래프를 읽고 재개하는 경로 보존
- 기존 실행을 새 의미로 재구성하지 않는 회귀 테스트 추가

### 4. 모드 2 엔진

- 호출 계획, 단계 그래프, 프롬프트 지시, 단계 결과 계약 구현
- 양쪽 공급자가 같은 A/B 스냅샷과 같은 선행 산출물을 보는 장벽 테스트
- 병합본과 출처 추적표 렌더링
- 최종 검증·사용자 결정·추가 라운드·일시정지 경계 연결

### 5. 모드 3 공급자-문서 분리

- `owner-response`, `owned-document-revision` 신규 워크플로 사용 중단
- 양쪽 모델의 A/B 전체 검토, 문서별 쟁점, 편집 담당 교대, 두 수정본 장벽 구현
- 문서별 최종 검증과 선택적 재실행 의존성 구현
- 결과 파일과 채택 기록을 A/B 기준으로 변경
- 레거시 `workflow-v1 dual-document`에는 기존 단계와 파일명을 유지

### 6. 메뉴·CLI·진행판

- 새 작업 메뉴에 네 모드 표시. 모드 4는 선택 불가능한 상태와 이유를 명확히 보여줌
- 파일 선택 문구·최근 경로 역할·미리보기·오류 메시지를 문서 A/B로 변경
- 도움말과 `--plan-only`에 새 모드 및 호출 수 표시
- 진행판 단계 이름을 `병합 후보`, `문서 A/B 검토`, `문서 A/B 개정`, `문서 검증`처럼 표시

### 7. 문서 및 전체 검증

- README 실행 예시와 결과 구조 갱신
- 테스트 통과 후 정적 잔여 용어 검색
- 가짜 공급자 E2E를 모드 1·2·3 각각 2라운드로 검증
- 라이브 공급자 E2E는 모든 로컬 테스트 통과 뒤 기존 명시적 LIVE 확인 절차를 유지하여 별도 수행
- 모드 4는 계속 실패 폐쇄되는지 검증

## 필수 테스트 목록

1. 모드 1은 brief 하나를 받고 최종 문서 하나를 만든다.
2. 모드 2·3은 A/B 두 문서가 모두 필요하다.
3. 모드 2·3은 같은 폴더·중첩 폴더·결과 루트 침범을 호출 전에 차단한다.
4. 모드 2·3은 각 폴더의 보조 Markdown을 A/B 문맥으로만 포함한다.
5. `--codex/--claude` 호환 별칭은 A/B로 정규화되고 경고를 남긴다.
6. 신규 실행 매니페스트에는 공급자 소유 문서 필드가 없다.
7. 기존 `workflow-v1 dual-document` 실행은 같은 단계·파일 의미로 조회·재개할 수 있다.
8. 모드 2 R1의 두 병합 후보는 서로를 보지 않고 같은 A/B 스냅샷을 사용한다.
9. 모드 2는 최종 문서 하나와 A/B 출처 추적표를 만든다.
10. 모드 3의 두 공급자는 A/B 모두를 검토한다.
11. 모드 3의 편집 담당은 라운드마다 A/B 사이에서 교대하며 영구 결합되지 않는다.
12. 두 문서 개정이 모두 커밋되기 전에 다음 라운드가 시작되지 않는다.
13. 모드 3은 A'와 B' 및 비교·채택 기록을 만든다.
14. 일시정지는 모드 2 합성 완료, 모드 3 양쪽 개정 완료라는 라운드 장벽에서 한 번만 발생한다.
15. 사용자 결정 변경·근거 추가·3라운드 확장은 목표 문서와 의존 단계만 재실행한다.
16. 구조화 결과의 공급자·단계·대상 문서 불일치는 실패 폐쇄한다.
17. 원본 해시는 모든 정상·오류·재개 흐름에서 동일하다.
18. 모드 4는 `DF-PREFLIGHT-3A-ISOLATION`으로 모델 호출 전에 차단된다.
19. 진행 이벤트와 로그에는 원문 문서·비밀값이 노출되지 않는다.
20. 기존 52개 테스트가 모두 유지되고 신규 테스트가 추가된다.

## 이번 세션의 검증

PowerShell 7에서 다음 명령을 실행했다.

```powershell
& 'C:\Program Files\PowerShell\7\pwsh.exe' -NoProfile -File '.\tests\Run-Tests.ps1'
```

결과: `통과 52, 실패 0` (약 24초).

라이브 Codex/Claude 호출, 설치, 커밋은 수행하지 않았다. Git은 사용자 프로필의 전역 ignore 파일을 읽을 때 권한 경고를 표시했지만 저장소 상태·테스트 실행에는 영향을 주지 않았다.

## 완료 기준

- 메뉴와 CLI에서 네 모드의 입력·출력 차이가 설명 없이도 구분된다.
- 새 모드 2는 A/B에서 C 하나를 만들고 출처 추적을 제공한다.
- 새 모드 3은 공급자 소유권 없이 A/B 계보를 유지하여 A'/B'를 만든다.
- 신규 실행 데이터에서 문서 ID와 공급자 역할이 분리된다.
- 레거시 실행의 조회·재개·산출물 의미가 깨지지 않는다.
- 모드 4의 격리 게이트는 계속 닫혀 있다.
- 전체 로컬 테스트와 모드별 가짜 공급자 E2E가 통과한다.
- README, PRD, 구현 계획, 도움말, 메뉴, 오류 메시지, 진행판 용어가 일치한다.

## Suggested skills

- 별도 필수 스킬은 없다. 이 저장소는 PowerShell 기반 로컬 CLI이며 현재 사용 가능한 목록에 전용 PowerShell 개발 스킬이 없다.
- 작업 종료나 새 세션 재인계가 필요하면 `handoff` 스킬을 사용한다.

## 붙여넣기용 다음 세션 프롬프트

`D:\Coding\APP-windows\DuoForge`에서 모드 확장 구현을 이어가 주세요. 먼저 `NEXT_SESSION_HANDOFF.md`, `require\PRD.md`, `docs\IMPLEMENTATION_PLAN.md`와 인계 문서에 지정된 핵심 PowerShell 파일을 읽으세요. 문서는 A/B 계보이고 Codex·Claude는 교체 가능한 작업자라는 확정 모델을 유지한 채, 우선 PRD와 구현 계획을 4개 모드로 개정하고 정규 입력 모델·레거시 호환 경계를 테스트로 고정한 다음 단계별 구현을 진행하세요. 기존 실행을 새 의미로 묵시적으로 재해석하거나 모드 4의 격리 게이트를 열지 마세요. 원문 공급자 출력·문서 내용·비밀값을 로그나 진행 이벤트에 추가로 노출하지 마세요. 시작 전과 주요 구현 슬라이스마다 다음 기준 테스트를 실행하세요: `& 'C:\Program Files\PowerShell\7\pwsh.exe' -NoProfile -File '.\tests\Run-Tests.ps1'`.
