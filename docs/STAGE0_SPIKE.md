# 단계 0 기술 검증 기록

검증일: 2026-07-27  
환경: Windows, PowerShell 7.6.3

## 검증 범위

설치된 CLI의 버전, 도움말에 노출된 기능, 구독 로그인 상태 명령과 API 자격증명 우선 조건을 확인했다. 사용자 승인 후 공급자별 1회 실제 모델 호출도 수행해 구조화 출력과 런타임 안전 경계를 검증했다.

## Codex

- 확인 버전: `codex-cli 0.145.0`
- 구독 인증: `codex login status` 종료 코드와 `Logged in using ChatGPT`만 정규화
- 확인 기능: `--model`, `--ask-for-approval`, `--config`, `--sandbox`, `--skip-git-repo-check`, `--ephemeral`, `--ignore-user-config`, `--ignore-rules`, `--output-schema`, `--json`, `--output-last-message`
- 판단: 문서 모드용 격리 작업 폴더·읽기 전용·구조화 출력의 구현 기준선은 충족
- 모델 메뉴: CLI `app-server model/list`의 계정별 가시 모델, `isDefault`, 모델별 기본·지원 추론 정도를 프로세스마다 조회한다. 현재 결과는 가시 모델 7개, `gpt-5.6-sol` 기본, `high` 지원으로 권장 표시되며 조회 실패 시 로컬 캐시와 제한된 내장 목록으로 폴백한다.
- 차단 사항: Windows `read-only` 격리 스파이크에서 쓰기는 거부됐지만 범위 밖 읽기와 자식 프로세스 실행이 허용되어 3A의 선제 차단 계약을 충족하지 못함

## Claude Code

- 확인 버전: `2.1.220 (Claude Code)`
- 구독 인증: `claude auth status`의 원문을 보존하지 않고 `loggedIn`, `authMethod`, `apiProvider`, `subscriptionType`만 정규화
- 확인 기능: `--model`, `--effort`, `--safe-mode`, `--strict-mcp-config`, 빈 `--tools`, `--disallowedTools`, `--no-chrome`, `--no-session-persistence`, `--permission-mode`, `--output-format`, `--json-schema`
- 설치된 2.1.220 도움말에는 온라인 CLI 문서의 `--max-turns`가 노출되지 않아 해당 플래그에 의존하지 않고 `-p` 단일 출력 호출을 사용한다.
- 판단: 문서 모드와 무도구 호출 프로필의 구현 기준선은 충족
- 모델 메뉴: 설치된 `claude --help`에서 최신 계열 별칭과 effort를 프로세스마다 다시 읽고 `default`를 함께 제공한다. 현재는 `opus|sonnet|fable|default`와 `low|medium|high|xhigh|max`를 표시하며 `opus + high`가 실제 목록에 있을 때만 권장한다. Claude CLI에는 계정별 `/model` 전체 행을 내보내는 기계 판독 명령이 없어 별칭이 실제 버전을 런타임에 해석한다.

## 인증 안전

- `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`과 공급자 우회 변수가 프로세스 환경에 존재하면 변수 이름만 표시하고 실패 폐쇄한다.
- 환경 변수 값, 이메일, 조직 ID, 토큰과 공급자 인증 파일은 상태·로그·매니페스트에 저장하지 않는다.
- 환경 변수 삭제나 공급자 로그아웃은 자동 수행하지 않는다.

## 결론

- `shared-document`, `dual-document`: 공통 기반 구현을 진행할 수 있음
- `dual-project-audit`: `DF-PREFLIGHT-3A-ISOLATION`으로 차단
- 공급자별 라이브 스모크: `run-20260727-142342-87cca1`에서 Codex `gpt-5.6-sol/high`, Claude `opus/high`를 각 1회 호출해 구조화 `independent-draft` 성공
- 라이브 안전 결과: 실제 이벤트 스트림의 금지 도구 이벤트 0건, 공급자 임시 작업 파일 0개, 호출 후 두 구독 인증 유지
- 라이브 과정에서 수정한 결함: PowerShell 래퍼의 종료 코드 손실, 승인 환경의 `Path` 누락, Codex 엄격 JSON Schema의 상수 타입 누락
- 전체 단계 E2E: `run-20260727-142702-0eeb82`에서 2라운드 13/13 단계 커밋, 라운드 장벽·상호 비평·응답·교대 합성·최종 검증과 최종 파일 5개 생성 확인
- 전체 단계 안전 결과: 원본 SHA-256 동일, 공급자 임시 파일 0개, 저장 파일의 비밀 패턴 0건, 호출 후 두 구독 인증 유지
- E2E 과정에서 수정한 추가 결함: 비밀 제거 결과의 빈·단일·다중 배열이 두 번째 PowerShell 정규화에서 붕괴하던 문제
- 독립 문서 전체 단계 E2E: `run-20260727-155148-7617d3`에서 Codex `gpt-5.6-sol/high`, Claude `opus/high`로 2라운드 12/12 단계와 최종 파일 6개 생성 후 사용자 결정 8건을 반영해 `COMPLETED`
- 독립 문서 안전 결과: 양쪽 원본 SHA-256 동일, 금지 도구 이벤트 0건, 공급자 작업 파일 0개, 미해결 질문 0개, 호출 후 두 구독 인증 유지
- 독립 문서 누적 모델 실행 시간: 형식 계약 복구와 결정 반영 재실행을 포함해 2,121.408초로 90분 상한 이내
- 독립 문서 E2E에서 수정한 결함: Codex 엄격 스키마의 선택 속성 거부, 여러 사용자 답변의 최신값 집계, 반복 무효화 감사 이력 배열, 이미 답한 과거 질문의 최종 병합 재등장
- 결정 반영 검증: 두 최신 공급자 결과가 결정 8건의 반영을 명시했고, 최종 렌더러가 결정 원장을 적용해 과거 질문을 확정 처리한 뒤 모델 재호출 없이 `AWAITING_USER`에서 `COMPLETED`로 전환
- 3A OS 격리 스파이크: 범위 밖 표식 읽기와 중첩 `cmd.exe` 실행은 종료 코드 0으로 성공했고, 쓰기만 접근 거부와 전후 SHA-256 동일을 확인해 3A 게이트를 계속 닫음
- 3A 상세 근거: [3A_ISOLATION_SPIKE.md](3A_ISOLATION_SPIKE.md)

## 공식 기준

- [OpenAI Codex CLI 명령 참조](https://developers.openai.com/codex/cli/reference)
- [Claude Code 인증](https://code.claude.com/docs/en/authentication)
- [Claude Code CLI 참조](https://code.claude.com/docs/en/cli-usage)
- [Claude Code API 키 환경 변수 우선순위](https://support.claude.com/en/articles/12304248-manage-api-key-environment-variables-in-claude-code)
