# DuoForge

DuoForge는 Codex와 Claude가 불변 입력 스냅샷을 검토하고 토론하도록 조율하는 Windows 로컬 우선 CLI다. 문서 A/B는 공급자 소유권이 아닌 안정적인 문서 계보이며, Codex와 Claude는 교체 가능한 검토자·응답자·편집자·합성자·검증자다.

현재 저장소는 PRD v1.11의 문서 모드 확장 Beta 1차 완료본이다. 공통 안전 기반, 실행별 안전 진단, 필수 모델·분석 깊이 선택, 실행 계획, 불변 스냅샷, 구조화 토론 단계, 재개 가능한 상태 저장, 키보드 메뉴와 LIVE 토론 진행판, 쟁점 설명·근거 추가·사용자 결정과 최종 산출물 렌더링을 제공한다.

| 화면 모드 | 내부 ID | 입력 | 결과 | 상태 |
|---|---|---|---|---|
| 1. 컨셉으로 공동 문서 만들기 | `shared-document` | brief 또는 컨셉 C | 공동 문서 C' | 실제 E2E 통과 (`AWAITING_USER`) |
| 2. 두 문서를 하나로 합의하기 | `document-merge` | 문서 A/B | 합의 문서 C와 출처 추적표 | 실제 E2E 통과 (`AWAITING_USER`) |
| 3. 두 문서를 각각 개선하기 | `dual-document` | 문서 A/B | 개선 문서 A'/B'와 채택 기록 | 실제 E2E 통과 (`AWAITING_USER`) |
| 4. 두 프로젝트 비교하기 | `dual-project-audit` | 프로젝트 A/B | 비교 보고서 | 격리 실패로 비활성 |

모드 4는 Windows 격리 후보가 범위 밖 읽기와 자식 프로세스 차단에 실패하여 `DF-PREFLIGHT-3A-ISOLATION`으로 입력 전송과 모델 호출 전에 차단된다. 사용자 확인으로 이 게이트를 열 수 없다.

## 요구 환경

- Windows 10/11
- PowerShell 7 이상
- Codex CLI와 Claude Code CLI
- 각 공급자의 구독 로그인

## 실행

```powershell
.\duoforge.cmd
```

인수 없이 실행하면 대화형 PowerShell 7 터미널에서는 환경·구독 상태를 확인한 뒤 `↑/↓`, `Home/End`, `Enter`, `Esc`로 조작하는 홈 메뉴를 연다. 숫자·영문 단축키도 즉시 선택에 사용할 수 있고, 비활성 항목에 커서를 두면 이유를 보여준다. VT가 없으면 Windows 콘솔 커서 API로 같은 메뉴를 표시하고, 커서 제어나 키 읽기를 모두 사용할 수 없을 때만 ANSI 없는 줄 입력 메뉴로 한 번 폴백한다. 리디렉션·CI 같은 비대화형 환경에서는 입력을 기다리지 않고 도움말을 출력하며, 하위 명령과 옵션은 자동화·고급 사용을 위한 선택 경로다.

진단과 도움말은 다음처럼 실행한다.

```powershell
.\duoforge.cmd doctor
.\duoforge.cmd doctor --json
.\duoforge.cmd help
```

명시적 실행 계획 예시는 다음과 같다.

```powershell
.\duoforge.cmd start shared-document `
  --brief ".\require\PRD.md" `
  --codex-model "gpt-5.6-sol" `
  --codex-effort "high" `
  --claude-model "opus" `
  --claude-effort "high" `
  --type "prd" `
  --max-rounds 2 `
  --pause-after-round `
  --plan-only
```

문서 A/B를 사용하는 모드 2와 3은 공급자 이름이 아닌 정규 문서 옵션을 사용한다.

```powershell
.\duoforge.cmd start document-merge `
  --document-a ".\docs-a\PRD.md" `
  --document-b ".\docs-b\PRD.md" `
  --codex-model "gpt-5.6-sol" --codex-effort "high" `
  --claude-model "opus" --claude-effort "high" `
  --type "prd" --max-rounds 2 --plan-only

.\duoforge.cmd start dual-document `
  --document-a ".\docs-a\PRD.md" `
  --document-b ".\docs-b\PRD.md" `
  --codex-model "gpt-5.6-sol" --codex-effort "high" `
  --claude-model "opus" --claude-effort "high" `
  --type "prd" --max-rounds 2 --plan-only
