# DuoForge 다음 세션 인계

## 작업 공간과 현재 기준점

- 작업 공간: `D:\Coding\APP-windows\DuoForge`
- 브랜치: `main`
- 현재 HEAD: `cd3f82c A/B 마이그레이션 저장·쟁점 계약을 실패 폐쇄로 강화함`
- 현재 작업 트리에는 슬라이스 9 구현과 문서 변경이 커밋되지 않은 상태로 남아 있다. 시작 전부터 수정돼 있던 `NEXT_SESSION_HANDOFF.md`, `docs\IMPLEMENTATION_PLAN.md`, `require\PRD.md`와 새 `docs\ROADMAP.md`를 보존한 채 구현 결과를 더했다.
- 현재 모듈 버전: `0.8.0`
- 최신 구현 기준선: PowerShell 7 오프라인 회귀 `100개 통과, 0개 실패`, `git diff --check` 통과
- 슬라이스 9의 **1차 의미 기반 대용량 문맥 배치**는 구현과 오프라인 검증을 마쳤다. 다음 세션은 현재 diff를 다시 읽고, 쿠키님의 명시적 요청이 있을 때만 커밋하거나 다음 승인 작업을 시작한다.

이 handoff, 코드, 테스트와 문서 갱신은 아직 커밋하지 않았다. 실제 로그인·브라우저·공급자 모델 호출은 수행하지 않았다.

## 먼저 읽을 파일

1. `NEXT_SESSION_HANDOFF.md`
2. `docs\IMPLEMENTATION_PLAN.md` — 특히 `슬라이스 9: 의미 기반 대용량 문맥 배치`
3. `require\PRD.md` — 특히 7.3, 19.4, 24, 26
4. `docs\ROADMAP.md` — 현재 작업과 분리된 장기 대규모 개선 후보
5. `README.md` — 현재 구현 동작만 확인
6. `src\DuoForge\Private\26.ContextBatches.ps1` — Markdown 구조 맵, 의미 배치 계획·팩·커버리지와 schema 1 호환 경로
7. `src\DuoForge\Private\17.PromptBuilder.ps1` — 배치 프롬프트와 이후 전체 토론 문맥
8. `src\DuoForge\Private\10.StateStore.ps1` — 저장 세대·단계 그래프·재개 전 검증
9. `src\DuoForge\Private\09.Requests.ps1`, `05.Planner.ps1`, `15.StageEngine.ps1` — 계획·호출 수·배치 장벽
10. `src\DuoForge\Private\19.ArtifactRenderer.ps1` — `COVERAGE.md`
11. `src\DuoForge\Private\20.RunCoordinator.ps1`, `25.DecisionExtensions.ps1` — 저장 계획을 이용한 재개·라운드 추가
12. `tests\Run-Tests.ps1`, `tests\fixtures\workflow-v1-resume`

## 직전 완료 상태

- 커밋 `cd3f82c`에서 A/B 추가 근거 원자성, `reviewerVerdicts`/`editorialDecisions`/`adoptions` 분리, 단계별 계보 허용 행렬, `issueKey` 무결성, 공개 요청·CLI 검증, 저장 세대 계약과 workflow-v1 전체 재개 fixture를 완료했다.
- 신규 저장 계약은 manifest 4/state 2/inventory 2/ledger 2이고, 기존 workflow-v1과 초기 workflow-v2 저장은 재작성하지 않는다.
- 슬라이스 9에서 신규 schema 2 의미 분할·봉투·CORE 근거 계약, 저장 무결성, 문서별 균형 부분 선택과 모드 2·3 가짜 공급자 E2E를 구현했다.
- 동일한 A/B 원문의 섹션 ID 계보 분리, schema 2 비활성 위장 변조 차단, 활성 schema 1 초기 workflow-v2의 재분할 없는 재개를 추가 회귀로 고정했다.
- 최종 검토에서 XML escape 팽창 CORE의 적응형 재분할, A/B 최소 배치 preflight, 브리지·지도 반복 축소와 불가능 팩 실패 경로, 실제 과거 파일형 schema 1 모드 2·3 정적 fixture 전체 재개를 보강했다.
- 구현 계획과 README의 최신 기준선은 전체 오프라인 회귀 100개다.
- 저장된 `AWAITING_USER` 실행을 재개하거나 질문에 답하지 않았고, 실제 공급자를 다시 호출하지 않았다.

