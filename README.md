# DuoForge

DuoForge는 Codex와 Claude가 같은 입력 스냅샷을 독립적으로 검토하고 서로의 결과를 비평하도록 조율하는 Windows 로컬 우선 CLI다.

현재 저장소는 PRD v1.4의 문서 모드 Core Beta 구현이다. 공통 안전 기반, 진단, 필수 모델·추론 정도 선택, 실행 계획, 불변 스냅샷, 구조화 토론 단계, 재개 가능한 상태 저장, 쟁점 설명·근거 추가·사용자 결정과 최종 산출물 렌더링을 제공한다. 프로젝트 읽기 전용 비교(3A)는 현재 Windows 격리 후보가 범위 밖 읽기와 자식 프로세스 차단에 실패하여 의도적으로 비활성화되어 있다.

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
  --codex-model "gpt-5.6-sol" `
  --codex-effort "high" `
  --claude-model "opus" `
  --claude-effort "high" `
  --type "prd" `
  --max-rounds 2 `
  --pause-after-round `
  --plan-only
```

`--plan-only`는 모델을 호출하거나 확정 실행을 만들지 않고 선택한 모델·추론 정도, 검증·전송 범위와 최악 호출 수만 보여준다. 네 선택 옵션은 생략할 수 없으며, 인수 없이 여는 대화형 메뉴에서는 각 항목을 번호로 반드시 선택한다.

Codex 메뉴는 DuoForge 프로세스를 시작할 때 CLI의 `app-server model/list`를 호출해 현재 계정에 노출된 모델, 기본 모델과 모델별 기본·지원 추론 정도를 다시 받는다. 이 호출이 실패하면 CLI 로컬 캐시, 마지막으로 제한된 내장 목록 순서로 폴백하며 메뉴에 출처와 경고를 표시한다. CLI가 지정한 기본 모델을 권장하고, `high`가 해당 모델에 실제로 존재할 때만 `high`를 권장한다. `high`가 사라지면 CLI 기본 추론 정도, `medium`, 첫 지원값 순서로 이동한다.

Claude CLI는 계정별 `/model` 전체 행을 기계 판독 목록으로 내보내지 않는다. 따라서 매 DuoForge 프로세스에서 설치된 `claude --help`가 광고하는 최신 계열 별칭과 effort를 다시 읽고, `opus|sonnet|fable` 같은 버전 비고정 별칭과 계정·조직 권장 모델을 런타임에 해석하는 `default`를 표시한다. `opus`와 `high`가 현재 CLI 목록에 있을 때만 권장하며, 사라지면 `default`와 현재 지원 effort로 이동한다. Claude Models API는 API 키가 필요하므로 구독 전용 정책을 지키기 위해 사용하지 않는다.

제안 목록에 없는 CLI 모델은 `모델명 직접 입력` 또는 `--codex-model`·`--claude-model`로 지정할 수 있으며, `[1m]` 같은 CLI 모델 접미사도 허용한다.

확정 실행은 `start`에서 스냅샷까지만 만든다. 출력된 실행 ID를 사용해 상태와 남은 호출 수를 먼저 확인한다.

```powershell
.\duoforge.cmd status --run "run-20260727-..."
.\duoforge.cmd issues --run "run-20260727-..."
.\duoforge.cmd resume --run "run-20260727-..."
```

차단 쟁점이 사용자 결정을 기다리면 질문 카드의 선택값을 기록한 뒤 마지막 합성·검증 단계만 다시 실행한다.

```powershell
.\duoforge.cmd answer --run "run-20260727-..." --issue "D-001" --choice "A"
.\duoforge.cmd answer --run "run-20260727-..." --issue "D-001" --choice "B" --replace
.\duoforge.cmd constraint --run "run-20260727-..." --issue "D-001" --text "개인정보는 국내에만 저장한다."
.\duoforge.cmd constraint --run "run-20260727-..." --issue "D-001" --text "개인정보는 국내에만 저장한다." --confirm
.\duoforge.cmd extend-round --run "run-20260727-..."
.\duoforge.cmd resume --run "run-20260727-..." --live
```

질문 카드는 우선순위 순으로 한 번에 최대 3개만 표시한다. 답변 변경은 `--replace`로 이력을 남기며, 자유 제약은 미리보기를 확인한 뒤 `--confirm`으로 적용한다. 세 번째 라운드는 호출 상한을 먼저 검사한 뒤 `extend-round`로 추가한다. 최신 사용자 답변은 양쪽 최종 단계에 공통 제약으로 주입되고 과거 라운드의 동일 질문은 최종 병합에서 확정 처리된다. Critical 쟁점은 보류할 수 없고, Major 쟁점의 부분 완료 보류는 대화형 확인 또는 명시적인 `--confirm-partial`이 필요하다.

호출당 크기를 넘는 UTF-8 입력은 고정 문맥 배치로 분할하고 예상·실제 커버리지를 `COVERAGE.md`에 기록한다. 완전한 커버리지가 불가능하면 시작 시 `--allow-partial`이 있어야 `COMPLETED_PARTIAL`로 진행한다. 누적 모델 실행 시간이 90분에 도달하면 다음 공급자 호출 전에 실패 폐쇄한다. 구조 오류는 같은 프롬프트를 반복하지 않고 전용 `FORMAT_REPAIR` 요청으로 한 번만 복구하며, 완료 산출물이 손상되면 해당 단계와 의존 단계만 감사 이력으로 보존한 뒤 재실행한다.

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

공급자별 1회 라이브 스모크와 두 문서 모드의 2라운드 전체 단계 E2E는 `gpt-5.6-sol/high`와 `Opus 5(opus)/high`로 통과했다. 공동 문서는 13/13 단계, 독립 문서는 12/12 단계를 커밋했고, 독립 문서 실행은 사용자 결정 8건을 반영한 뒤 `COMPLETED`에 도달했다. 두 실행에서 구조화 출력, 금지 도구 이벤트 0건, 원본 해시 동일, 임시 작업물 정리와 호출 후 구독 인증 유지를 확인했으며 자세한 근거는 [docs/STAGE0_SPIKE.md](docs/STAGE0_SPIKE.md)에 기록했다. 3A Windows 격리 후보는 쓰기는 차단했지만 범위 밖 읽기와 자식 프로세스 실행을 허용하여 안전 게이트를 통과하지 못했으며, 상세 결과는 [docs/3A_ISOLATION_SPIKE.md](docs/3A_ISOLATION_SPIKE.md)에 기록했다.

## 테스트

```powershell
& "C:\Program Files\PowerShell\7\pwsh.exe" -NoLogo -NoProfile -File ".\tests\Run-Tests.ps1"
```

구현 단계와 안전 판단은 [docs/IMPLEMENTATION_PLAN.md](docs/IMPLEMENTATION_PLAN.md), 현재 CLI 검증 근거는 [docs/STAGE0_SPIKE.md](docs/STAGE0_SPIKE.md), 3A 격리 판정은 [docs/3A_ISOLATION_SPIKE.md](docs/3A_ISOLATION_SPIKE.md)를 참고한다.
