---
name: linear-task
description: Linear 이슈에 대한 작업을 수행하고 상태를 업데이트합니다. "태스크 작업", "이슈 처리" 요청 시 사용
allowed-tools: mcp__linear-server__get_issue, mcp__linear-server__update_issue, mcp__linear-server__create_comment, mcp__linear-server__list_comments, mcp__linear-server__get_project, Read, Write, Edit, Glob, Grep, Bash, Task, TodoWrite
---

# Linear Task Execution

Linear 이슈에 대해 조사, 라우팅, 작업 수행의 전체 파이프라인을 실행합니다.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                      Linear Task Skill                          │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                 Step 1: Researcher Subagent                     │
│  - Linear 이슈 정보 수집                                         │
│  - 부모 이슈, 관련 이슈 조회                                      │
│  - GitHub 저장소 정보 수집                                        │
│  - 배경지식 및 컨텍스트 수집                                      │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                 Step 2: Router Subagent                         │
│  - Researcher 결과 분석                                          │
│  - 작업 유형 분류 (개발 vs 일반)                                  │
│  - 적절한 Worker 선택                                            │
│  - Work Order 생성                                               │
└─────────────────────────────────────────────────────────────────┘
                              │
                    ┌─────────┴─────────┐
                    ▼                   ▼
┌───────────────────────┐   ┌───────────────────────┐
│  Developer Subagent   │   │ General Worker        │
│  - Repo clone         │   │ - Research            │
│  - 코드 작업          │   │ - Documentation       │
│  - PR 생성            │   │ - Analysis            │
│  - 결과 반환          │   │ - 결과 반환           │
└───────────────────────┘   └───────────────────────┘
                    │                   │
                    └─────────┬─────────┘
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                 Step 4: Result & Comment                        │
│  - 이슈 상태 업데이트                                            │
│  - Session ID 포함 완료 코멘트 작성                              │
└─────────────────────────────────────────────────────────────────┘
```

## Instructions

### Step 0: Session ID 확인

```bash
echo $CLAUDE_SESSION_ID
```

Session ID를 기록해둡니다.

### Step 1: Researcher Subagent 실행

Task 도구를 사용하여 researcher subagent를 실행합니다.

**Subagent 프롬프트:**

```
Linear 이슈 정보를 수집하고 분석합니다.

Issue ID: {issue_id}

다음 작업을 수행하세요:

1. Linear MCP로 이슈 정보 조회 (mcp__linear-server__get_issue, includeRelations: true)
2. 부모 이슈가 있으면 부모 이슈 정보도 조회
3. 이슈 코멘트 조회 (mcp__linear-server__list_comments)
4. 이슈 설명과 첨부파일에서 GitHub 저장소 URL 추출
5. 완료 기준(acceptance criteria) 추출

결과를 다음 JSON 형식으로 반환:
{
  "issue": { id, identifier, title, description, state, priority, labels, assignee, branchName },
  "parent_issue": { id, title, description } | null,
  "repository": { url, related_files } | null,
  "context": { comments_summary, blocking_issues, related_issues, technical_notes },
  "acceptance_criteria": [],
  "constraints": []
}
```

**사용 도구:** Task (subagent_type: general-purpose)

### Step 2: Router Subagent 실행

Researcher의 결과를 기반으로 router subagent를 실행합니다.

**Subagent 프롬프트:**

```
작업 유형을 분류하고 적절한 worker를 선택합니다.

Research Result:
{researcher_result}

다음 기준으로 라우팅을 결정하세요:

Developer 선택 조건:
- GitHub 저장소 URL이 존재
- 코드 수정/추가/삭제 키워드 (구현, 수정, 버그, fix, implement, add)
- PR/커밋이 결과물로 예상됨

General Worker 선택 조건:
- 저장소 정보 없음
- 조사/분석/문서 키워드 (조사, 분석, 문서, research, analyze, document)
- 보고서/문서가 결과물로 예상됨

