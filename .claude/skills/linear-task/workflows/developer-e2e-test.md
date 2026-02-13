# Developer E2E Test Writing Workflow

E2E 테스트를 skip 상태로 작성하는 워크플로우입니다.
구현 코드 없이 테스트 스펙만 작성하고, CI가 통과(스킵된 테스트는 실패하지 않음)하면 PR을 생성합니다.

## Configuration

| 설정 | 값 | 설명 |
|------|-----|------|
| `AUTO_MERGE_THRESHOLD` | 90 | PR 리뷰 점수가 이 값 이상이면 자동 머지 |

## Architecture

```
Developer E2E Test Workflow
       │
       ├─ Step 1: Repository 준비
       │
       ├─ Step 2: codebase-analyzer
       │
       ├─ Step 3: e2e-test-writer
       │
       ├─ Step 4: Commit 생성
       │
       ├─ Step 5: PR 생성
       │
       ├─ Step 6: ci-validator (최대 2회 재시도)
       │
       ├─ Step 7: pr-reviewer (E2E 테스트 리뷰 기준)
       │
       └─ Step 8: 점수 기반 자동 처리 (≥AUTO_MERGE_THRESHOLD: 머지)
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
  관련 영역: {target_areas}
  특히 E2E 테스트 구조와 패턴을 중점적으로 분석해주세요:
  - 기존 E2E 테스트 파일 위치 및 네이밍 컨벤션
  - 사용 중인 E2E 테스트 프레임워크 (Playwright, Cypress, etc.)
  - 기존 skip 패턴이 있는지 확인"
```

**기대 출력**: 프로젝트 정보, 디렉토리 구조, 테스트 구조, E2E 테스트 패턴

### Step 3: e2e-test-writer 호출

**Task tool 사용**:
```
subagent_type: "e2e-test-writer"
prompt: "다음 기능에 대한 E2E 테스트를 skip 상태로 작성해주세요:
  Repository: /tmp/{repo_name}
  코드베이스 분석: {codebase_analysis}
  기능 요구사항: {feature_spec}
  완료 기준: {acceptance_criteria}
  Linear 이슈: {issue_info}"
```

**기대 출력**: E2E 테스트 파일, skip된 테스트 케이스 목록

### Step 4: Commit 생성

```bash
cd /tmp/{repo_name}
git add -A
git commit -m "$(cat <<'EOF'
{커밋 메시지}

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

### Step 5: PR 생성

```bash
cd /tmp/{repo_name}
git push -u origin {branch_name}

gh pr create --title "{PR 제목}" --body "$(cat <<'EOF'
## Summary
{변경 사항 요약}

> **Note**: 이 PR은 E2E 테스트 스펙을 skip 상태로 작성합니다.
> 실제 구현 PR에서 skip이 제거되고 테스트가 활성화됩니다.

## E2E Test Cases (Skipped)
{skip된 테스트 케이스 목록}

## Changes
{변경 파일 목록}

## Session Info
**Claude Session ID**: `{session_id}`

---
Generated with Claude Code
EOF
)"
```

### Step 6: ci-validator 호출

**Task tool 사용**:
```
subagent_type: "ci-validator"
prompt: "브랜치의 CI가 완료될 때까지 대기하고 결과를 확인해주세요:
  Repository: /tmp/{repo_name}
  브랜치: {branch_name}"
