---
name: developer
description: TDD 스타일 개발 워크플로우 오케스트레이터. 코드베이스 분석 → 테스트 작성 → 코드 구현 → 로컬 검증 → PR 생성 → CI 검증. "개발 작업", "코드 구현", "PR 생성" 요청 시 사용
allowed-tools: Task, Bash(git:*), Bash(gh pr:*), Bash(gh auth:*), Bash(cd:*), Bash(echo $CLAUDE_SESSION_ID), Bash(ls:*), TodoWrite
---

# Developer Skill (TDD Workflow Orchestrator)

GitHub repository에서 TDD 스타일로 개발 작업을 수행하고 PR을 생성하는 오케스트레이터 스킬입니다.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        Developer Skill (Orchestrator)                    │
└───────────────────────────────────────────────────────────────────────────┘
                                    │
         ┌──────────────────────────┼──────────────────────────┐
         ▼                          ▼                          ▼
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│  codebase-      │     │   test-writer   │     │   code-writer   │
│   analyzer      │     │  (Red Phase)    │     │ (Green Phase)   │
└─────────────────┘     └─────────────────┘     └─────────────────┘
                                                        │
                                    ┌───────────────────┤
                                    ▼                   ▼
                        ┌─────────────────┐ ┌─────────────────┐
                        │ local-test-     │ │   ci-validator  │
                        │   validator     │ │                 │
                        └─────────────────┘ └────────┬────────┘
                                                     │
                                                     ▼
                                          ┌─────────────────┐
                                          │ linear-status-  │
                                          │    reporter     │
                                          │   (optional)    │
                                          └─────────────────┘
```

## Workflow

### Step 0: Session ID 확인

```bash
echo $CLAUDE_SESSION_ID
```

이 Session ID는 모든 결과에 포함됩니다.

### Step 1: Repository 준비

1. 작업 디렉토리 설정:
   ```bash
   cd /tmp && git clone {repository_url} {repo_name}
   cd /tmp/{repo_name}
   ```

2. 기본 브랜치 확인 및 작업 브랜치 생성:
   ```bash
   git checkout -b {branch_name}
   ```

### Step 2: codebase-analyzer 호출

**Task tool 사용**:
```
subagent_type: "codebase-analyzer"
prompt: "다음 repository의 코드베이스를 분석해주세요:
  Repository: /tmp/{repo_name}
  작업 설명: {task_description}
  관련 영역: {target_areas}"
```

**기대 출력**: 프로젝트 정보, 디렉토리 구조, 테스트 구조, 코드 패턴

### Step 3: test-writer 호출 (TDD Red Phase)

**Task tool 사용**:
```
subagent_type: "test-writer"
prompt: "다음 기능에 대한 테스트를 작성해주세요:
  Repository: /tmp/{repo_name}
  코드베이스 분석: {codebase_analysis}
  기능 요구사항: {feature_spec}
  완료 기준: {acceptance_criteria}"
```

**기대 출력**: 생성된 테스트 파일, 테스트 케이스 목록, GitHub Actions 변경사항

### Step 4: code-writer 호출 (TDD Green Phase)

**Task tool 사용**:
```
subagent_type: "code-writer"
prompt: "테스트를 통과시키는 구현 코드를 작성해주세요:
  Repository: /tmp/{repo_name}
  코드베이스 분석: {codebase_analysis}
  테스트 정보: {test_spec}
  구현 힌트: {implementation_hints}"
```

**기대 출력**: 생성/수정된 파일, 구현 요약

### Step 5: Commit 생성

```bash
cd /tmp/{repo_name}
git add -A
git commit -m "$(cat <<'EOF'
{커밋 메시지}

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

### Step 6: local-test-validator 호출

**Task tool 사용**:
```
subagent_type: "local-test-validator"
prompt: "로컬에서 테스트/린트/타입체크/빌드를 검증해주세요:
  Repository: /tmp/{repo_name}
  코드베이스 분석: {codebase_analysis}
  테스트 정보: {test_spec}"
```

**실패 시 처리**:
1. 실패 원인 분석
2. code-writer 재호출하여 수정
3. 새 commit 생성
4. local-test-validator 재호출
5. **최대 3회 재시도**

