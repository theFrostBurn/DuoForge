# DuoForge 다음 세션 인계

## 작업 공간과 기준점

- 작업 공간: `D:\Coding\APP-windows\DuoForge`
- 브랜치: `main`
- 문서 모델 확정 커밋: `666d58e865f789a06abc3b7db028e7c2dd30b3dc`
- 모드 확장 구현 커밋: `db5b62ae929a107fd501d5ffea85f697b6aefb2d`
- 이 인계 문서는 위 구현 커밋 다음의 별도 커밋으로 기록한다.
- 기준 문서: PRD v1.6, `docs\IMPLEMENTATION_PLAN.md`
- 2026-07-28 마지막 오프라인 검증: PowerShell 7 회귀 `통과 68, 실패 0`

## 먼저 읽을 파일

1. `NEXT_SESSION_HANDOFF.md`
2. `require\PRD.md`
3. `docs\IMPLEMENTATION_PLAN.md`
4. `README.md`
5. `src\DuoForge\Private\09.Requests.ps1` — 정규 A/B 입력과 레거시 어댑터
6. `src\DuoForge\Private\05.Planner.ps1`, `15.StageEngine.ps1` — workflow-v1/v2 단계 그래프와 실행
7. `src\DuoForge\Private\16.StageContract.ps1`, `schemas\stage-result-v2.schema.json` — v2 결과 계약
8. `src\DuoForge\Private\17.PromptBuilder.ps1`, `18.ProviderAdapters.ps1` — 프롬프트·공급자 경계
9. `src\DuoForge\Private\19.ArtifactRenderer.ps1` — 최종 문서와 출처·채택 기록
10. `src\DuoForge\Private\14.Interactive.ps1`, `src\DuoForge\Public\Cli.ps1` — 네 모드 UI·CLI
11. `tests\Run-Tests.ps1` — 정규 입력, 레거시 호환, 가짜 공급자 E2E와 비노출 회귀

## 확정 제품 모델

| 화면 모드 | 내부 ID | 입력 | 결과 | 현재 상태 |
|---|---|---|---|---|
| 1. 컨셉으로 공동 문서 만들기 | `shared-document` | brief 또는 컨셉 C | 공동 문서 C' | 활성, workflow-v2 오프라인 검증 |
| 2. 두 문서를 하나로 합의하기 | `document-merge` | 문서 A/B | 합의 문서 C와 출처 추적표 | 구현·오프라인 검증 완료 |
| 3. 두 문서를 각각 개선하기 | `dual-document` | 문서 A/B | A'/B'와 문서별 채택 기록 | 구현·오프라인 검증 완료 |
| 4. 두 프로젝트 비교하기 | `dual-project-audit` | 프로젝트 A/B | 비교 결과 | 격리 게이트 폐쇄 |

- A/B는 공급자나 최초 작성자가 아니라 실행 안의 안정적인 문서 계보다.
- Codex와 Claude는 교체 가능한 검토자·응답자·편집자·합성자·검증자다.
- `performedBy`는 감사용 단계 작업자이며 문서 소유권이 아니다.
- 기존 실행을 새 의미로 묵시적으로 재해석하거나 저장된 단계·산출물을 다시 쓰지 않는다.

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

## 현재 경계와 주의사항

- 모드 1~3의 2라운드 가짜 공급자 E2E와 전체 오프라인 회귀는 완료됐다.
- 기존 라이브 결과는 `workflow-v1 shared-document/dual-document`의 역사적 증거일 뿐이다. 신규 `document-merge`나 `workflow-v2 dual-document`의 라이브 완료로 간주하지 않는다.
- 이번 모드 확장에서는 실제 Codex·Claude 공급자 호출을 수행하지 않았다.
- 실제 공급자 호출은 `--live`만으로 시작하지 않고 대화형 화면에서 사용자가 정확히 `LIVE`를 입력해야 한다. 새 세션에서도 별도 명시적 동의 전에는 호출하지 않는다.
- 모드 4의 기능 플래그나 격리 게이트를 열지 않는다.
- 원문 공급자 출력, stdout·stderr, 프롬프트·문서·컨텍스트 내용, 생성 중 텍스트와 비밀값을 로그·진행 이벤트에 추가하지 않는다.
- Git이 사용자 프로필의 전역 ignore 파일을 읽을 때 권한 경고를 낼 수 있으나 현재 저장소 검증과 커밋에는 영향을 주지 않았다.