```

모드 2·3은 문서 A/B의 폴더가 같거나 중첩되면 보조 Markdown 문맥이 섞이지 않도록 시작 전에 차단한다. 정규 보조 문맥 옵션은 `--document-a-context`와 `--document-b-context`다. 기존 `--codex`/`--claude`, `--codex-context`/`--claude-context`는 각각 A/B로 변환하고 사용 중단 예정 경고를 남기지만, 신규 실행 기록에는 정규 `documentA/documentB`, `documentAContext/documentBContext` 의미만 사용한다. 정규 옵션과 별칭이 서로 다른 경로를 지정하거나 알 수 없는 CLI 옵션이 들어오면 시작 전에 실패 폐쇄한다.

`--plan-only`는 AI 작업이나 작업 기록을 만들지 않고 선택한 모델·분석 깊이, 확인·전송 범위와 최대 AI 요청 횟수만 보여준다. 네 선택 옵션은 생략할 수 없으며, 대화형 메뉴의 권장 항목은 처음 강조될 뿐 `Enter` 또는 단축키로 확정하기 전에는 선택값이 생기지 않는다.

신규 실행은 `workflow-v2`와 문서 계보 A/B, 단계 작업자 `performedBy`를 분리해 기록한다. `workflowVersion`이 없는 기존 실행은 `workflow-v1`로 읽으며 기존 단계 그래프, `owner-response`/`owned-document-revision`, 파일명과 프롬프트 의미를 묵시적으로 바꾸거나 재작성하지 않는다.

신규 저장 세대는 `manifest.json` schema 4와 `state.json`, `inputs/inventory.json`, `issues.json` schema 2를 `duoforge-run-v2` 계약으로 묶는다. manifest의 입력은 문서 본문이나 원본 경로가 아니라 스냅샷 이름과 SHA-256만 기록하며, 역할은 inventory의 `roles.documents.A/B`와 일치해야 한다. 저장 파일의 버전·역할이나 manifest에서 계산한 단계 그래프의 작업자·대상·출처·의존성이 섞이면 공급자 호출 전에 `DF-RUN-STORAGE-CONTRACT`으로 차단한다. 기존 workflow-v1과 초기 workflow-v2 저장 세대는 해당 세대 그대로 읽고 재작성하지 않는다.

workflow-v2 쟁점은 검토자의 평가 `reviewerVerdicts`, 실제 편집 판단 `editorialDecisions`, 반영 기록 `adoptions`를 분리한다. 검토 동의만으로 쟁점을 해결하지 않으며, 수용 판단은 실제 반영 위치가 있어야 하고 거부 판단도 구체적인 편집 판단과 이유가 있어야 `RESOLVED`가 될 수 있다. 단계별 대상·출처 허용 행렬과 전역 고유 `issueKey` 계약은 A/B 계보 충돌, 중복 정의와 dangling 참조를 저장 전에 차단한다.

완료 산출물은 실행 폴더의 `final` 아래에 생성된다.

- 모드 1: 문서 유형별 최종 문서, `DEBATE_SUMMARY.md`, `DECISIONS.md`, `OPEN_QUESTIONS.md`
- 모드 2: 합의 문서 C, `source-trace.md`, `DEBATE_SUMMARY.md`, `DECISIONS.md`, `OPEN_QUESTIONS.md`
- 모드 3: `document-A-final.md`, `document-B-final.md`, `comparison.md`, `adoption-log.md`, `OPEN_QUESTIONS.md`

## 실행 데이터

기본 실행 기록과 최종 산출물은 저장소의 `results\<run-id>`에 생성된다. `results/`는 Git에서 제외되지만 재개·질문·근거 추가와 결과 열기에 필요한 실제 사용자 데이터이므로 캐시처럼 일괄 삭제하면 안 된다. 테스트 실행기는 별도 테스트 이름의 결과 루트를 사용하며, 저장소에는 완료 판정 요약과 재현 가능한 현재 workflow-v2 검증 경로만 유지한다.

오류가 발생하면 해당 실행 폴더의 `diagnostics.jsonl`에 진단 행을 append한다. 아직 run이 없거나 run 파일에 쓸 수 없으면 `%LOCALAPPDATA%\DuoForge\diagnostics\<diagnostic-id>\diagnostics.jsonl`로 폴백하며, 테스트·격리 환경에서는 `DUOFORGE_DATA_ROOT`가 같은 기준 루트를 대체한다. writer가 두 위치 모두 실패해도 원래 DF 오류와 상태는 유지하고 `DF-DIAGNOSTIC-WRITE` 경고만 추가한다. 오류가 없는 실행에는 빈 진단 파일을 만들지 않는다.

진단 행은 `diagnosticId`로 `steps.json`, 실패·재시도 `events.jsonl`, 진행 observer와 반환 결과를 연결한다. 화면에는 코드별 고정 공개 요약, 동일한 DF 코드·진단 ID와 writer가 실제로 사용한 진단 파일 경로만 표시한다. stdout·stderr 본문, 프롬프트, 문서·컨텍스트·모델 결과, 명령 인자, 환경변수 값, 인증정보, 절대 입력 경로, 원시 예외·스택과 임의 `Exception.Data`는 진단 파일이나 진행 화면에 기록하지 않는다.

지원이 필요하면 화면에 표시된 `DF-*` 오류 코드와 해당 `diagnostics.jsonl` 파일을 함께 제공한다. 화면에 표시되지 않은 입력 문서나 공급자 출력·인증정보를 추가로 첨부하지 않는다.

신규 실행은 사용되지 않는 `logs\` 폴더를 만들지 않는다. 기존 workflow-v1·초기 workflow-v2 실행이나 fixture에 이미 있는 `logs\`는 재개 중 삭제하거나 다시 쓰지 않는다.

Codex 메뉴는 DuoForge 프로세스를 시작할 때 CLI의 `app-server model/list`를 호출해 현재 계정에 노출된 모델, 기본 모델과 모델별 기본·지원 추론 정도를 다시 받는다. 이 호출이 실패하면 CLI 로컬 캐시, 마지막으로 제한된 내장 목록 순서로 폴백하며 메뉴에 출처와 경고를 표시한다. CLI가 지정한 기본 모델을 권장하고, `high`가 해당 모델에 실제로 존재할 때만 `high`를 권장한다. `high`가 사라지면 CLI 기본 추론 정도, `medium`, 첫 지원값 순서로 이동한다.

Claude CLI는 계정별 `/model` 전체 행을 기계 판독 목록으로 내보내지 않는다. 따라서 매 DuoForge 프로세스에서 설치된 `claude --help`가 광고하는 최신 계열 별칭과 effort를 다시 읽고, `opus|sonnet|fable` 같은 버전 비고정 별칭과 계정·조직 권장 모델을 런타임에 해석하는 `default`를 표시한다. `opus`와 `high`가 현재 CLI 목록에 있을 때만 권장하며, 사라지면 `default`와 현재 지원 effort로 이동한다. Claude Models API는 API 키가 필요하므로 구독 전용 정책을 지키기 위해 사용하지 않는다.

제안 목록에 없는 CLI 모델은 `모델명 직접 입력` 또는 `--codex-model`·`--claude-model`로 지정할 수 있으며, `[1m]` 같은 CLI 모델 접미사도 허용한다.

`start`는 선택한 문서를 작업 폴더에 별도로 보관하고 작업 기록까지만 만든다. AI 작업은 시작하지 않는다. 출력된 작업 ID로 현재 상태와 앞으로 가능한 AI 요청 횟수를 먼저 확인한다.

```powershell
.\duoforge.cmd status --run "run-20260727-..."
.\duoforge.cmd issues --run "run-20260727-..."
.\duoforge.cmd resume --run "run-20260727-..."
```

사용자 결정이 필요한 확인 사항이 있으면 질문 카드의 선택값을 기록한 뒤 마지막 문서 작성·확인 작업만 다시 실행한다. 현재 질문에 모두 답하면 답변을 반영해 검토하고, 그 결과 새로운 결정이 필요할 때만 다음 `사용자 확인 단계`를 연다. 최초 단계를 포함해 최대 3회(`1/3`~`3/3`)까지만 질문하며, 더 묻지 않아도 되면 즉시 완료한다. 미답변 질문이 있으면 명시적 `resume --live`도 AI 작업 전에 차단한다. 세 번째 답변 뒤에도 새 결정이 필요하면 네 번째 질문을 열지 않고 `QUESTION_LIMIT_REACHED`로 종료해 질문·확인 사항·결과 문서를 보존한다. 사용자 화면에는 `사용자 확인을 3번 거친 뒤 멈춤`으로 표시하며 완료나 일부 완료로 오해시키지 않는다.

```powershell
.\duoforge.cmd answer --run "run-20260727-..." --issue "D-001" --choice "1"
.\duoforge.cmd answer --run "run-20260727-..." --issue "D-001" --choice "2" --replace
.\duoforge.cmd constraint --run "run-20260727-..." --issue "D-001" --text "개인정보는 국내에만 저장한다."
.\duoforge.cmd constraint --run "run-20260727-..." --issue "D-001" --text "개인정보는 국내에만 저장한다." --confirm
.\duoforge.cmd extend-round --run "run-20260727-..."
.\duoforge.cmd resume --run "run-20260727-..." --live
```

질문 카드는 우선순위 순으로 한 번에 최대 3개만 표시한다. 각 질문은 작은 터미널에서도 섹션 제목과 2칸 들여쓴 본문을 다른 행으로 유지하며 `현재 상태 → 핵심 쟁점 → AI 검토와 문서 처리 → 사용자에게 요청하는 것 → 선택 결과` 순서로 설명한다. 승인·방향 선택·자료 요청 중 무엇이 필요한지 먼저 밝히고, 화면 높이가 남으면 핵심 쟁점·제안 방향·요청 내용에 여러 줄을 우선 배분한다. 그래도 긴 내용은 `[M] 자세히 보기·추가 검토 → 질문 내용 전체 보기`에서 저장·검증된 질문, 쟁점, AI 검토, 요청과 선택 결과를 줄이지 않고 터미널 스크롤로 읽은 뒤 결정 화면으로 돌아올 수 있다. `[M]`에는 추가 토론·AI 상세 설명·양쪽 의견 비교만 두고, 직접 답변과 여러 질문의 공통 전제는 `[O] 선택지에 없는 내 의견 직접 입력`으로 통합한다. 이 화면에도 원시 출력, 생성 중 텍스트, 전체 문서, 프롬프트와 모델 응답 원문은 표시하지 않는다. 한 질문의 답을 저장하면 남은 질문 목록을 바로 이어서 보여주고, 중간에 나가도 `사용자 요청으로 멈춤` 작업 메뉴의 `남은 질문에 답하기 (N)`으로 다시 들어갈 수 있다. 미답변 질문이 있으면 `답변 반영하고 AI 작업 계속하기`는 이유와 함께 비활성화한다. 화면에는 현재 사용자 확인 단계를 `1/3`처럼 표시하고, `3/3`에서는 이번 답변 뒤 새 질문이 생겨도 다시 묻지 않는다고 알린다. 문서 계보는 `문서 A/문서 B/최종 문서`, 사용자 선택은 `1안/2안/3안`, AI 작업자는 `Codex/Claude`로 표기를 분리한다. 신규 AI 질문은 실제로 선택할 수 있는 서로 다른 대안 두세 개만 허용하며, 권장안은 그중 하나를 가리켜야 한다. 스키마 설명이나 자리 표시가 선택지로 반환되면 저장 전에 형식 복구 대상으로 처리한다. 질문의 첫 선택 화면에서 `[O]`를 고르면 직접 쓴 내용을 `이 질문의 주관식 답변`으로 확정하거나 `여러 질문에 공통 전제`로 추가할 수 있다. 주관식 답변은 현재 질문을 답변 완료로 처리하고, 공통 전제는 객관식·주관식 답변과 함께 두 AI의 마지막 문서·검증 단계에 적용하되 현재 질문을 미답변으로 남긴다. 두 경로 모두 미리보기 뒤 정확한 `APPLY` 확인이 필요하며, 기존 답변 변경 화면에서도 같은 동작을 제공한다. 답변·공통 전제·추가 자료를 저장한 뒤에는 내부 단계 ID 대신 다시 진행할 관련 AI 작업 수를 보여준다. 이전 답변 변경 목록은 대상 문서·질문 제목·현재 답변을 함께 보여주고, 항목을 고르면 원래 질문·핵심 쟁점·현재 답변을 독립 섹션의 전체 본문으로 새 선택지보다 먼저 다시 보여준다. 신규 답변 기록에는 질문 제목과 문장을 함께 보존하며, 이 필드가 없는 기존 실행은 저장된 쟁점과 선택지로 질문을 복원했다는 안내를 표시한다. 화면과 신규 CLI 예시는 숫자 선택을 사용하지만 기존 `--choice A/B/C`도 같은 내부 결정 코드로 계속 읽는다. 답변 변경은 `--replace`로 이력을 남기며, 자유 제약은 미리보기를 확인한 뒤 `--confirm`으로 적용한다. 세 번째 라운드는 최대 AI 요청 횟수를 먼저 검사한 뒤 `extend-round`로 추가한다. 최신 사용자 답변과 공통 전제는 양쪽 최종 단계에 구속력 있게 주입되고 과거 라운드의 동일 질문은 최종 병합에서 확정 처리된다. 서로 양립할 수 없거나 안전하게 반영할 수 없으면 AI는 이를 조용히 무시하지 않고 새 확인 사항으로 알려야 한다. 반드시 해결해야 하는 항목은 보류할 수 없고, 중요 항목의 일부 완료 보류는 대화형 확인 또는 명시적인 `--confirm-partial`이 필요하다.

모든 사람용 터미널 화면은 같은 읽기 문법을 사용한다. 화면 제목과 상태 태그 뒤에는 터미널 폭에 맞춘 구분선을 두고, 큰 섹션은 `── 제목`, 본문은 2칸, 하위 본문은 4칸 들여쓴다. 긴 경로·설명·명령·키-값은 `WindowWidth - 1` 안에서 공백 우선으로 줄바꿈하며 이어진 줄은 값 또는 본문 시작 열에 맞춘다. 큰 섹션 사이는 기본 한 줄을 비우되 20~23행의 작은 화면은 공백을 줄이고 섹션 표식을 유지한다. 정보·상태·경고 블록 뒤에 별도의 선택 메뉴가 이어질 때는 메뉴 제목 전 한 줄을 비우며, 작은 화면에서는 메뉴 내부 설명이나 푸터 여백을 줄여 전체 높이를 지킨다. 이때 질문 카드는 바로 아래 선택 메뉴에 요청 종류가 반복되므로 한 줄 식별자만 남기고 상태 태그와 구분선을 생략할 수 있다. 색상과 Unicode를 쓸 수 없는 환경에서도 `--`, `OK`, `X`, `!`, `i` 표식으로 같은 상태와 다음 행동을 읽을 수 있다. 이 문법은 사람용 출력에만 적용되며 `--json`, 저장 JSON·JSONL과 생성된 최종 Markdown은 바꾸지 않는다.

호출당 크기를 넘는 Markdown의 신규 실행은 `context-plan` schema 2의 결정론적 의미 배치를 사용한다. ATX/Setext 제목과 제목 경로, 서문, 완결된 문단·목록·표·fenced code를 먼저 보존하고, 하나의 의미 단위가 상한을 넘을 때만 문단·줄·UTF-8 안전 바이트 순서로 폴백한다. XML escape 뒤 실제 전송 바이트도 분할 시점에 계산하므로 특수문자가 많은 CORE는 의미 경계를 가능한 한 보존하면서 호출 상한 안으로 더 나뉜다. 각 팩의 `DOCUMENT_MAP`, `BEFORE`, `AFTER`는 위치와 연결을 위한 `context-only` 영역이고 `CORE`만 사실 분석과 근거에 사용할 수 있다. 완성 프롬프트 크기는 실행 생성 시점과 각 단계 소비 시점에 모두 검증한다.

신규 `duoforge-stage-v5` 실행은 원문이 호출 한도의 30%를 넘으면 문맥 배치를 사용해 이후 계보·결정·지시문 공간을 예약한다. 문서별 최종 확인은 모든 보이는 선행 산출물의 SHA-256을 먼저 검증하되, 요청에는 대상 최신 문서와 그 대상의 쟁점·응답·채택·질문만 넣는다. 비대상 문서와 반복된 과거 문서·요약은 전송하지 않으며 투영 산출물은 50%, 사용자 결정·근거 메타데이터는 12.5% 예산을 넘으면 공급자 호출 전에 실패 폐쇄한다.

기존 v4 실행이 AI 호출 전에 `DF-PROMPT-SIZE-LIMIT`로 멈추면 일반 이어하기를 제공하지 않고 `입력 크기 조정 필요`로 표시한다. 메뉴 또는 `repair-prompt`에서 정확한 `REPAIR`를 입력해야 실행당 한 번 v5 입력 투영으로 복구를 준비하며, 이 동작은 공급자를 호출하지 않는다. 준비 뒤 실제 실행에는 다시 별도의 정확한 `LIVE` 확인이 필요하다.

커버리지는 중복 브리지가 아닌 `CORE` 원본 범위만으로 계산한다. 완전 커버리지가 불가능하면 시작 시 `--allow-partial`이 있어야 하며, A/B 각각에 최소 한 배치를 확보한 뒤 각 문서의 앞·뒤가 한쪽에 치우치지 않도록 결정론적으로 선택한다. 두 문서를 모두 분석할 호출 여유가 없으면 시작 전에 거부한다. 누락 섹션 ID·바이트·문서별 커버리지는 `context-plan.json`과 `COVERAGE.md`에 기록하고 `COMPLETED_PARTIAL`로 표시한다. 기존 context-plan schema 1과 workflow-v1·초기 workflow-v2 저장 실행은 기존 팩·그래프·프롬프트를 재분할하거나 재작성하지 않고 해당 세대 그대로 재개한다. 누적 모델 실행 시간이 90분에 도달하면 다음 공급자 호출 전에 실패 폐쇄한다. 구조 오류는 같은 프롬프트를 반복하지 않고 전용 `FORMAT_REPAIR` 요청으로 한 번만 복구하며, 허용 시도를 모두 사용하면 terminal `FAILED_STAGE`로 전이해 일반 이어하기를 숨긴다. `attemptCount`는 현재 입력 세대의 형식 복구 예산, `totalAttemptCount`는 누적 실제 공급자 호출 감사·총예산에 사용하므로 사용자 답변 등으로 입력 세대가 바뀌어도 누적 호출은 사라지지 않는다. 완료 산출물이 없거나 해시·스키마가 손상되면 원인을 분리하고 해당 단계와 의존 단계만 감사 이력으로 보존한 뒤 재실행한다. 쟁점 정의 대상과 참조 대상은 별도로 검증해 원장 자기 참조를 중복 정의로 오판하지 않는다.

같은 장벽의 Codex·Claude 단계는 현재 순차 호출되지만, 각 프롬프트에는 단계 그래프상 전이적 선행 단계의 산출물만 들어간다. 따라서 먼저 호출된 공급자의 같은 단계 결과는 뒤 공급자에게 공개되지 않으며, 실패 재시도·사용자 일시정지·프로세스 재개 후에도 양쪽이 동일한 선행 산출물 집합에서 판단한다. 양쪽 단계가 모두 커밋된 뒤에만 다음 장벽이 그 결과를 함께 볼 수 있다. 이 정책 이전에 생성된 미완료 실행은 혼합 규칙으로 조용히 재개하지 않고 새 실행 생성을 요구한다.

쟁점 설명은 Codex, Claude 또는 양쪽 관점과 초급·일반·전문가 수준을 선택할 수 있다. 저장된 설명 조회는 호출하지 않으며, 새 설명은 `--live`와 대화형 `LIVE` 확인이 모두 필요하다. 실행당 설명 호출은 최대 6회다.

```powershell
.\duoforge.cmd explain --run "run-20260727-..." --issue "D-001" --provider both --level beginner
.\duoforge.cmd explain --run "run-20260727-..." --issue "D-001" --provider both --level beginner --live
```

`AWAITING_EVIDENCE` 상태에서는 요청된 Markdown 근거를 실행 폴더 밖에서 추가한다. 목록은 검토 항목의 식별 정보만 요약하고, 항목을 고르면 핵심 쟁점과 필요한 자료를 줄이지 않고 보여준 뒤 파일을 선택한다. 원본을 변경하지 않고 `E######.md` 불변 스냅샷으로 보존하며, 관련된 마지막 문서 단계만 다시 실행 대상으로 만든다.

