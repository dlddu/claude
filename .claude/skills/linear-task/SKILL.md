---
name: linear-task
description: Linear sub-task에 대한 작업을 수행하고 상태를 업데이트합니다. "태스크 작업", "sub-task 완료" 요청 시 사용
allowed-tools: mcp__linear-server__get_issue, mcp__linear-server__update_issue, mcp__linear-server__create_comment, Task, Bash(echo $CLAUDE_SESSION_ID)
---

# Linear Sub-task Execution

할당된 Linear sub-task에 대해 작업을 수행합니다. 라우터를 통해 적절한 서브에이전트로 작업을 위임하고, 최종 결과를 Linear에 업데이트합니다.

## Input

- Sub-task ID: $ARGUMENTS

## Instructions

### Step 1: Session ID 확인

먼저 Bash로 `echo $CLAUDE_SESSION_ID`를 실행하여 session ID를 확인합니다.

### Step 2: 라우팅 결정

Task 도구를 사용하여 `linear-task-router` 서브에이전트를 호출합니다:

```
Task(subagent_type: "linear-task-router", prompt: "다음 Linear sub-task를 분석하여 라우팅을 결정해주세요: {sub-task ID}")
```

라우터는 다음 형식으로 결과를 반환합니다:
```json
{
  "route": "coding" | "general",
  "reason": "라우팅 결정 사유",
  "task_summary": "sub-task 요약",
  "parent_context": "부모 이슈 컨텍스트"
}
```

### Step 3: 서브에이전트 호출

라우팅 결정에 따라 적절한 서브에이전트를 호출합니다:

#### coding으로 라우팅된 경우:
```
Task(subagent_type: "linear-task-coding", prompt: "다음 Linear sub-task의 코딩 작업을 수행해주세요: {sub-task ID}\n\n컨텍스트: {라우터가 제공한 컨텍스트}")
```

#### general로 라우팅된 경우:
```
Task(subagent_type: "linear-task-general", prompt: "다음 Linear sub-task의 작업을 수행해주세요: {sub-task ID}\n\n컨텍스트: {라우터가 제공한 컨텍스트}")
```

### Step 4: 상태 업데이트 및 코멘트 작성

서브에이전트의 작업 결과를 확인하고 Linear를 업데이트합니다.

#### 작업 성공 시

1. Linear MCP를 사용하여 sub-task 상태를 **Done**으로 변경합니다
2. `mcp__linear-server__create_comment`를 사용하여 완료 코멘트를 작성합니다

완료 코멘트 형식:

```markdown
## 작업 완료 보고

**Claude Session ID**: `{session_id}`

### 라우팅 정보
- 작업 유형: {coding/general}
- 라우팅 사유: {라우터의 결정 사유}

### 수행한 작업
- {작업 내용 1}
- {작업 내용 2}

### 변경된 파일
- `{파일 경로 1}`
- `{파일 경로 2}`

### 검증 결과
{테스트/검증 실행 결과 요약}
```

#### 작업 실패/블로킹 시

다음 상황에서는 sub-task 상태를 **Blocked**로 변경합니다:

- 외부 의존성이 해결되지 않은 경우
- 추가 정보나 결정이 필요한 경우
- 기술적 제약으로 진행이 불가능한 경우
- 다른 작업이 먼저 완료되어야 하는 경우
- 테스트 실패로 작업을 완료할 수 없는 경우

Blocked 상태로 변경 시 `mcp__linear-server__create_comment`를 사용하여 다음 형식으로 코멘트를 작성합니다:

```markdown
## 작업 블로킹 보고

**Claude Session ID**: `{session_id}`

### 라우팅 정보
- 작업 유형: {coding/general}
- 라우팅 사유: {라우터의 결정 사유}

### 블로킹 사유
{사유 설명}

### 해결을 위해 필요한 조치
- {필요한 조치 1}
- {필요한 조치 2}

### 관련 정보
- 관련 이슈: {있는 경우}
- 담당자: {알고 있는 경우}
```

## Workflow Summary

```
1. Session ID 확인
   ↓
2. linear-task-router 호출 → 라우팅 결정
   ↓
3. 결정에 따른 서브에이전트 호출
   ├─ coding → linear-task-coding
   └─ general → linear-task-general
   ↓
4. 결과에 따른 Linear 업데이트
   ├─ 성공 → Done + 완료 코멘트 (session ID 포함)
   └─ 실패 → Blocked + 사유 코멘트 (session ID 포함)
```

## Output Format

작업이 완료되면 다음을 출력합니다:

1. Sub-task 요약
2. 라우팅 결정 (coding/general 및 사유)
3. 수행한 작업 내용
4. 변경된 파일 목록
5. 최종 상태 (Done 또는 Blocked)
6. (Blocked인 경우) 블로킹 사유 및 해결 방안
