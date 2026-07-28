# DuoForge 다음 세션 인계

## 기준점

- 작업 공간: `D:\Coding\APP-windows\DuoForge`
- 브랜치: `main`
- 직전 구현 기준: `c3e6387 토론 진행판이 문서 대상과 실행 상태를 정확히 알리게 함`
- 원격 기준: `origin/main`은 `d495984`다. 이 handoff를 포함한 로컬 `main`은 원격보다 2커밋 앞서 있으며 진행판 보강과 로드맵·인계 정리 커밋은 아직 푸시되지 않았다.
- `docs\ROADMAP.md` 전면 정리와 이 handoff 교체는 현재 문서 커밋에 포함됐다. 다음 세션 시작 시 작업 트리가 깨끗한지 다시 확인한다.
- 모듈 버전: `0.8.0`
- 마지막 구현 기준선: 2026-07-28 PowerShell 7 전체 오프라인 회귀 `100개 통과, 0개 실패`, `git diff --check` 통과
- 실제 로그인·브라우저·공급자 모델 호출은 이번 문서 정리에서 수행하지 않았다.

완료된 의미 기반 대용량 문맥 구현은 커밋 `d495984`와 `docs\IMPLEMENTATION_PLAN.md` 슬라이스 9를 참조한다. 진행판의 대상 문서·실패·재시도·복귀 동작 보강은 커밋 `c3e6387`에 있다. 이 handoff는 완료 이력을 반복하지 않고 다음 구현에 필요한 내용만 남긴다.

## 다음 목표와 사용자 합의

현재 고정형 TUI는 안전한 **진행 상황판**에 가깝다. 최근 확정 결과 한 건과 숫자 집계만 보여 주므로 Codex와 Claude의 교환이 이어지는 느낌은 약하다.

다음 세션에는 아래 1·2를 함께 구현한다.

1. 검증·커밋된 최근 결과 최대 3건을 오래된 순서에서 최신 순서로 보여 주는 확정 피드
2. `C/M/m` 같은 축약 대신 새 쟁점·검토 응답·실제 편집 반영을 구분하는 자연어 행동 집계

`issueKey` 기반 주장 → 응답 → 실제 반영 미니 스레드는 **이번 범위에 넣지 않는다**. 1차 피드를 사용한 뒤에도 관전감이 부족할 때 공개 필드 허용 목록, 대표 쟁점 선정 규칙과 workflow-v1·`72×20` 폴백을 먼저 설계한다. 더 넓은 시각화와 웹·데스크톱 관전 UI도 `docs\ROADMAP.md`의 별도 후속·장기 후보로 유지한다.

## 먼저 읽을 파일

1. `NEXT_SESSION_HANDOFF.md`
2. `docs\ROADMAP.md` — 합의된 1차 범위, 조건부 후속과 명시적 비목표
3. `src\DuoForge\Private\13.ProgressView.ps1`
   - `Get-DuoForgeProgressArtifactRecordInternal`
   - `Get-DuoForgeProgressSnapshotInternal`
   - `New-DuoForgeProgressFrameInternal`
4. `tests\Run-Tests.ps1` — 고정형 진행판, 변조 산출물, 폭·높이, 대상 문서와 로그 폴백 회귀
5. `README.md`의 `고정형 토론 진행판`
6. `require\PRD.md` 15.5와 `FR-COM-062`~`FR-COM-066`

## 현재 구현에서 활용할 지점

- `Get-DuoForgeProgressArtifactRecordInternal`은 `COMMITTED` 단계만 읽고 산출물 해시와 단계 결과 스키마를 다시 검증한다. 공개 가능한 `summary`, 대상 문서와 쟁점·응답·반영 건수도 이미 만든다.
- `Get-DuoForgeProgressSnapshotInternal`은 유효한 `$artifactRecords`를 모두 수집하지만 현재 `latest` 한 건만 snapshot에 싣는다.
- `New-DuoForgeProgressFrameInternal`은 최근 확정 한 건, 요약과 `C/M/m` 집계를 렌더링한다.
- ANSI 없는 누적 로그도 `snapshot.latest`를 사용하므로 `latest` 호환은 유지하는 편이 안전하다.
- `context-batch-analysis`는 공급자 원요약을 노출하지 않고 `문맥 배치 분석 결과가 검증·저장되었습니다.`라는 일반화된 문구를 사용한다.

## 테스트 우선 구현 계획