```powershell
.\duoforge.cmd evidence --run "run-20260727-..." --issue "D-002" --file ".\proof.md"
.\duoforge.cmd resume --run "run-20260727-..." --live
```

라이브 진행판에서 `P`를 누르거나 별도 터미널에서 `pause`를 요청하면 현재 모델 호출은 끝까지 보존하고 다음 호출 전에 `PAUSED_USER`로 멈춘다. 진행판의 `P`는 대소문자를 구분하지 않으며 한 번만 요청된다. `--pause-after-round`를 선택한 실행은 각 라운드 경계에서 한 번씩 멈춘다. 구독 한도 오류는 `PAUSED_QUOTA`로 분류하며 API 과금 방식으로 자동 전환하지 않는다.

```powershell
.\duoforge.cmd pause --run "run-20260727-..."
```

더 이상 이어가지 않을 작업은 작업 메뉴의 `이 작업 포기`로 종료한다. 포기는 상태를 `CANCELLED`로 바꾸고 AI 작업 재개를 막지만 문서 사본, 답변, 진단과 감사 기록은 그대로 보존한다. 포기한 작업은 홈의 `포기한 작업 관리`에서 다시 확인할 수 있다. 정확한 `RESTORE` 확인으로 복원하면 이전 상태와 관계없이 `PAUSED_USER`로 돌아가며, 복원만으로 AI 작업이나 재개가 시작되지는 않는다. 영구 삭제는 포기한 작업에만 표시되며, 별도의 `DELETE` 확인 뒤 해당 `results\<run-id>` 폴더 전체를 삭제한다. 원본 입력 문서는 실행 폴더 밖에 있으므로 삭제 대상에 포함하지 않는다.

