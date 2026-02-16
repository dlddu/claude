---
name: linear-task
description: Linear 이슈에 대한 작업을 수행합니다. Subagent들을 orchestration하여 리서치, 라우팅, 실행을 자동화합니다. "태스크 작업", "이슈 처리", "Linear 작업" 요청 시 사용
allowed-tools: mcp__linear-server__get_issue, mcp__linear-server__create_comment, Task, Bash, TodoWrite, WebSearch, Read
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
│  task-router    │ Step 2: 작업 유형 분석 및 라우팅 결정
└────────┬────────┘
         │
         ▼
┌──────────────────────────────────┐
│  워크플로우 분기 실행              │ Step 3: Progressive Disclosure
│  ├─ workflows/developer          │         라우팅 결정에 따라 해당 파일만 로드
│  ├─ workflows/developer-e2e-test │  (variant: e2e-test)
│  ├─ workflows/developer-impl    │  (variant: implementation)
│  ├─ workflows/mac-developer      │
│  └─ workflows/general            │
└────────┬─────────────────────────┘
         │
         ▼
┌──────────────────────────────┐
│ comment-composer      │ Step 4: 코멘트 본문 생성 (subagent)
└────────┬─────────────────────┘
         │
         ▼
┌──────────────────────────────┐
│ linear-status-report.sh      │ Step 5: 상태 결정 + API 실행 (스크립트)
└──────────────────────────────┘
```

## Workflow

### Step 0: 작업 시작 알림

Linear 이슈에 작업 시작 코멘트를 생성합니다.

**mcp__linear-server__create_comment 도구 사용**:
- issueId: `{issue_id}`
- body: 아래 형식의 Markdown

**코멘트 형식**:
```markdown
## 🚀 작업 시작

**Claude Session ID**: `${CLAUDE_SESSION_ID}`
**시작 시간**: {current_timestamp}

---
작업이 시작되었습니다. 완료 후 결과를 업데이트하겠습니다.
```

**에러 처리**: 코멘트 생성 실패 시에도 워크플로우 계속 진행

이 Session ID는 최종 완료 코멘트에도 포함됩니다.

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
- `routing_decision.selected_target`: "developer", "mac-developer" 또는 "general-purpose"

### Step 3: 워크플로우 분기 실행 (Progressive Disclosure)

router의 `routing_decision.selected_target`에 따라 해당 워크플로우 파일을 로드하고 실행합니다.

#### "developer" 선택 시

`routing_decision.workflow_variant` 값에 따라 로드할 워크플로우를 결정합니다:

##### workflow_variant: "e2e-test"

1. **워크플로우 파일 로드**:
   ```
   Read tool 사용:
   - file_path: "{skill_directory}/workflows/developer-e2e-test.md"
   ```

2. **워크플로우 실행**: developer-e2e-test.md의 지침에 따라 E2E 테스트 작성 워크플로우 수행
   - Repository 준비
   - codebase-analyzer → e2e-test-writer 순차 호출
   - PR 생성
   - ci-validator (최대 2회 재시도)

3. **결과 수집**: 워크플로우 완료 후 결과 JSON 구성

##### workflow_variant: "implementation"

1. **워크플로우 파일 로드**:
   ```
   Read tool 사용:
   - file_path: "{skill_directory}/workflows/developer-impl.md"
   ```

2. **워크플로우 실행**: developer-impl.md의 지침에 따라 TDD + E2E 활성화 워크플로우 수행
   - Repository 준비
   - codebase-analyzer → test-writer → code-writer → E2E 활성화 (code-writer) 순차 호출
   - local-test-validator (최대 3회 재시도)
   - PR 생성
   - ci-validator (최대 2회 재시도)

3. **결과 수집**: 워크플로우 완료 후 결과 JSON 구성

##### workflow_variant: null (기본값)

1. **워크플로우 파일 로드**:
   ```
   Read tool 사용:
   - file_path: "{skill_directory}/workflows/developer.md"
   ```

2. **워크플로우 실행**: 기존 developer.md의 지침에 따라 TDD 워크플로우 수행
   - Repository 준비
   - codebase-analyzer → test-writer → code-writer 순차 호출
   - local-test-validator (최대 3회 재시도)
   - PR 생성
   - ci-validator (최대 2회 재시도)

3. **결과 수집**: 워크플로우 완료 후 결과 JSON 구성

#### "mac-developer" 선택 시

1. **워크플로우 파일 로드**:
   ```
   Read tool 사용:
   - file_path: "{skill_directory}/workflows/mac-developer.md"
   ```

2. **워크플로우 실행**: mac-developer.md의 지침에 따라 TDD 워크플로우 수행 (로컬 테스트 제외)
   - Repository 준비
   - codebase-analyzer → test-writer → code-writer 순차 호출
   - PR 생성
   - ci-validator (최대 2회 재시도)

3. **결과 수집**: 워크플로우 완료 후 결과 JSON 구성

#### "general-purpose" 선택 시

1. **워크플로우 파일 로드**:
   ```
   Read tool 사용:
   - file_path: "{skill_directory}/workflows/general-purpose.md"
   ```

2. **워크플로우 실행**: general-purpose.md의 지침에 따라 작업 수행
   - general-purpose subagent 호출

3. **결과 수집**: 워크플로우 완료 후 결과 JSON 구성

### Step 4: 코멘트 본문 생성

`comment-composer` subagent를 호출하여 코멘트 본문을 생성합니다.

**보고 형식 참조**:
```
Read tool 사용:
- file_path: "{skill_directory}/common/report-format.md"
```

**호출 방법**:
```
Task tool 사용:
- subagent_type: "comment-composer"
- prompt: {JSON 형식의 결과 정보} (report-format.md 참조)
```

**기대 출력**:
```json
{
  "comment_body": "Markdown 코멘트 본문"
}
```

### Step 5: Linear 상태 업데이트 + 코멘트 생성

subagent가 생성한 `comment_body`와 워크플로우 결과의 `issue_id`, `team_id`, `status`를 조합하여
`{skill_directory}/scripts/linear-status-report.sh` 스크립트에 전달합니다.
스크립트가 `status` 필드 기반으로 대상 상태를 결정(success→Done, blocked→In Review)하고,
Linear GraphQL API를 호출하여 상태 변경과 코멘트 생성을 처리합니다.

**스크립트 입력 JSON 구성**:
```json
{
  "issue_id": "{워크플로우 결과의 issue_id}",
  "team_id": "{워크플로우 결과의 team_id}",
  "status": "{워크플로우 결과의 status (success | blocked)}",
  "comment_body": "{Step 4 subagent가 반환한 comment_body}"
}
```

**스크립트 실행**:
```bash
# 1. JSON을 임시 파일에 저장
echo '{script_input}' > /tmp/linear-status-input.json

