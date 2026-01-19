---
name: linear-task
description: Linear sub-task에 대한 작업을 수행하고 상태를 업데이트합니다. "태스크 작업", "sub-task 완료" 요청 시 사용
allowed-tools: mcp__linear-server__get_issue, mcp__linear-server__update_issue, mcp__linear-server__create_comment, Read, Write, Edit, Glob, Grep, Bash, Task, TodoWrite
---

# Linear Sub-task Execution

할당된 Linear sub-task에 대해 작업을 수행합니다.

## Instructions

### Step 1: Sub-task 분석

1. 사용자가 제공한 sub-task ID를 사용하여 Linear MCP로 정보를 가져옵니다
2. sub-task의 제목, 설명, 완료 기준을 확인합니다
3. 부모 이슈의 컨텍스트도 함께 확인합니다

### Step 2: 작업 계획 작성

sub-task를 완료하기 위한 세부 계획을 작성합니다:

1. 수정해야 할 파일 식별
2. 구현 방법 결정
3. 테스트 방법 결정
4. TodoWrite 도구를 사용하여 작업 추적

### Step 3: 작업 수행

계획에 따라 작업을 진행합니다:

1. 코드 변경 수행
2. 필요한 테스트 작성/수정
3. 린트 및 타입 체크 통과 확인
4. 변경사항 커밋

### Step 4: 상태 업데이트 및 코멘트 작성

먼저 Bash로 `echo $CLAUDE_SESSION_ID`를 실행하여 session ID를 확인합니다.

#### 작업 완료 시

1. Linear MCP를 사용하여 sub-task 상태를 **Done**으로 변경합니다
2. `mcp__linear-server__create_comment`를 사용하여 완료 코멘트를 작성합니다

완료 코멘트 형식:

```markdown
## 작업 완료 보고

**Claude Session ID**: `{session_id}`

### 수행한 작업
- {작업 내용 1}
- {작업 내용 2}

### 변경된 파일
- `{파일 경로 1}`
- `{파일 경로 2}`

### 테스트 결과
{테스트 실행 결과 요약}
```

#### 작업 완료 불가 시

다음 상황에서는 sub-task 상태를 **Blocked**로 변경합니다:

- 외부 의존성이 해결되지 않은 경우
- 추가 정보나 결정이 필요한 경우
- 기술적 제약으로 진행이 불가능한 경우
- 다른 작업이 먼저 완료되어야 하는 경우

Blocked 상태로 변경 시 `mcp__linear-server__create_comment`를 사용하여 다음 형식으로 코멘트를 작성합니다:

```markdown
## 작업 블로킹 보고

**Claude Session ID**: `{session_id}`

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
1. Sub-task 정보 조회
   ↓
2. 작업 계획 수립
   ↓
3. 코드 변경 및 테스트
   ↓
4. 결과에 따른 상태 변경
   ├─ 성공 → Done + 완료 코멘트
   └─ 실패 → Blocked + 사유 코멘트
```

## Output Format

작업이 완료되면 다음을 출력합니다:

1. Sub-task 요약
2. 수행한 작업 내용
3. 변경된 파일 목록
4. 최종 상태 (Done 또는 Blocked)
5. (Blocked인 경우) 블로킹 사유 및 해결 방안