```powershell
.\duoforge.cmd abandon --run "run-20260727-..."
.\duoforge.cmd restore --run "run-20260727-..."
.\duoforge.cmd delete --run "run-20260727-..."
```

무인 자동화에서는 각각 `--confirm-abandon`, `--confirm-restore`, `--confirm-delete`를 명시해야 한다. 복원은 실행 잠금 안에서 `CANCELLED`를 다시 확인하고 상태와 `RUN_RESTORED` 이벤트를 원자적으로 기록한다. `delete`는 실행 결과 루트의 직계 `run-*` 폴더, 저장된 작업 ID 일치, `CANCELLED` 상태, 실행 잠금과 연결 지점 부재를 모두 확인한 뒤에만 동작한다.

실제 Codex·Claude 작업은 대화형 PowerShell에서만 시작할 수 있다. 저장된 AI별 모델·분석 깊이와 전송할 문서, `예정 요청`, `실패 시 추가 요청`, `최대 요청`을 쉬운 문장으로 다시 보여준 뒤 확인어 `LIVE`를 입력해야 한다. `LIVE`는 제품 기능명이 아니라 문서 전송과 AI 작업 시작에 동의하는 확인어다. 선택 정보가 없는 이전 형식의 작업 기록은 이어서 실행할 수 없다.