## 검증 명령과 마지막 결과

시작 전과 주요 구현·검증 슬라이스마다 다음 기준 테스트를 실행한다.

```powershell
& 'C:\Program Files\PowerShell\7\pwsh.exe' -NoProfile -File '.\tests\Run-Tests.ps1'
```

마지막 결과:

- 회귀 테스트: `통과 68, 실패 0` (약 25초)
- `git diff --check`: 통과
- 신규 v2 스키마 포함 JSON 파싱: 통과
- PowerShell 구문 검사: 오류 0
- 제품 코드 비밀 패턴 점검: 후보 0

## 다음 작업

1. `git status --short`와 `git log -2 --oneline`으로 깨끗한 인계 상태와 두 최신 커밋을 확인한다.
2. 위 기준 테스트를 먼저 실행해 `통과 68, 실패 0`을 재현한다.
3. `workflow-v2` 모드 1·2·3의 실제 공급자 E2E 준비 상태를 독립 검토한다. 입력 픽스처, 예상 호출 수, 원본 해시, 산출물·이벤트 검증 항목을 먼저 확정한다.
4. 예상 호출 범위와 위험을 쿠키님께 제시하고 정확한 `LIVE` 동의를 받기 전에는 공급자를 호출하지 않는다.
5. 동의가 있으면 모드 1, 2, 3을 순차 실행하고 각 실행에서 단계 완료, 원본 해시 불변, 결과 파일, A/B 출처·채택 기록, 로그·이벤트 비노출을 확인한다.
6. 라이브 검증 뒤 기준 테스트를 다시 실행하고 문서 상태를 실제 결과에 맞게 갱신한다. 실패하면 기존 라이브 증거로 대체하지 말고 오류 코드와 메타데이터만 보고한다.

## 추천 스킬

- 현재 라이브 E2E 준비·실행에 즉시 필요한 전용 스킬은 없다. 저장소 문서와 PowerShell 테스트를 기준으로 진행한다.
- 다음 검증 단계를 마친 뒤 다시 세션을 넘길 때 `handoff` 스킬을 사용한다.

## 붙여넣기용 다음 세션 프롬프트

`D:\Coding\APP-windows\DuoForge`에서 DuoForge 모드 확장 다음 단계를 이어가 주세요. 먼저 `NEXT_SESSION_HANDOFF.md`, `require\PRD.md`, `docs\IMPLEMENTATION_PLAN.md`, `README.md`와 인계 문서의 핵심 PowerShell 파일을 읽고, `git status --short`, `git log -2 --oneline`을 확인한 뒤 `& 'C:\Program Files\PowerShell\7\pwsh.exe' -NoProfile -File '.\tests\Run-Tests.ps1'`로 68개 기준 테스트를 재현하세요. 문서 A/B는 안정적인 계보이고 Codex·Claude는 교체 가능한 작업자라는 모델, workflow-v1 저장 의미 보존, 모드 4 격리 게이트 폐쇄를 유지하세요. 즉시 할 일은 workflow-v2 모드 1·2·3 실제 공급자 E2E의 입력·호출 수·검증 항목을 준비하고 검토하는 것입니다. 예상 범위를 먼저 보고한 뒤 제가 정확히 `LIVE`라고 명시적으로 동의하기 전에는 공급자를 호출하지 마세요. 원문 공급자 출력, stdout·stderr, 프롬프트·문서·컨텍스트 내용, 생성 중 텍스트와 비밀값을 로그나 진행 이벤트에 추가로 노출하지 마세요.
