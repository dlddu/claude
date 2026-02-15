# Mac Developer Workflow (TDD - No Local Test)

GitHub repository에서 TDD 스타일로 개발 작업을 수행하는 워크플로우입니다.
Developer 워크플로우와 동일하지만, 로컬 테스트 검증(local-test-validator) 단계를 제외합니다.
CI를 통해서만 테스트/린트/타입체크/빌드를 검증합니다.

## Configuration

| 설정 | 값 | 설명 |
|------|-----|------|
| `AUTO_MERGE_THRESHOLD` | 90 | PR 리뷰 점수가 이 값 이상이면 자동 머지 |

## Architecture

```
Mac Developer Workflow (No Local Test)
       │
       ├─ Step 1: Repository 준비
       │
       ├─ Step 2: codebase-analyzer
       │
       ├─ Step 3: test-writer (Red Phase)
       │
       ├─ Step 4: code-writer (Green Phase)
       │
       ├─ Step 5: Commit 생성
       │
       ├─ Step 6: PR 생성
       │
       ├─ Step 7: ci-validator (최대 2회 재시도)
       │
       ├─ Step 8: pr-reviewer (PR 리뷰)
       │
       └─ Step 9: 점수 기반 자동 처리 (≥AUTO_MERGE_THRESHOLD: 머지)
```

## Input Requirements

이 워크플로우는 다음 정보가 필요합니다:
- `repository_url`: GitHub repository URL
- `agent_instructions`: 작업 지시사항
- `success_criteria`: 완료 기준

## Workflow Steps

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

### Step 6: PR 생성

Commit 생성 후 바로 PR을 생성합니다 (로컬 테스트 생략):

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

## Session Info
**Claude Session ID**: `{session_id}`

---
Generated with Claude Code
EOF
)"
```

### Step 7: ci-validator 호출

**Task tool 사용**:
```
subagent_type: "ci-validator"
prompt: "브랜치의 CI가 완료될 때까지 대기하고 결과를 확인해주세요:
  Repository: /tmp/{repo_name}
  브랜치: {branch_name}"
```

**실패 시 처리 (최대 2회 재시도)**:
1. 실패 원인 분석
2. code-writer 재호출하여 수정
3. 새 commit 생성 및 push
4. ci-validator 재호출

### Step 8: pr-reviewer 호출 (PR 리뷰)

CI 검증 통과 후 PR 리뷰를 수행합니다.

**Task tool 사용**:
```
subagent_type: "pr-reviewer"
prompt: "다음 PR에 대한 리뷰를 수행해주세요:
  Repository: /tmp/{repo_name}
  PR Number: {pr.number}
  Requirements:
    title: {issue_info.title}
    description: {issue_info.description}
    acceptance_criteria: {work_summary.acceptance_criteria}
    key_requirements: {work_summary.key_requirements}
  Session ID: {session_id}"
```

**기대 출력**: 리뷰 점수, 상세 평가, PR 코멘트 작성 여부

### Step 9: 점수 기반 자동 처리

pr-reviewer 출력을 `{skill_directory}/scripts/auto-merge.sh`에 전달하여 점수 파싱 및 머지를 실행합니다.
스크립트가 JSON 파싱, 점수 비교, `gh pr merge --squash --delete-branch` 실행까지 모두 처리합니다.

```bash
printf '%s\n' '{pr_reviewer_output}' | {skill_directory}/scripts/auto-merge.sh \
  --repo /tmp/{repo_name} \
  --pr {pr_number} \
  --threshold 90
```

스크립트 출력 JSON의 `status`, `merged`, `blocking_stage`, `blocking_reason`을 워크플로우 결과에 반영합니다.
상세 출력 형식은 `{skill_directory}/common/score-based-auto-merge.md`를 참조합니다.

## Output Format

워크플로우 완료 후 다음 JSON 형식으로 결과를 반환합니다:

```json
{
  "workflow": "mac-developer",
  "status": "success | blocked",
  "summary": "작업 결과 한 줄 요약",
  "repository": {
    "url": "https://github.com/owner/repo",
    "branch": "feature/task-123",
    "base_branch": "main"
  },
  "workflow_stages": {
    "repository_setup": { "status": "completed | failed" },
    "codebase_analysis": { "status": "completed | failed | skipped" },
    "test_writing": {
      "status": "completed | failed | skipped",
      "files_created": ["tests/auth.test.ts"]
    },
    "code_writing": {
      "status": "completed | failed",
      "files_created": ["src/auth.ts"],
      "files_modified": ["src/index.ts"]
    },
    "pr_creation": { "status": "completed | failed" },
    "ci_validation": {
      "status": "passed | failed | timeout",
      "retries": 0
    },
    "pr_review": {
      "status": "completed | failed | skipped",
      "total_score": 85,
      "breakdown": {
        "requirements_coverage": 90,
        "hardcoding_check": 80,
        "general_quality": 83
      },
      "comment_posted": true
    }
  },
  "changes": {
    "files_created": ["src/auth.ts", "tests/auth.test.ts"],
    "files_modified": ["src/index.ts"],
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
    "ci_status": "passed",
    "merged": true,
    "merge_method": "squash"
  }
}
```

## Error Handling

### 단계별 실패 처리

| 단계 | 실패 시 처리 | 최대 재시도 |
|------|------------|-----------|
| Repository 준비 | In Review 상태로 즉시 종료 | 0 |
| codebase-analyzer | 기본 분석으로 진행, 실패 시 In Review | 0 |
| test-writer | 재시도 후 partial | 1 |
| code-writer | 재시도 후 partial | 2 |
| PR 생성 | 재시도 후 partial | 1 |
| ci-validator | code-writer 재호출 | 2 |
| pr-reviewer | ≥`AUTO_MERGE_THRESHOLD` 자동 머지, 미만 partial | 0 |

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
2. **로컬 테스트 생략**: 이 워크플로우는 로컬 테스트 검증 없이 CI에서만 검증합니다
3. **순차적 Subagent 호출**: Subagent는 다른 subagent를 호출할 수 없음
4. **컨텍스트 전달**: 각 단계의 출력을 다음 단계에 완전히 전달
5. **기존 패턴 존중**: 프로젝트의 기존 코드 스타일과 패턴 따르기
6. **새 브랜치 작업**: main/master에 직접 push 금지