```powershell
.\duoforge.cmd resume --run "run-20260727-..." --live
```

### 고정형 토론 진행판

대화형 메뉴의 `R → LIVE`와 명시적 `resume --live`는 PowerShell 7 터미널에서 고정형 진행판을 연다. 진행판은 선택한 모드의 실제 단계 장벽을 표시하고, 현재 공급자·작업 단계·대상 문서·경과 시간과 검증·커밋된 최근 결과 최대 3건을 보여준다. 현재 작업의 한 셀 스피너는 기존 초 단위 heartbeat로만 움직이며 별도 타이머나 모델 호출을 만들지 않고 진행률을 뜻하지도 않는다. 공급자 프로세스 callback은 모듈 private 함수 이름을 closure 밖에서 다시 찾지 않고 캡처한 진입점을 사용한다. observer 또는 프레임 렌더 오류는 원문 예외 없이 고정 코드와 횟수를 한 번만 기록하고 공급자 호출을 계속하며, 전체화면을 유지할 수 없으면 heartbeat 중복이 없는 누적 로그로 폴백한다. 최근 결과는 파일 시각이 아니라 단계 그래프에서 유효한 마지막 3건을 선택한 뒤 오래된 것부터 표시한다. 단계에 문서 계보가 기록되어 있으면 문서 A·문서 B·문서 A/B·공동 문서·합의 문서 C로 구분하고, workflow-v1에 없는 계보는 추정하지 않는다.