### Step 7: PR 생성

로컬 테스트 통과 후:

```bash
cd /tmp/{repo_name}
git push -u origin {branch_name}

gh pr create --title "{PR 제목}" --body "$(cat <<'EOF'
## Summary
{변경 사항 요약}

## Changes
{변경 파일 목록}

## Test Plan
{테스트 계획}

---
🤖 Generated with Claude Code
EOF
)"
```

### Step 8: ci-validator 호출

**Task tool 사용**:
```
subagent_type: "ci-validator"
prompt: "PR의 CI가 완료될 때까지 대기하고 결과를 확인해주세요:
  Repository: /tmp/{repo_name}
  PR 번호: {pr_number}
  최대 대기 시간: 30분"
```

**실패 시 처리**:
1. 실패 원인 분석
2. code-writer 재호출하여 수정
3. 새 commit 생성 및 push
4. ci-validator 재호출
5. **최대 2회 재시도**

### Step 9: Linear 상태 보고 (Optional)

Linear 컨텍스트가 제공된 경우, `linear-status-reporter` subagent를 호출하여 이슈를 업데이트합니다.

**Linear 컨텍스트 확인**:
- 입력에서 `issue_id`, `team_id`, `session_id`, `routing_decision`, `work_summary`가 제공되었는지 확인합니다
- 제공되지 않은 경우 이 단계를 건너뜁니다

**호출 방법**:
```
Task tool 사용:
subagent_type: "linear-status-reporter"
prompt: 다음 JSON 형식의 정보를 전달합니다
```

#### 성공 시 Input (status가 completed인 경우)

```json
{
  "issue_id": "{issue_id}",
  "team_id": "{team_id}",
  "session_id": "{session_id}",
  "status": "success",
  "routing_decision": {
    "selected_target": "developer",
    "confidence": "{routing_decision.confidence}",
    "reasoning": "{routing_decision.reasoning}"
  },
  "work_summary": {
    "task_type": "{work_summary.task_type}",
    "complexity": "{work_summary.complexity}",
    "estimated_scope": "{work_summary.estimated_scope}"
  },
  "work_result": {
    "executor": "developer",
    "summary": "{작업 요약}",
    "changes": ["{files_created}", "{files_modified}"],
    "pr_info": {
      "url": "{pr.url}",
      "branch": "{repository.branch}"
    },
    "verification": "테스트: {tests.passed}/{tests.total} 통과, CI: {pr.ci_status}"
  }
}
```

#### 블로킹 시 Input (status가 blocked/failed인 경우)

```json
{
  "issue_id": "{issue_id}",
  "team_id": "{team_id}",
  "session_id": "{session_id}",
  "status": "blocked",
  "routing_decision": {
    "selected_target": "developer",
    "confidence": "{routing_decision.confidence}",
    "reasoning": "{routing_decision.reasoning}"
  },
  "work_summary": {
    "task_type": "{work_summary.task_type}",
    "complexity": "{work_summary.complexity}",
    "estimated_scope": "{work_summary.estimated_scope}"
  },
  "blocking_info": {
    "stage": "{실패 단계: repository_setup | codebase_analysis | test_writing | code_writing | local_validation | pr_creation | ci_validation}",
    "reason": "{에러 메시지 또는 실패 사유}",
    "attempted_actions": ["{실패 전 시도한 작업들}"],
    "required_actions": ["{수정 제안 또는 다음 단계}"],
    "collected_info": "{부분 결과 또는 진단 정보}"
  }
}
```

### Step 10: 결과 반환

모든 작업 완료 후 JSON 형식으로 반환합니다.

## 출력 형식

