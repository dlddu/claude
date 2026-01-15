---
name: linear-task
description: Linear 이슈 작업을 수행합니다. 이슈 분석, 라우팅, 작업 수행, 결과 보고까지 전체 워크플로우를 관리합니다. "태스크 작업", "이슈 처리" 요청 시 사용
allowed-tools: Task, Bash, mcp__linear-server__get_issue, mcp__linear-server__update_issue, mcp__linear-server__create_comment
---

# Linear Task Execution Skill

Linear 이슈에 대한 작업을 수행하고 결과를 보고하는 통합 워크플로우입니다.

## Overview

이 skill은 다음 subagent들을 순차적으로 호출하여 작업을 수행합니다:

1. **linear-task-researcher**: 이슈 정보 및 배경지식 수집
2. **task-router**: 작업 유형 판별 및 라우팅 결정
3. **developer** 또는 **general-worker**: 실제 작업 수행

## Workflow

### Phase 1: 정보 수집 (linear-task-researcher)

Task 도구를 사용하여 `linear-task-researcher` subagent를 호출합니다:

```
Task 도구 호출:
- subagent_type: linear-task-researcher
- prompt: "Linear 이슈 {issue_id}에 대한 정보를 수집해주세요. 이슈 상세, 관련 컨텍스트, repository 정보, 배경지식을 포함해주세요."
```

researcher가 반환하는 정보:
- 이슈 상세 정보 (제목, 설명, 상태, 우선순위)
- 부모/관련 이슈 정보
- 코멘트 요약
- Repository URL 및 관련 파일
- 작업 요구사항 및 완료 기준

### Phase 2: 라우팅 결정 (task-router)

researcher의 결과를 `task-router` subagent에게 전달합니다:

```
Task 도구 호출:
- subagent_type: task-router
- prompt: "다음 작업 정보를 분석하여 적절한 subagent(developer 또는 general-worker)를 결정해주세요:

  {researcher_result를 여기에 포함}"
```

router가 반환하는 정보:
- routing_decision: "developer" 또는 "general-worker"
- reasoning: 라우팅 결정 이유
- task_summary: 작업 요약
- context_for_agent: 에이전트에게 전달할 컨텍스트

### Phase 3: 작업 수행

router의 결정에 따라 적절한 subagent를 호출합니다:

#### developer로 라우팅된 경우:

```
Task 도구 호출:
- subagent_type: developer
- prompt: "다음 Linear 이슈 작업을 수행해주세요:

  이슈: {issue_identifier} - {issue_title}
  Repository: {repository_url}

  작업 내용:
  {task_requirements}

  완료 기준:
  {acceptance_criteria}

  작업 완료 후 PR을 생성하고 결과를 반환해주세요."
```

#### general-worker로 라우팅된 경우:

```
Task 도구 호출:
- subagent_type: general-worker
- prompt: "다음 Linear 이슈 작업을 수행해주세요:

  이슈: {issue_identifier} - {issue_title}

  작업 내용:
  {task_requirements}

  완료 기준:
  {acceptance_criteria}

  작업 완료 후 결과를 반환해주세요."
```

### Phase 4: 결과 보고

#### Session ID 확인

먼저 Bash로 session ID를 확인합니다:
```bash
echo $CLAUDE_SESSION_ID
```

#### 작업 완료 시

1. Linear MCP로 이슈 상태를 **Done**으로 변경:
   ```
   mcp__linear-server__update_issue:
   - id: {issue_id}
   - state: "Done"
   ```

2. 완료 코멘트 작성:
   ```
   mcp__linear-server__create_comment:
   - issueId: {issue_id}
   - body: (아래 형식)
   ```

완료 코멘트 형식:
```markdown
## 작업 완료 보고

**Claude Session ID**: `{session_id}`

### 라우팅 결정
- 작업 유형: {developer|general-worker}
- 결정 이유: {routing_reasoning}

### 수행한 작업
- {작업 내용 1}
- {작업 내용 2}

### 결과물
{developer인 경우}
- PR URL: {pr_url}
- 변경된 파일:
  - `{파일 1}`
  - `{파일 2}`

{general-worker인 경우}
- {결과물 요약}

### 테스트/검증 결과
{테스트 결과 또는 검증 내용}
```

#### 작업 블로킹 시

다음 상황에서는 상태를 **Blocked**로 변경합니다:
- 외부 의존성 미해결
- 추가 정보/결정 필요
- 기술적 제약
- Repository 접근 불가

Blocked 코멘트 형식:
```markdown
## 작업 블로킹 보고

**Claude Session ID**: `{session_id}`

### 진행 상황
- 라우팅 결정: {developer|general-worker}
- 도달 단계: {researcher|router|worker}

### 블로킹 사유
{상세 사유}

### 해결을 위해 필요한 조치
- {조치 1}
- {조치 2}

### 수집된 정보 요약
{researcher가 수집한 주요 정보}
```

## Error Handling

### Subagent 실패 시

1. 실패한 단계와 에러 내용을 기록
2. 가능하면 재시도 (최대 2회)
3. 재시도 실패 시 Blocked 상태로 변경 및 보고

### Repository 미발견 시

1. researcher가 repository URL을 찾지 못한 경우
2. 이슈 설명에서 추가 정보 요청 코멘트 작성
3. Blocked 상태로 변경

### 라우팅 불확실 시

1. router의 confidence가 "low"인 경우
2. 추가 정보 요청 코멘트 작성
3. 명확해질 때까지 Blocked 상태 유지

## Output Format

skill 실행 완료 후 사용자에게 다음을 출력합니다:

```
## Linear 이슈 작업 완료

**이슈**: {identifier} - {title}
**상태**: {Done|Blocked}

### 워크플로우 실행 결과
1. 정보 수집: {성공|실패}
2. 라우팅: {developer|general-worker} ({confidence})
3. 작업 수행: {성공|실패|블로킹}

### 최종 결과
{결과 요약}

### Linear 코멘트
{작성된 코멘트 요약}
```

## Important Notes

1. **순차 실행**: 각 phase는 이전 phase 완료 후 진행
2. **컨텍스트 전달**: 각 subagent에게 필요한 정보를 명확히 전달
3. **상태 추적**: 모든 단계의 결과를 추적하여 최종 보고에 반영
4. **Session ID 필수**: 모든 코멘트에 session ID 포함