```text
DUOFORGE  LIVE 진행 화면
진행  ███████████░░░░░  7/13 · 진행 중
단계별 진행 ─────────────────────────────────────────────
✓ 1차  각자 초안 작성       Codex ✓  Claude ✓
✓ 1차  서로의 초안 검토     Codex ✓  Claude ✓
● 1차  검토 의견 판단       Codex ✓  Claude ●
────────────────────────────────────────────────────────
지금 작업 중  ⠼ Claude · 검토 의견 판단 · 답변을 기다리는 중 00:31
작업 대상  공동 문서
최근 완료  1/3    Codex✓ 1차 서로의 초안 검토 · 공동 문서
최근 완료  2/3    Claude✓ 1차 검토 의견 판단 · 공동 문서
최근 완료  3/3  › Codex✓ 1차 공동 문서 작성 · 공동 문서
  승인된 수정만 문서에 반영했습니다.
  변경 사항  새 항목: 중요 2 | 의견: 자료 필요 1 | 반영: 반영 1
```

공급자 응답 수신은 단계 성공으로 취급하지 않는다. 스키마 검증, 비밀값 제거, 원자적 산출물 저장과 상태 커밋이 모두 끝난 `COMMITTED` 상태의 단계 중 산출물 해시와 해당 workflow의 단계 결과 스키마를 다시 통과한 결과만 공개한다. 손상된 항목은 피드에서 제외하고 더 오래된 유효 항목으로 최대 3건을 채운다. `context-batch-analysis`는 공급자 원요약 대신 일반화된 안전 문구만 표시하며, 원시 응답, 생성 중 텍스트와 내부 사고 과정은 표시하지 않는다.

