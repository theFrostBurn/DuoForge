# 단계 0 기술 검증 기록

검증일: 2026-07-27  
환경: Windows, PowerShell 7.6.3

## 검증 범위

이번 검증은 설치된 CLI의 버전, 도움말에 노출된 기능, 구독 로그인 상태 명령과 API 자격증명 우선 조건만 확인했다. 실제 Codex·Claude 모델 호출은 구독 사용량을 소비할 수 있으므로 실행하지 않았다.

## Codex

- 확인 버전: `codex-cli 0.145.0`
- 구독 인증: `codex login status` 종료 코드와 `Logged in using ChatGPT`만 정규화
- 확인 기능: `--ask-for-approval`, `--config`, `--sandbox`, `--skip-git-repo-check`, `--ephemeral`, `--ignore-user-config`, `--ignore-rules`, `--output-schema`, `--json`, `--output-last-message`
- 판단: 문서 모드용 격리 작업 폴더·읽기 전용·구조화 출력의 구현 기준선은 충족
- 차단 사항: `read-only`는 모델의 명령 도구 표면 자체를 없애지 않으므로 3A의 선제적 무도구 조건은 충족하지 못함

## Claude Code

- 확인 버전: `2.1.220 (Claude Code)`
- 구독 인증: `claude auth status`의 원문을 보존하지 않고 `loggedIn`, `authMethod`, `apiProvider`, `subscriptionType`만 정규화
- 확인 기능: `--safe-mode`, `--strict-mcp-config`, 빈 `--tools`, `--disallowedTools`, `--no-chrome`, `--no-session-persistence`, `--permission-mode`, `--output-format`, `--json-schema`
- 설치된 2.1.220 도움말에는 온라인 CLI 문서의 `--max-turns`가 노출되지 않아 해당 플래그에 의존하지 않고 `-p` 단일 출력 호출을 사용한다.
- 판단: 문서 모드와 무도구 호출 프로필의 구현 기준선은 충족

## 인증 안전

- `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`과 공급자 우회 변수가 프로세스 환경에 존재하면 변수 이름만 표시하고 실패 폐쇄한다.
- 환경 변수 값, 이메일, 조직 ID, 토큰과 공급자 인증 파일은 상태·로그·매니페스트에 저장하지 않는다.
- 환경 변수 삭제나 공급자 로그아웃은 자동 수행하지 않는다.

## 결론

- `shared-document`, `dual-document`: 공통 기반 구현을 진행할 수 있음
- `dual-project-audit`: `DF-PREFLIGHT-3A-ISOLATION`으로 차단
- 실제 공급자 E2E: 별도 사용자 동의 후 실행
- 라이브 E2E 전 잔여 조건: 실제 이벤트 스트림에서 금지 도구 이벤트 0건, 구조화 출력 성공, 원문 결과 파일 정리와 구독 인증 유지 확인

## 공식 기준

- [OpenAI Codex CLI 명령 참조](https://developers.openai.com/codex/cli/reference)
- [Claude Code 인증](https://code.claude.com/docs/en/authentication)
- [Claude Code CLI 참조](https://code.claude.com/docs/en/cli-usage)
- [Claude Code API 키 환경 변수 우선순위](https://support.claude.com/en/articles/12304248-manage-api-key-environment-variables-in-claude-code)
