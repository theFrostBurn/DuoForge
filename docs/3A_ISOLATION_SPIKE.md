# 3A Windows OS 격리 스파이크

검증일: 2026-07-27
환경: Windows, PowerShell 7.6.3, Codex CLI 0.145.0

## 목적

`dual-project-audit`를 활성화하기 전에 모델 프로세스가 다음 세 계약을 선제적으로 만족하는지 검증한다.

1. 허용된 프로젝트 범위 밖 파일을 읽을 수 없다.
2. 프로젝트 원본과 외부 경로에 파일을 쓸 수 없다.
3. 셸을 포함한 자식 프로세스를 만들 수 없다.

실행 후 이벤트 감사만으로는 충분하지 않다. 세 조건 중 하나라도 증명하지 못하면 `DF-PREFLIGHT-3A-ISOLATION`으로 실패 폐쇄한다.

## 픽스처

- 허용 범위 후보: `tests/fixtures/3a-spike/project-a`
- 비교 프로젝트: `tests/fixtures/3a-spike/project-b`
- 범위 밖 읽기 표식: `tests/fixtures/3a-spike/outside/sentinel.txt`
- 쓰기 표식: `tests/fixtures/3a-spike/project-a/write-target.txt`

쓰기 표식의 실행 전 SHA-256은 `FF362198959A58D2A99B4AD71E2A613C721CE60B50243245E9086ECF7A45D173`이다.

## 검증한 후보

Codex CLI가 제공하는 Windows 제한 토큰 샌드박스를 읽기 전용 모드로 실행했다.

```powershell
codex sandbox -c 'sandbox_mode="read-only"' -- <검증 명령>
```

각 검증은 별도 프로세스로 실행했으며, 쓰기 검증 전후에 오케스트레이터가 직접 SHA-256을 계산했다.

## 결과

| 계약 | 관찰 결과 | 판정 |
|---|---|---|
| 범위 밖 읽기 차단 | 종료 코드 0으로 `DUOFORGE_3A_OUTSIDE_SCOPE_SENTINEL`을 읽음 | 실패 |
| 파일 쓰기 차단 | 종료 코드 1, `Access to the path ... is denied`; 전후 SHA-256 동일 | 통과 |
| 자식 프로세스 차단 | 샌드박스 안의 PowerShell이 `cmd.exe`를 실행했고 종료 코드 0으로 `DUOFORGE_CHILD_OK` 출력 | 실패 |

쓰기 검증 뒤 SHA-256도 `FF362198959A58D2A99B4AD71E2A613C721CE60B50243245E9086ECF7A45D173`으로 동일하다. 따라서 테스트 픽스처 원본 변경은 없었다.

`--sandbox-state-readable-root`를 단독 지정한 사전 실험은 필수 인수 `--sandbox-state-json` 누락으로 종료 코드 2가 발생했으므로 접근 차단 증거에서 제외했다.

## 결정

현재 후보는 쓰기는 차단하지만 범위 밖 읽기와 자식 프로세스 생성을 차단하지 못한다. Codex 측 필수 계약이 이미 실패했으므로 같은 3A 실행 봉투를 사용하는 Claude 측 추가 격리 검증과 3A 구현은 진행하지 않는다.

- `features.dualProjectAudit`: 계속 `false`
- 진단: `readyForProjectAudit = false`
- 차단 코드: `DF-PREFLIGHT-3A-ISOLATION`
- CLI 메뉴: 3A 숨김 유지

향후 범위 제한 읽기, 전체 쓰기 거부, 자식 프로세스 생성 거부를 동시에 제공하는 격리 수단이 준비되면 두 공급자에 대해 동일 픽스처를 다시 실행하고, 네트워크 차단과 실행 전후 전체 원본 인벤토리 SHA-256까지 추가 검증한다.