개요는 최신 항목을 처음 선택한다. `↑/↓` 또는 `J/K`로 이동하고 `D`로 한 건의 상세 화면을 열 수 있다. 상세는 선택한 항목의 정제 요약과 변경 집계만 보여주며 `PgUp/PgDn/Home/End`로 스크롤하고 `Esc`로 개요에 돌아간다. `P`는 어느 화면에서든 `현재 AI 작업이 끝난 뒤 멈추기`를 한 번만 요청하고, `Enter`는 종료 확인에만 사용한다.

높이가 `20~23`행이면 선택한 1건, `24~31`행이면 2건, `32`행 이상이면 최대 3건을 여러 줄로 펼친다. 요약은 공백을 우선해 줄바꿈하고 긴 한 단어만 안전하게 나누며, 가용 높이가 줄면 접힌 헤더·현재 작업·장벽 최소 3개·하단 상태를 먼저 보존한다. 화면 문구는 `새 항목`, `의견 처리`, `문서 반영`, `분석 깊이`처럼 일상어를 쓰지만 내부 상태·스키마와 JSON 값은 바꾸지 않는다.

라이브 실행 자체는 최종 계획 확인을 위해 비리디렉션 대화형 입출력을 요구하며, 리디렉션된 `resume --live`는 공급자 호출 전에 `DF-LIVE-NONINTERACTIVE`로 차단한다. 지원 호스트인 PowerShell 7 독립 ConsoleHost 또는 Windows Terminal에서 VT를 지원하고 창이 최소 `72×20`이면 대체 화면 버퍼를 사용한다. 대화형 호스트에서 VT가 없거나 창이 좁거나 화면 갱신이 실패하면 모델 실행을 중단하지 않고 ANSI 없는 축약형 누적 진행 로그로 전환한다. 실패·재시도·중단 복구·최종 renderer 오류에는 고정형 진행판과 누적 로그 모두 같은 DF 코드·진단 ID·실제 진단 파일 경로를 표시한다. 누적 로그는 기존처럼 단계 전환과 해당 단계의 최신 확정 요약 한 건만 기록하고 초 단위 heartbeat에는 같은 요약을 반복하지 않는다. 종료 화면에서 Enter를 누르면 대화형 메뉴 실행은 작업 메뉴로, 명시적 `resume --live`는 셸 프롬프트로 돌아가며 메뉴 복귀 화면과 명시적 JSON 결과에도 같은 진단 참조가 남는다.