## 해결한 문제와 사용자가 확정한 동작

슬라이스 9 전 대용량 처리는 UTF-8 바이트 상한과 줄바꿈 중심으로 잘랐고, 생성된 팩에는 전체 위치, 제목 경로, 앞뒤 연결 문맥이나 문서 지도가 없었다. 현재 구현은 아래 확정 동작으로 교체됐다.

사용자는 다음을 요구했다.

1. `서문+내용1,2 // 내용3,4 // 내용5,6+마무리글`처럼 제목·내용 관계와 의미가 유지되는 크기로 나눈다.
2. 중간 배치에는 아주 짧은 앞쪽 문맥, 현재 원문, 아주 짧은 뒤쪽 문맥을 함께 제공한다.
3. 첫 배치에도 현재 원문 뒤의 중간·후반 방향을 알 수 있는 짧은 문맥을 제공한다.
4. 바이트는 의미 분할 기준이 아니라 호출 한도를 넘지 않기 위한 강제 상한과 최후 폴백으로만 사용한다.

## 1차 범위에서 확정한 설계

- 신규 모델 전처리 호출, 새 단계 유형과 배치별 교차 토론은 추가하지 않는다. 기존의 배치당 Codex/Claude `context-batch-analysis` 1회와 이후 전체 토론 그래프를 유지한다.
- 신규 실행만 `context-plan.schemaVersion=2`를 생성한다. 기존 schema 1 계획과 저장 팩은 그대로 읽고 재개하며 절대 재분할·재작성하지 않는다.
- 로컬 결정론적 Markdown 구조 맵을 사용한다. ATX/Setext 제목, 서문, 제목 경로, 문단, 목록, 표와 fenced code 경계를 인식한다.
- 각 원본 스냅샷의 의미 구간에 안정적인 섹션 ID, 1-based 줄 범위, 0-based half-open UTF-8 바이트 범위, 원본 해시를 부여한다. 원문 내용은 `context-plan.json` 메타데이터에 복제하지 않는다.
- 인접한 완결 섹션을 목표 크기까지 묶는다. 하나의 섹션이 너무 클 때만 하위 제목 → 문단 → 줄 → UTF-8 안전 바이트 순서로 폴백하며 이유와 연속 구간 ID를 기록한다.
- 각 팩은 `DOCUMENT_MAP`, `BEFORE`, `CORE`, `AFTER`를 명확히 분리한다. `CORE`만 분석·근거 가능 영역이고 지도와 브리지는 `context-only`다. 앞뒤 브리지는 같은 스냅샷을 벗어나지 않는다.
- `coreBytes`, `overlapBytes`, `transmittedBytes`를 분리한다. 커버리지는 중복된 브리지 바이트가 아니라 `CORE`만으로 계산한다.
- 봉투 오버헤드를 별도 예약하고 완성된 프롬프트가 `maxInputBytesPerCall`을 넘으면 브리지를 줄인 뒤에도 맞지 않을 경우 첫 공급자 호출 전에 실패한다.
- 완전 커버리지가 기본이다. `--allow-partial`에서는 A/B 및 각 문서의 앞·중간·뒤가 한쪽으로 치우치지 않게 결정론적으로 선택하고, 누락 섹션과 문서별 커버리지를 명시한다.
- 모델 생성 계층형 요약, A/B 섹션 의미 대응, 배치별 교차 비평·잠정 합의는 2차 대규모 개선으로 분리한다.