```

**실패 시 처리 (최대 2회 재시도)**:
1. 실패 원인 분석
2. **e2e-test-writer 재호출**하여 수정 (구현 코드가 없으므로 code-writer가 아닌 e2e-test-writer를 호출)
3. 새 commit 생성 및 push
4. ci-validator 재호출

### Step 7: pr-reviewer 호출 (E2E 테스트 리뷰 기준)

CI 검증 통과 후 PR 리뷰를 수행합니다.

**Task tool 사용**:
```
subagent_type: "pr-reviewer"
prompt: "다음 PR에 대한 리뷰를 수행해주세요:
  Repository: /tmp/{repo_name}
  PR Number: {pr.number}
  **Review Type: E2E Test Writing**

  Requirements:
    title: {issue_info.title}
    description: {issue_info.description}
    acceptance_criteria: {work_summary.acceptance_criteria}
    key_requirements: {work_summary.key_requirements}

  **E2E 테스트 리뷰 기준** (일반 리뷰 기준 대신 아래 기준 사용):
  - 요구사항 반영도 (50%): acceptance criteria가 e2e 테스트 케이스로 커버되는가?
  - 테스트 품질 (30%): 테스트 구조, 가독성, 패턴 준수, 현실적 테스트 데이터 사용
  - 하드코딩 여부 (20%): 테스트 데이터/선택자의 적절한 파라미터화

  감점 항목 (기본 점수에서 차감):
  - 바이너리 파일 포함: 0 ~ -20점 (기존과 동일)
  - **CI 미통과: -100점** (CI가 통과하지 않은 경우 → 자동 블로킹)

  **추가 확인 사항**:
  - 모든 e2e 테스트가 skip 상태인지 확인
  - skip 제거 시 실행 가능한 구조인지 확인 (import, fixture, setup 정확성)

  Session ID: {session_id}"
```

**기대 출력**: 리뷰 점수, 상세 평가, PR 코멘트 작성 여부

### Step 8: 점수 기반 자동 처리

pr-reviewer 출력을 `scripts/auto-merge.sh`에 전달하여 점수 파싱 및 머지를 실행합니다.
스크립트가 JSON 파싱, 점수 비교, `gh pr merge --squash --delete-branch` 실행까지 모두 처리합니다.

```bash
echo '{pr_reviewer_output}' | {repository_root}/scripts/auto-merge.sh \
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
  "workflow": "developer-e2e-test",
  "status": "success | blocked",
  "summary": "작업 결과 한 줄 요약",
  "repository": {
    "url": "https://github.com/owner/repo",
    "branch": "feature/e2e-test-123",
    "base_branch": "main"
  },
  "workflow_stages": {
    "repository_setup": { "status": "completed | failed" },
    "codebase_analysis": { "status": "completed | failed | skipped" },
    "e2e_test_writing": {
      "status": "completed | failed",
      "files_created": ["tests/e2e/feature.e2e.test.ts"],
      "test_cases_count": 8,
      "all_skipped": true
    },
    "pr_creation": { "status": "completed | failed" },
    "ci_validation": {
      "status": "passed | failed | timeout",
      "retries": 0
    },
    "pr_review": {
      "status": "completed | failed | skipped",
      "total_score": 92,
      "breakdown": {
        "requirements_coverage": 95,
        "test_quality": 90,
        "hardcoding_check": 88
      },
      "ci_failure_penalty": 0,
      "comment_posted": true
    }
  },
  "changes": {
    "files_created": ["tests/e2e/feature.e2e.test.ts"],
    "files_modified": [],
    "files_deleted": []
  },
  "tests": {
    "total": 8,
    "skipped": 8,
    "type": "e2e"
  },
  "pr": {
    "created": true,
    "url": "https://github.com/owner/repo/pull/123",
    "number": 123,
    "title": "test: Add e2e test specs for feature (skipped)",
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
| e2e-test-writer | 재시도 후 partial | 1 |
| PR 생성 | 재시도 후 partial | 1 |
| ci-validator | e2e-test-writer 재호출 | 2 |
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

1. **구현 코드 없음**: 이 워크플로우는 테스트 스펙만 작성합니다 (code-writer 호출 없음)
2. **모든 테스트 skip**: 작성된 모든 e2e 테스트는 skip 상태여야 합니다
3. **실행 가능한 구조**: skip이 제거되면 바로 실행 가능해야 합니다
4. **순차적 Subagent 호출**: Subagent는 다른 subagent를 호출할 수 없음
5. **컨텍스트 전달**: 각 단계의 출력을 다음 단계에 완전히 전달
6. **기존 패턴 존중**: 프로젝트의 기존 E2E 테스트 스타일과 패턴 따르기
7. **새 브랜치 작업**: main/master에 직접 push 금지