기존 공급자별 라이브 스모크와 2라운드 전체 단계 E2E는 `workflow-v1 shared-document/dual-document`의 역사적 증거이며 신규 모드 완료로 재해석하지 않는다. 대체된 workflow-v1 테스트 전용 실행기와 생성 결과는 저장소 정리 범위에서 제거했으며, workflow-v1 읽기·재개 호환성은 직렬화 fixture를 사용하는 오프라인 회귀로 계속 보호한다. 2026-07-28에는 별도 `workflow-v2` 실제 공급자 E2E를 실행해 모드 1 `13/13`, 모드 2 `13/13`, 모드 3 `14/14` 단계와 입력 해시 불변·A/B 계보·최종 파일·이벤트 비노출을 확인했다. 라이브 검증기는 이제 신규 `logs\` 부재와 선택적으로 존재하는 `diagnostics.jsonl`의 Depth 100 재파싱·허용 목록·canary 비노출도 검사한다. 세 모드 모두 `AWAITING_USER` 체크포인트로 강화 검증을 통과했다. 이는 질문 카드와 사용자 게이트가 정상 작동한 E2E 성공 상태이며, 테스트 픽스처의 결정을 임의로 답해 `COMPLETED`로 바꾸는 추가 공급자 호출은 완료 조건이 아니다. 모드 3 최초 실행에서 발견한 Minor 근거 대기의 잘못된 차단 상태는 중앙 차단 규칙 재계산으로 수정한 뒤 신규 실제 공급자 실행으로 재검증했다. 실행 ID와 판정 근거는 [docs/STAGE0_SPIKE.md](docs/STAGE0_SPIKE.md)에 기록한다.

## 테스트

2026-07-31 기준 PowerShell 7 오프라인 회귀는 162개다. 기존 회귀에 더해 실제 프로세스 heartbeat callback의 `0,1,2`초 전달과 스피너 프레임 변화, observer·프레임 오류의 고정 코드 단일 폴백, 쟁점 정의/참조 대상 분리, 현재 입력 세대 시도와 누적 호출 분리, 재시도 소진의 `FAILED_STAGE`, 복합 실행의 0-call 복구, 공급자 프로세스 오류의 안전 분류와 doctor·카탈로그·단계 호출 컨텍스트 동일성을 포함하며 모두 통과한다.

실제 공급자 E2E의 테스트 전용 Claude 선택은 `tests\workflow-v2-live-settings.json`에서 관리하며 현재 `sonnet/low`로 고정한다. 전체 workflow-v2 라이브 E2E 실행기는 이 설정과 정확한 `LIVE` 동의를 요구한다. 진행판 전용 `tests\Invoke-LiveProgressE2E.ps1`은 실제 카탈로그가 노출한 Codex `gpt-5.6-luna/low`와 Claude `sonnet/low`만 허용하고 다른 모델로 대체하지 않으며, 첫 Codex·Claude 장벽 뒤 자동 `PAUSED_USER`를 요구한다. 2026-07-31 최초 실행, 별도 승인한 재시험, 비관리자 호스트 재검증 `run-20260731-142621-3d2365`, 재부팅 후 재검증 `run-20260731-163804-17c44b` 모두 Codex 첫 호출이 동일한 `DF-PROVIDER-PROCESS`(종료 코드 1, stdout 0바이트, stderr 163바이트)로 끝나 Claude를 호출하지 않았다. 네 실행 모두 모델 대체나 실행 내 자동 재시도 없이 실패 폐쇄했다. 세 번째와 네 번째 실행은 `STANDARD`, 프로필 일치, PowerShell 7.6.3 `ConsoleHost`, 비리디렉션 `120×30` 환경에서 수행했으며, 네 번째 실행 직전과 직후 8501 리스너 및 Python 프로세스는 0이었다. 따라서 관리자 권한·프로필 불일치와 Streamlit/Uvicorn 서버는 각각 단독 원인이 아니다. 실제 화면의 장시간 프레임 변화와 2-call `PAUSED_USER` 성공은 아직 입증되지 않았으며, 오프라인 callback·프레임 회귀와 구분해 기록한다. 일반 실행의 모델 선택 화면과 사용자 실행에 저장된 선택값은 바꾸지 않으며, 과거 `opus/high` E2E는 문서화된 시점 증거로만 취급하고 재호출하지 않는다.

현재 Codex 경로는 doctor·모델 카탈로그·단계 호출 모두 같은 `node.exe`와 `codex.js`, 인증 home과 정제된 자식 환경을 사용한다. 카탈로그 가시성은 실제 모델 호출 가능성을 증명하지 않으므로 doctor에는 `UNVERIFIED`로 표시한다. 종료 코드가 0이 아닌 공급자 프로세스의 stderr는 메모리에서만 고정 안전 사유로 분류하고 즉시 버리며 stdout은 분류 입력으로 쓰지 않는다. `MODEL_UNAVAILABLE`, `AUTH`, `INVALID_OPTION`, `SCHEMA_REJECTED`, `NETWORK`, `REASONING_UNAVAILABLE`, `MODEL_CONFIGURATION_UNAVAILABLE`을 포함한 합성 fixture가 원시 stdout·stderr 제거를 검증한다. 전용 LIVE 실행기는 관리자 PowerShell을 거부한다. 일반 비관리자 PowerShell 7에서도 동일 실패를 재현했으므로 권한은 단독 원인이 아니다.

현재 사용자 Codex 기본 설정은 `gpt-5.6-sol/high`지만 DuoForge 단계 실행은 저장된 선택값을 `--model`과 `model_reasoning_effort`로 명시하고 `--ignore-user-config`를 사용하므로 같은 호출 프로필이 아니다. `codex-cli 0.146.0`의 실제 카탈로그는 Sol의 `high`, Luna의 `low`·`medium`을 모두 노출했고, 세 조합과 Luna/low 단계 스키마 조합의 전체 인자 배열은 parse-only 검사에서 모두 종료 코드 0이었다. 원본 성공 실행은 `codex-cli 0.145.0`의 Sol/high였으므로 현재 결함은 모델 이름 오타보다 비대화형 `exec`의 실제 요청·스키마·버전 경계를 분리해 확인해야 한다. `tests\Invoke-CodexInvocationMatrix.ps1`은 정확한 새 `LIVE` 한 번에 Sol/high 기본 호출, Luna/low 기본 호출, Luna/medium 기본 호출, 조건부 Luna/low 단계 스키마 호출만 순서대로 수행하며 예상 3회·절대 상한 4회와 `PAUSED_USER` 안전 요약을 강제한다.

```powershell
& 'C:\Program Files\PowerShell\7\pwsh.exe' -NoProfile -File '.\tests\Run-Tests.ps1'
```

구현 단계와 안전 판단은 [docs/IMPLEMENTATION_PLAN.md](docs/IMPLEMENTATION_PLAN.md), 당시 CLI·실제 공급자 E2E 검증 기록은 [docs/STAGE0_SPIKE.md](docs/STAGE0_SPIKE.md), 3A 격리 판정은 [docs/3A_ISOLATION_SPIKE.md](docs/3A_ISOLATION_SPIKE.md)를 참고한다. 현재 설치·로그인·모델 사용 가능 상태는 `.\duoforge.cmd doctor --json`으로 다시 확인한다.
