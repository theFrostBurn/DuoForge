# DuoForge

DuoForge는 Codex와 Claude가 같은 입력 스냅샷을 독립적으로 검토하고 서로의 결과를 비평하도록 조율하는 Windows 로컬 우선 CLI다.

현재 저장소는 PRD v1.3의 문서 모드 Core Beta 구현이다. 공통 안전 기반, 진단, 실행 계획, 불변 스냅샷, 구조화 토론 단계, 재개 가능한 상태 저장과 최종 산출물 렌더링을 제공한다. 프로젝트 읽기 전용 비교(3A)는 안전 격리 검증 전까지 의도적으로 비활성화되어 있다.

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
  --type "prd" `
  --max-rounds 2 `
  --plan-only
```

`--plan-only`는 모델을 호출하거나 확정 실행을 만들지 않고 검증·전송 범위·최악 호출 수만 보여준다.

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

실제 Codex·Claude 구독 CLI 호출은 대화형 PowerShell에서만 다음처럼 시작할 수 있다. 전송 경고와 공급자별 최악 추가 호출 수를 다시 표시한 뒤 정확히 `LIVE`를 입력해야 한다.

```powershell
.\duoforge.cmd resume --run "run-20260727-..." --live
```

라이브 E2E는 아직 실행하지 않았다. 현재 공급자 버전에서 최초 실제 실행을 승인하기 전에는 `doctor` 결과와 [docs/STAGE0_SPIKE.md](docs/STAGE0_SPIKE.md)의 잔여 경계를 확인해야 한다.

## 테스트

```powershell
& "C:\Program Files\PowerShell\7\pwsh.exe" -NoLogo -NoProfile -File ".\tests\Run-Tests.ps1"
```

구현 단계와 안전 판단은 [docs/IMPLEMENTATION_PLAN.md](docs/IMPLEMENTATION_PLAN.md), 현재 CLI 검증 근거는 [docs/STAGE0_SPIKE.md](docs/STAGE0_SPIKE.md)를 참고한다.