# 2. 스크립트 실행 (실패 시 DEBUG=1 추가하여 재실행)
{skill_directory}/scripts/linear-status-report.sh /tmp/linear-status-input.json
```

> `{skill_directory}`는 이 스킬의 디렉토리 경로입니다.

상세 출력 형식은 `{skill_directory}/common/linear-status-report.md`를 참조합니다.

성공 시 → 이슈 상태를 "Done"으로, 완료 보고 코멘트 생성
블로킹 시 → 이슈 상태를 "In Review"로, 블로킹 보고 코멘트 생성

## Error Handling

### Researcher 실패 시
- Linear API 접근 문제인지 확인
- 이슈 ID가 올바른지 확인
- 실패 사유와 함께 In Review 상태로 전환

### Router 실패 시
- researcher 출력 형식 확인
- 기본값으로 general-purpose 선택 후 진행
- 불확실성을 코멘트에 명시

### 워크플로우 실패 시
- 실패 원인 분석
- 부분 완료된 작업 정리
- blocking_info 구성 후 linear-status-report.sh 스크립트로 보고

### linear-status-report.sh (Step 5) 실패 시
- 워크플로우 결과는 유지
- Linear 보고 실패를 에러로 기록
- 부분 성공 결과 반환

## Important Notes

1. **Progressive Disclosure**: 라우팅 결정 후 해당 워크플로우 파일만 로드하여 토큰 효율성 확보

2. **Subagent 순차 호출**: 각 subagent는 순차적으로 호출해야 합니다 (subagent는 다른 subagent를 호출할 수 없음)

3. **컨텍스트 전달**: 각 단계의 출력을 다음 단계에 완전히 전달해야 합니다

4. **Session ID 필수**: 모든 코멘트에 Session ID를 반드시 포함합니다

5. **상태 관리**: 작업 시작 시 In Progress, 완료 시 Done 또는 In Review로 변경

6. **에러 복구**: 가능한 경우 에러 복구를 시도하고, 불가능한 경우 명확한 보고

## Quick Reference

| 단계 | Agent | 입력 | 출력 |
|------|-------|------|------|
| 1 | linear-task-researcher | issue_id | JSON (이슈 정보, 컨텍스트) |
| 2 | task-router | researcher 출력 | JSON (라우팅 결정, 지시사항) |
| 3 | 워크플로우 분기 | router 지시사항 | 작업 결과 JSON |
| 4 | comment-composer | 결과 JSON | 코멘트 본문 |
| 5 | linear-status-report.sh (스크립트) | status + comment_body (파일) | 상태 결정 + 업데이트 + 코멘트 생성 |

## File Structure

```
linear-task/
├── SKILL.md                      # 이 파일 (오케스트레이터)
├── workflows/
│   ├── developer.md              # 기본 TDD 개발 워크플로우
│   ├── developer-e2e-test.md     # E2E 테스트 작성 워크플로우 (skip 상태)
│   ├── developer-impl.md         # 구현 + E2E 활성화 워크플로우
│   ├── mac-developer.md          # TDD 개발 워크플로우 (로컬 테스트 제외)
│   └── general-purpose.md        # 일반 작업 워크플로우
├── common/
│   ├── report-format.md          # 보고 형식 템플릿
│   ├── linear-status-report.md   # 상태 보고 절차
│   └── score-based-auto-merge.md # 점수 기반 자동 머지 절차
└── scripts/
    ├── linear-status-report.sh   # Linear 상태 업데이트 + 코멘트 생성 스크립트
    └── auto-merge.sh             # 점수 파싱 + PR 머지 실행 스크립트
```