## 완료한 테스트 우선 구현 순서

권위 있는 전체 계획은 `docs\IMPLEMENTATION_PLAN.md` 슬라이스 9에 있다.

1. 제목/문단/표/목록/fenced code 경계와 첫·중간·마지막 문맥 봉투의 실패 테스트를 먼저 추가한다.
2. `26.ContextBatches.ps1`에 순수 Markdown 구조 맵·분할·패킹 함수를 구현하고 동일 입력의 섹션 ID·배치 해시 결정성을 고정한다.
3. `context-plan` v2와 팩 봉투를 생성하고 core/overlap/transmitted 바이트 및 원본 위치·해시를 기록한다.
4. `17.PromptBuilder.ps1`에서 CORE와 context-only 영역의 용도를 명확히 지시하고 팩 무결성과 최종 입력 크기를 재검증한다.
5. `10.StateStore.ps1`에서 v2 계획의 배치 ID, 내부 경로, 파일 크기·해시, 섹션 순서·비중첩·core 합계·커버리지를 공급자 호출 전에 실패 폐쇄한다. schema 1에는 신규 필드를 요구하지 않는다.
6. 부분 분석의 균형 선택과 `COVERAGE.md`의 문서별·섹션별 누락 표시를 구현한다.
7. 모드 2·3 강제 대용량 가짜 공급자 E2E와 기존 schema 1 재개 해시 불변을 검증한 뒤 PRD·README를 실제 구현에 맞춘다.

## 실제 수정 파일

핵심 구현:

- `src\DuoForge\Private\26.ContextBatches.ps1`
- `src\DuoForge\Private\09.Requests.ps1`
- `src\DuoForge\Private\17.PromptBuilder.ps1`
- `src\DuoForge\Private\10.StateStore.ps1`
- `tests\Run-Tests.ps1`
- `tests\fixtures\workflow-v2-schema1-resume`

통합 경계:

- `src\DuoForge\Private\13.ProgressView.ps1`, `15.StageEngine.ps1`, `16.StageContract.ps1`, `19.ArtifactRenderer.ps1`
- `src\DuoForge\Private\20.RunCoordinator.ps1`, `25.DecisionExtensions.ps1`
- `README.md`, `require\PRD.md`, `docs\IMPLEMENTATION_PLAN.md`, `docs\ROADMAP.md`

`05.Planner.ps1`의 호출 계산은 유지했다. `09.Requests.ps1`에는 A/B 각각 최소 한 문맥 배치를 확보하지 못하는 저용량 계획을 preflight에서 거부하는 경계만 추가했다. 단계 그래프 생성 경로에는 schema 2 배치의 단일 문서 계보를 전달했고, `19.ArtifactRenderer.ps1`에는 round 0 문맥 쟁점을 기존 round 1 원장에 안전하게 병합하는 최소 변경만 적용했다.

## 필수 회귀와 완료 기준

- 구조 경계: ATX/Setext, 서문·결론, 문단, 목록, 표, fenced code와 큰 단일 섹션 폴백
- 인코딩: CRLF/LF, BOM, 한글·emoji, 서로게이트와 UTF-8 원문 byte-for-byte 재구성
- 봉투: 첫·중간·마지막 BEFORE/CORE/AFTER, 같은 스냅샷 밖 누출 0건, CORE 원문 정확히 1회
- 예산: 완성 팩 상한, 브리지 축소, 계획 배치 수=실제 팩 수=그래프 배치 수, 호출 상한·부분 동의 유지
- 저장: 중복·누락 batch ID, run 밖 path, 파일 누락, bytes/hash 변조, section gap/overlap과 core 합계 불일치를 공급자 호출 0회에서 차단
- 호환: schema 1 workflow-v1/초기 workflow-v2 저장 해시 불변, 완료된 context stage 미재호출, 라운드 추가 시 배치 단계 복제 0건
- 모드: shared brief 회귀와 document-merge/dual-document의 A/B·보조 문맥 역할 및 커버리지 분리
- 비노출: 이벤트·로그·진행판·`COVERAGE.md`에 원문, 제목 본문, 앞뒤 브리지나 공급자 출력이 새로 노출되지 않음
- 문서: README는 구현 완료 뒤에만 현재 동작으로 갱신하고, 계획 기능을 지원 기능처럼 쓰지 않음