```json
{
  "success": true,
  "status": "completed | partial | failed | blocked",
  "session_id": "CLAUDE_SESSION_ID",
  "summary": "작업 결과 한 줄 요약",
  "repository": {
    "url": "https://github.com/owner/repo",
    "branch": "feature/task-123",
    "base_branch": "main"
  },
  "workflow_stages": {
    "repository_setup": {
      "status": "completed | failed",
      "duration_ms": 5000
    },
    "codebase_analysis": {
      "status": "completed | failed | skipped",
      "duration_ms": 10000
    },
    "test_writing": {
      "status": "completed | failed | skipped",
      "files_created": ["tests/auth.test.ts"],
      "duration_ms": 15000
    },
    "code_writing": {
      "status": "completed | failed",
      "files_created": ["src/auth.ts"],
      "files_modified": ["src/index.ts"],
      "duration_ms": 20000
    },
    "local_validation": {
      "status": "passed | failed",
      "retries": 1,
      "test_passed": true,
      "lint_passed": true,
      "typecheck_passed": true,
      "build_passed": true,
      "duration_ms": 30000
    },
    "pr_creation": {
      "status": "completed | failed",
      "duration_ms": 3000
    },
    "ci_validation": {
      "status": "passed | failed | timeout",
      "retries": 0,
      "duration_ms": 180000
    }
  },
  "changes": {
    "files_created": ["src/auth.ts", "tests/auth.test.ts"],
    "files_modified": ["src/index.ts", ".github/workflows/test.yml"],
    "files_deleted": []
  },
  "tests": {
    "total": 5,
    "passed": 5,
    "failed": 0,
    "coverage": "85%"
  },
  "pr": {
    "created": true,
    "url": "https://github.com/owner/repo/pull/123",
    "number": 123,
    "title": "feat: Add authentication feature",
    "ci_status": "passed"
  },
  "linear_report": {
    "reported": true,
    "issue_id": "이슈 ID",
    "new_status": "Done",
    "comment_created": true
  },
  "error": null
}
```

### Status 정의

| Status | 설명 |
|--------|------|
| `completed` | 모든 작업 완료, PR 생성 성공, CI 통과 |
| `partial` | 일부 완료 (로컬 테스트 통과, PR 생성, CI 실패 등) |
| `failed` | 복구 불가능한 실패 발생 |
| `blocked` | 권한, 인증, 네트워크 등 외부 요인으로 진행 불가 |

## Error Handling

### 단계별 실패 처리

| 단계 | 실패 시 처리 | 최대 재시도 |
|------|------------|-----------|
| Repository 준비 | blocked 상태로 즉시 종료 | 0 |
| codebase-analyzer | 기본 분석으로 진행, 실패 시 blocked | 0 |
| test-writer | 재시도 후 partial | 1 |
| code-writer | 재시도 후 partial | 2 |
| local-test-validator | code-writer 재호출 | 3 |
| PR 생성 | 재시도 후 partial | 1 |
| ci-validator | code-writer 재호출 | 2 |

### Rollback 전략

모든 작업은 새 브랜치에서 진행되므로 main에 영향 없음.

필요 시:
```bash
# 로컬 브랜치 삭제
git checkout main && git branch -D {branch_name}

# 원격 브랜치 삭제
git push origin --delete {branch_name}

# PR 닫기
gh pr close {pr_number}
```

## Important Notes

1. **TDD 원칙 준수**: 테스트를 먼저 작성하고, 테스트 통과를 위한 최소 구현
2. **순차적 Subagent 호출**: Subagent는 다른 subagent를 호출할 수 없음
3. **컨텍스트 전달**: 각 단계의 출력을 다음 단계에 완전히 전달
4. **Session ID 포함**: 모든 결과에 Session ID 포함
5. **기존 패턴 존중**: 프로젝트의 기존 코드 스타일과 패턴 따르기
6. **새 브랜치 작업**: main/master에 직접 push 금지

## Quick Reference

| 단계 | Subagent | 입력 | 출력 |
|------|----------|------|------|
| 2 | codebase-analyzer | repository_path, task_description | 프로젝트 분석 JSON |
| 3 | test-writer | codebase_analysis, feature_spec | 테스트 파일, 케이스 목록 |
| 4 | code-writer | codebase_analysis, test_spec | 구현 파일 목록 |
| 6 | local-test-validator | repository_path, test_commands | 검증 결과 JSON |
| 8 | ci-validator | pr_number, max_wait | CI 결과 JSON |
| 9 | linear-status-reporter (optional) | work_result, linear_context | 상태 업데이트 확인 JSON |
