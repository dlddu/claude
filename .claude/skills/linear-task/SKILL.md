---
name: linear-task
description: Linear 이슈에 대한 작업을 수행합니다. Subagent들을 orchestration하여 리서치, 라우팅, 실행을 자동화합니다. "태스크 작업", "이슈 처리", "Linear 작업" 요청 시 사용
allowed-tools: mcp__linear-server__get_issue, mcp__linear-server__update_issue, mcp__linear-server__create_comment, Task, Bash, TodoWrite
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
┌─────────────────┐
│   developer     │ Step 3: 실제 작업 수행
│      OR         │
│ general-purpose │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ Linear Comment  │ Step 4: 결과 보고
└─────────────────┘
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

### Step 3: 실행 Subagent 호출

router의 결정에 따라 적절한 subagent를 호출합니다.

**developer 선택 시**:
```
Task tool 사용:
- subagent_type: "developer"
- prompt: "다음 작업을 수행해주세요:
  Repository: {repository_url}
  작업 내용: {agent_instructions}
  완료 기준: {success_criteria}"
```

**general-purpose 선택 시**:
```
Task tool 사용:
- subagent_type: "general-purpose"
- prompt: "다음 작업을 수행해주세요:
  작업 내용: {agent_instructions}
  완료 기준: {success_criteria}"
```

### Step 4: Linear 상태 업데이트 및 코멘트 작성

작업 결과에 따라 Linear 이슈를 업데이트합니다.

#### 작업 성공 시

1. 이슈 상태를 **Done**으로 변경:
   ```
   mcp__linear-server__update_issue 사용
   stateId: Done 상태의 ID
   ```

2. 완료 코멘트 작성 (`mcp__linear-server__create_comment` 사용):

```markdown
## 작업 완료 보고

**Claude Session ID**: `{session_id}`
**Routing Decision**: `{selected_agent}` (confidence: {confidence})

### 이슈 분석 결과
- **작업 유형**: {task_type}
- **복잡도**: {complexity}
- **범위**: {estimated_scope}

### 수행한 작업
{executor_subagent의 작업 보고 내용}

### 변경 사항
- {변경 내용 1}
- {변경 내용 2}

### PR 정보 (developer 사용 시)
- PR URL: {pr_url}
- Branch: {branch_name}

### 검증 결과
{테스트/빌드 결과}
```

#### 작업 실패/블로킹 시

1. 이슈 상태를 **Blocked**로 변경

2. 블로킹 코멘트 작성:

```markdown
## 작업 블로킹 보고

**Claude Session ID**: `{session_id}`
**Routing Decision**: `{selected_agent}` (confidence: {confidence})

### 블로킹 단계
{researcher | router | developer | general-purpose} 단계에서 블로킹

### 블로킹 사유
{상세 사유}

### 시도한 작업
- {시도 1}
- {시도 2}

### 해결을 위해 필요한 조치
- {조치 1}
- {조치 2}

### 수집된 정보
{researcher가 수집한 정보 요약}
```

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

| 단계 | Subagent | 입력 | 출력 |
|------|----------|------|------|
| 1 | linear-task-researcher | issue_id | JSON (이슈 정보, 컨텍스트) |
| 2 | task-router | researcher 출력 | JSON (라우팅 결정, 지시사항) |
| 3 | developer / general-purpose | router 지시사항 | 작업 완료 보고 |
| 4 | (이 skill) | 전체 결과 | Linear 코멘트 |