위 회귀는 2026-07-28 PowerShell 7 전체 실행에서 `100개 통과, 0개 실패`로 확인했다. `git diff --check`도 통과했다.

## 최종 검토에서 닫은 비차단 검증 위험

- 초기 workflow-v2/schema 1의 실제 과거 manifest 3/state·inventory·ledger 1 파일형과 모드 2·3의 13/14단계 계보를 비식별 정적 fixture로 고정했다. 두 fixture는 원본 해시 불변, 저장 계약, 가짜 공급자 전체 재개와 최종 산출물을 검증한다.
- 팩 상한 조정은 브리지를 0까지 줄인 뒤 `DOCUMENT_MAP`을 256바이트까지 줄이는 경계를 검증한다. 최소 봉투도 맞지 않는 경우 `DF-CONTEXT-PACK-SIZE`로 닫히며, 특수문자 escape 팽창으로 재분할 가능한 CORE는 그 전에 UTF-8 안전 범위로 더 나눈다.
- 독립 diff 리뷰에서 발견한 A/B 0% 부분 선택은 두 문서에 각각 최소 한 배치를 확보하지 못하면 `DF-CONTEXT-DOCUMENT-CAPACITY`로 preflight 차단하도록 수정했다.

각 작은 수정 슬라이스와 마지막에 실행:

```powershell
& 'C:\Program Files\PowerShell\7\pwsh.exe' -NoProfile -File '.\tests\Run-Tests.ps1'
git diff --check
git status --short
```

## 장기 대규모 개선 목록

- 단일 인덱스: `docs\ROADMAP.md`
- 규범적 향후 항목: `require\PRD.md` 26장
- 현재 계획: `docs\IMPLEMENTATION_PLAN.md`
- 다음 세션 임시 상태: 이 handoff

이번 논의에서 2차 후보로 분리한 항목은 모델 보조 계층형 문서 지도·구간 요약, A/B 의미 기반 섹션 대응, 의미 배치별 교차 토론 뒤 전체 합의, 비 Markdown 구조 어댑터와 실제 토큰·시간·사용량 기반 재계획이다. 모드 3B/3C, 모드 4 격리, UI/API, 추가 공급자, 팀 권한·감사, 외부 근거와 템플릿 플러그인도 로드맵에 함께 관리한다.

## 안전 경계

- 실제 로그인·로그아웃·브라우저·모델 호출 없이 오프라인 fixture와 정제된 저장 메타데이터만 사용한다.
- 이메일, 조직 ID, 인증 원문, 토큰, API 키와 인증 파일 내용을 출력하거나 저장하지 않는다.
- 기존 workflow-v1/v2 저장 실행을 수정·재개·마이그레이션하거나 `AWAITING_USER` 질문에 답하지 않는다.
- 모드 4 `DF-PREFLIGHT-3A-ISOLATION` 게이트와 원문 공급자 출력·프롬프트·문서·컨텍스트 비노출 경계를 유지한다.
- 실제 공급자 호출이 필요하다고 판단해도 실행하지 말고, 먼저 Claude `sonnet/low`, 공급자별 예상 호출 수와 새롭고 정확한 `LIVE` 동의를 요청한다.

## 추천 스킬

- 구현 자체에는 별도 스킬이 필요하지 않다. PowerShell 코드·저장 계약·fixture를 테스트 우선으로 직접 대조한다.
- 작업 종료 시 `handoff` 스킬로 구현 결과, 추가된 테스트 수, 남은 위험과 커밋 상태를 갱신한다.
