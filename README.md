# DuoForge

DuoForge는 Codex와 Claude가 같은 입력 스냅샷을 독립적으로 검토하고 서로의 결과를 비평하도록 조율하는 Windows 로컬 우선 CLI다.

현재 저장소는 PRD v1.4의 문서 모드 Core Beta 구현이다. 공통 안전 기반, 진단, 필수 모델·추론 정도 선택, 실행 계획, 불변 스냅샷, 구조화 토론 단계, 재개 가능한 상태 저장, 쟁점 설명·근거 추가·사용자 결정과 최종 산출물 렌더링을 제공한다. 프로젝트 읽기 전용 비교(3A)는 안전 격리 검증 전까지 의도적으로 비활성화되어 있다.

## 요구 환경

- Windows 10/11
- PowerShell 7 이상
- Codex CLI와 Claude Code CLI
- 각 공급자의 구독 로그인

## 실행

```powershell
.\duoforge.cmd
```

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
  --codex-model "gpt-5.6" `
  --codex-effort "high" `
  --claude-model "sonnet" `
  --claude-effort "high" `
  --type "prd" `
  --max-rounds 2 `
  --pause-after-round `
  --plan-only
```

`--plan-only`는 모델을 호출하거나 확정 실행을 만들지 않고 선택한 모델·추론 정도, 검증·전송 범위와 최악 호출 수만 보여준다. 네 선택 옵션은 생략할 수 없으며, 인수 없이 여는 대화형 메뉴에서는 각 항목을 번호로 반드시 선택한다. 제안 목록에 없는 CLI 모델은 `모델명 직접 입력` 또는 `--codex-model`·`--claude-model`로 지정할 수 있다. Codex 추론 정도는 `low|medium|high|xhigh|max|ultra`, Claude는 `low|medium|high|xhigh|max` 중에서 고른다.

확정 실행은 `start`에서 스냅샷까지만 만든다. 출력된 실행 ID를 사용해 상태와 남은 호출 수를 먼저 확인한다.

```powershell
.\duoforge.cmd status --run "run-20260727-..."
.\duoforge.cmd issues --run "run-20260727-..."
.\duoforge.cmd resume --run "run-20260727-..."
```

차단 쟁점이 사용자 결정을 기다리면 질문 카드의 선택값을 기록한 뒤 마지막 합성·검증 단계만 다시 실행한다.

```powershell
.\duoforge.cmd answer --run "run-20260727-..." --issue "D-001" --choice "A"
.\duoforge.cmd resume --run "run-20260727-..." --live
```

Critical 쟁점은 보류할 수 없다. Major 쟁점의 부분 완료 보류는 대화형 확인 또는 명시적인 `--confirm-partial`이 필요하다.

쟁점 설명은 Codex, Claude 또는 양쪽 관점과 초급·일반·전문가 수준을 선택할 수 있다. 저장된 설명 조회는 호출하지 않으며, 새 설명은 `--live`와 대화형 `LIVE` 확인이 모두 필요하다. 실행당 설명 호출은 최대 6회다.

```powershell
.\duoforge.cmd explain --run "run-20260727-..." --issue "D-001" --provider both --level beginner
.\duoforge.cmd explain --run "run-20260727-..." --issue "D-001" --provider both --level beginner --live
```

`AWAITING_EVIDENCE` 상태에서는 요청된 Markdown 근거를 실행 폴더 밖에서 추가한다. 원본을 변경하지 않고 `E######.md` 불변 스냅샷으로 보존하며, 관련된 마지막 문서 단계만 다시 실행 대상으로 만든다.

```powershell
.\duoforge.cmd evidence --run "run-20260727-..." --issue "D-002" --file ".\proof.md"
.\duoforge.cmd resume --run "run-20260727-..." --live
```

실행 중 `pause`를 요청하면 현재 모델 호출은 끝까지 보존하고 다음 호출 전에 `PAUSED_USER`로 멈춘다. `--pause-after-round`를 선택한 실행은 각 라운드 경계에서 한 번씩 멈춘다. 구독 한도 오류는 `PAUSED_QUOTA`로 분류하며 API 과금 방식으로 자동 전환하지 않는다.

```powershell
.\duoforge.cmd pause --run "run-20260727-..."
```

실제 Codex·Claude 구독 CLI 호출은 대화형 PowerShell에서만 다음처럼 시작할 수 있다. 저장된 공급자별 모델·추론 정도, 전송 경고와 최악 추가 호출 수를 다시 표시한 뒤 정확히 `LIVE`를 입력해야 한다. 선택 정보가 없는 이전 형식의 실행 기록은 라이브 재개할 수 없다.

```powershell
.\duoforge.cmd resume --run "run-20260727-..." --live
```

라이브 E2E는 아직 실행하지 않았다. 현재 공급자 버전에서 최초 실제 실행을 승인하기 전에는 `doctor` 결과와 [docs/STAGE0_SPIKE.md](docs/STAGE0_SPIKE.md)의 잔여 경계를 확인해야 한다. 실제 구독 호출과 3A OS 격리 실험은 별도 승인 작업이다.

## 테스트

```powershell
& "C:\Program Files\PowerShell\7\pwsh.exe" -NoLogo -NoProfile -File ".\tests\Run-Tests.ps1"
```

구현 단계와 안전 판단은 [docs/IMPLEMENTATION_PLAN.md](docs/IMPLEMENTATION_PLAN.md), 현재 CLI 검증 근거는 [docs/STAGE0_SPIKE.md](docs/STAGE0_SPIKE.md)를 참고한다.