1. 진행판 fixture에 커밋 산출물 4건 이상을 구성하고, 유효한 마지막 3건이 단계 그래프 기준으로 오래된 순서 → 최신 순서로 선택되는 실패 테스트를 먼저 추가한다.
2. 0·1·2·3건 상태와 최신 또는 중간 산출물의 해시·스키마 손상 시 해당 항목만 제외하고 이전 유효 항목으로 채우는 동작을 고정한다. 파일 시각이나 디렉터리 열거 순서에 의존하지 않는다.
3. snapshot에 `recentCommitted` 최대 3건을 추가한다. 기존 `latest`는 누적 로그와 내부 호환을 위해 `recentCommitted`의 마지막 항목과 같은 의미로 유지한다.
4. 각 항목을 헤더 한 줄과 정제 요약·행동 집계 한 줄 이내로 렌더링한다. 공급자·라운드·단계·대상 문서 순서를 일관되게 유지한다.
5. 집계 문구는 0건을 생략하되 다음 의미를 빠뜨리거나 섞지 않는다.
   - `issues`: 치명적·주요·경미한 새 지적
   - `issueResponses`: 수용·부분 수용·거부·보류·근거 필요·사용자 결정
   - `adoptions`: 실제 반영·부분 반영·미반영·보류
6. 최소 `72×20`에서 최근 3건, 현재 작업, 최소 장벽 3개와 하단 상태가 화면 높이 안에 들어오고 모든 줄이 71셀 이내인지 확인한다. `100×30`, 긴 한글·emoji·ANSI·제어문자도 함께 검증한다.
7. workflow-v1 fixture의 조회와 원본 해시 불변, 문맥 배치 원요약 비노출, A/B·공동·합의 대상 표시, 누적 로그의 단계당 한 번 출력이 회귀하지 않는지 확인한다.
8. 구현이 끝난 뒤 `README.md`와 `require\PRD.md`의 “가장 최근 한 건” 계약과 예시를 실제 최근 확정 피드에 맞춘다. `docs\ROADMAP.md`는 1차 항목을 완료로 바꾸되 미니 스레드는 후속 후보로 남긴다.

## 공개·비노출 경계

- 파일 해시와 단계 결과 스키마 검증을 통과한 `COMMITTED` 산출물만 사용한다.
- 이번 피드는 현재 공개 중인 정제 `summary`와 정수 집계만 사용한다.
- 원시 stdout·stderr, 생성 중 텍스트, 프롬프트, 문서·컨텍스트 본문, 내부 사고 과정은 표시·로그·이벤트에 추가하지 않는다.
- `issues.claim`, `proposal`, 근거 원문, `issueResponses.rationale`, `adoptions.rationale`와 `issueKey`는 이번 피드에 표시하지 않는다.
- 응답 수용을 실제 채택이나 전체 합의로 표현하지 않는다.
- 절대 `runDirectory`를 화면·이벤트에 다시 노출하지 않고 공개 식별자는 `runId`를 사용한다.
- 공급자 호출 수·순서, 프롬프트, 단계 그래프, 저장·재개 스키마와 이벤트 허용 목록을 바꾸지 않는다.
- 실제 로그인·브라우저·공급자 호출 없이 가짜 공급자와 오프라인 fixture를 우선 사용한다.

## 완료 기준과 검증

- 구현 diff가 원칙적으로 `13.ProgressView.ps1`, 진행판 테스트, README·PRD·ROADMAP 정합화에 한정된다. 다른 실행 계약 파일이 바뀌면 이유와 필요성을 별도로 검토한다.
- 새 회귀와 기존 전체 회귀가 모두 통과한다.
- 최소·넓은 화면, 변조 제외, 비노출, workflow-v1 호환과 누적 로그 동작이 테스트로 고정된다.
- 마지막에 아래 명령을 실행하고 실제 통과 수와 작업 트리 범위를 보고한다.

```powershell
& 'C:\Program Files\PowerShell\7\pwsh.exe' -NoProfile -File '.\tests\Run-Tests.ps1'
git diff --check
git status --short
```

실제 공급자 E2E가 필요하다고 판단해도 바로 실행하지 않는다. 별도 필요성을 설명하고 Claude `sonnet/low`, 공급자별 예상 호출 수와 정확한 새 `LIVE` 동의를 먼저 요청한다.

## 추천 스킬

- `emil-design-eng`: `72×20` 안에서 최근 3건의 정보 위계와 스캔 흐름을 다듬는 데 사용한다. 애니메이션보다 내용 순서·절단·상태 구분에 집중한다.
- 작업이 다시 다음 세션으로 넘어갈 때만 `handoff`를 사용해 검증 결과, 남은 위험과 커밋·푸시 상태를 갱신한다.
