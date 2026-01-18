---
name: linear-task
description: Linear 이슈에 대한 작업을 수행합니다. Subagent들을 orchestration하여 리서치, 라우팅, 실행을 자동화합니다. "태스크 작업", "이슈 처리", "Linear 작업" 요청 시 사용
allowed-tools: mcp__linear-server__get_issue, Task, Skill, Bash, TodoWrite
---

# Linear Task Orchestration Skill

Linear 이슈를 처리하기 위해 여러 subagent를 orchestration하는 skill입니다.

## Architecture

```
┌─────────────────┐
│  linear-task    │ (이 Skill)
│   Orchestrator  │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ linear-task-    │ Step 1: 이슈 정보 및 배경지식 수집
│   researcher    │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  task-router    │ Step 2: 작업 유형 분석 및 에이전트 결정
└────────┬────────┘
         │
         ▼
┌─────────────────────────┐
│       developer         │ Step 3: 실제 작업 수행 + 결과 보고
│          OR             │
│ general-purpose-wrapper │
└─────────────────────────┘
```

## Workflow

### Step 0: Session ID 확인

먼저 환경 변수에서 Session ID를 확인합니다:

```bash
echo $CLAUDE_SESSION_ID
```

이 Session ID는 최종 코멘트에 포함됩니다.

### Step 1: Researcher Subagent 호출

`linear-task-researcher` subagent를 Task tool로 호출합니다.

**호출 방법**:
```
Task tool 사용:
- subagent_type: "linear-task-researcher"
- prompt: "Linear 이슈 {issue_id}에 대한 정보를 수집하고 작업에 필요한 배경지식을 조사해주세요."
```

**기대 출력**: JSON 형식의 이슈 정보, repository 정보, 기술적 컨텍스트

### Step 2: Router Subagent 호출

researcher의 결과를 `task-router` subagent에 전달합니다.

**호출 방법**:
```
Task tool 사용:
- subagent_type: "task-router"
- prompt: "다음 작업 정보를 분석하여 적절한 실행 에이전트를 결정해주세요: {researcher_output}"
```

**기대 출력**: JSON 형식의 라우팅 결정 및 작업 지시사항

### Step 3: 실행 에이전트 호출

router의 결정에 따라 적절한 에이전트를 호출합니다.

**developer 선택 시** (Skill tool 사용):
```
Skill tool 사용:
- skill: "developer"
- args: "Repository: {repository_url}
  작업 내용: {agent_instructions}
  완료 기준: {success_criteria}

  [Linear Context]
  issue_id: {issue_id}
  team_id: {team_id}
  session_id: {session_id}
  routing_decision: {routing_decision JSON}
  work_summary: {work_summary JSON}"
```

developer skill은 TDD 스타일 워크플로우를 수행합니다:
1. codebase-analyzer로 코드베이스 분석
2. test-writer로 테스트 작성 (Red Phase)
3. code-writer로 구현 (Green Phase)
4. local-test-validator로 로컬 검증
5. PR 생성
6. ci-validator로 CI 검증
7. linear-status-reporter로 결과 보고

**general-purpose-wrapper 선택 시** (Skill tool 사용):
```
Skill tool 사용:
- skill: "general-purpose-wrapper"
- args: "작업 내용: {agent_instructions}
  완료 기준: {success_criteria}

  [Linear Context]
  issue_id: {issue_id}
  team_id: {team_id}
  session_id: {session_id}
  routing_decision: {routing_decision JSON}
  work_summary: {work_summary JSON}"
```

general-purpose-wrapper는:
1. general-purpose subagent로 실제 작업 수행
2. linear-status-reporter로 결과 보고

## Error Handling

### Researcher 실패 시
- Linear API 접근 문제인지 확인
- 이슈 ID가 올바른지 확인
- 실패 사유와 함께 Blocked 상태로 전환

### Router 실패 시
- researcher 출력 형식 확인
- 기본값으로 developer 선택 후 진행
- 불확실성을 코멘트에 명시

### Executor 실패 시
- 실패 원인 분석
- 부분 완료된 작업 정리
- 상세한 실패 보고서 작성

## Important Notes

1. **Subagent 순차 호출**: 각 subagent는 순차적으로 호출해야 합니다 (subagent는 다른 subagent를 호출할 수 없음)

2. **컨텍스트 전달**: 각 단계의 출력을 다음 단계에 완전히 전달해야 합니다

3. **Session ID 필수**: 모든 코멘트에 Session ID를 반드시 포함합니다

4. **상태 관리**: 작업 시작 시 In Progress, 완료 시 Done 또는 Blocked로 변경

5. **에러 복구**: 가능한 경우 에러 복구를 시도하고, 불가능한 경우 명확한 보고

## Quick Reference

| 단계 | Agent/Skill | 입력 | 출력 |
|------|-------------|------|------|
| 1 | linear-task-researcher (subagent) | issue_id | JSON (이슈 정보, 컨텍스트) |
| 2 | task-router (subagent) | researcher 출력 | JSON (라우팅 결정, 지시사항) |
| 3 | developer (skill) / general-purpose-wrapper (skill) | router 지시사항 + Linear Context | 작업 완료 보고 + Linear 상태 업데이트 |

**Note**:
- developer는 skill로 호출되며, 내부적으로 TDD 워크플로우를 수행합니다 (codebase-analyzer → test-writer → code-writer → local-test-validator → PR → ci-validator → linear-status-reporter)
- general-purpose-wrapper는 skill로 호출되며, general-purpose 작업 후 linear-status-reporter를 호출합니다
- 각 executor가 Linear Context를 받아 직접 linear-status-reporter를 호출하여 결과를 보고합니다