결과를 다음 JSON 형식으로 반환:
{
  "routing_decision": {
    "worker_type": "developer" | "general-worker",
    "confidence": "high" | "medium" | "low",
    "reasoning": "라우팅 결정 사유"
  },
  "work_order": {
    // developer인 경우: repository_url, task_title, task_description, acceptance_criteria, context
    // general-worker인 경우: task_title, task_description, task_type, acceptance_criteria, context
  }
}
```

**사용 도구:** Task (subagent_type: general-purpose)

### Step 3: Worker Subagent 실행

Router의 결정에 따라 적절한 worker subagent를 실행합니다.

#### Developer 실행 시

```
GitHub 저장소에서 개발 작업을 수행합니다.

Repository: {repository_url}
Task: {task_title}
Description: {task_description}
Acceptance Criteria: {acceptance_criteria}
Context: {context}

다음 작업을 수행하세요:

1. /tmp/workspace에 저장소 clone
2. feature 브랜치 생성
3. 코드 변경 수행
4. 테스트 실행 (가능한 경우)
5. 변경사항 커밋
6. 원격 저장소로 push
7. gh CLI로 PR 생성

결과를 다음 JSON 형식으로 반환:
{
  "status": "success" | "failed",
  "branch_name": "브랜치 이름",
  "pr_url": "PR URL",
  "commits": [{ hash, message }],
  "changed_files": ["파일 경로"],
  "summary": "작업 요약",
  "error": "에러 메시지 (실패 시)"
}
```

#### General Worker 실행 시

```
일반 작업을 수행합니다.

Task: {task_title}
Type: {task_type}
Description: {task_description}
Acceptance Criteria: {acceptance_criteria}
Context: {context}

다음 작업을 수행하세요:

1. 작업 유형에 맞는 정보 수집
2. 요구사항에 따른 작업 수행
3. 결과물 정리

결과를 다음 JSON 형식으로 반환:
{
  "status": "success" | "partial" | "failed",
  "task_type": "작업 유형",
  "deliverables": [{ type, title, content }],
  "summary": "작업 요약",
  "recommendations": ["권장사항"],
  "blockers": ["블로커"],
  "error": "에러 메시지 (실패 시)"
}
```

**사용 도구:** Task (subagent_type: general-purpose)

### Step 4: 결과 처리 및 코멘트 작성

#### 4.1 이슈 상태 업데이트

Worker 결과에 따라 이슈 상태를 업데이트합니다:

- **성공**: 상태를 `Done`으로 변경
- **부분 완료**: 상태 유지, 코멘트에 진행 상황 기록
- **실패/블로킹**: 상태를 `Blocked`로 변경

```
mcp__linear-server__update_issue({
  id: "{issue_id}",
  state: "Done" | "Blocked"
})
```

#### 4.2 완료 코멘트 작성

`mcp__linear-server__create_comment`를 사용하여 결과 코멘트를 작성합니다.

**성공 시 코멘트 형식:**

```markdown
## 작업 완료 보고

**Claude Session ID**: `{session_id}`

### 작업 유형
{Developer | General Worker}

### 수행한 작업
{worker_result.summary}

### 결과물
{Developer인 경우}
- **Branch**: `{branch_name}`
- **PR**: {pr_url}
- **변경 파일**: {changed_files}

{General Worker인 경우}
- **유형**: {task_type}
- **산출물**: {deliverables 요약}

### 권장 후속 조치
{있는 경우 기재}
```

**실패/블로킹 시 코멘트 형식:**

```markdown
## 작업 블로킹 보고

**Claude Session ID**: `{session_id}`

### 블로킹 사유
{error 또는 blockers}

### 시도한 작업
{수행 시도한 내용}

### 해결을 위해 필요한 조치
{권장 조치 사항}
```

## Error Handling

각 단계에서 에러 발생 시:

1. **Researcher 실패**: 이슈 정보를 가져올 수 없음 → 에러 코멘트 작성 후 종료
2. **Router 실패**: 작업 유형 판단 불가 → 수동 검토 요청 코멘트 작성
3. **Worker 실패**: 작업 수행 실패 → Blocked 상태로 변경, 상세 에러 코멘트 작성

## Output

스킬 실행 완료 후 다음 정보를 출력합니다:

1. 이슈 요약 (ID, 제목)
2. 실행된 파이프라인 요약
3. 최종 상태 (Done/Blocked)
4. 주요 결과물 (PR URL 또는 산출물 요약)
