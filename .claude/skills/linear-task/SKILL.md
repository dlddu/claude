---
name: linear-task
description: Linear 이슈에 대한 작업을 수행합니다. Subagent들을 orchestration하여 리서치, 라우팅, 실행을 자동화합니다. "태스크 작업", "이슈 처리", "Linear 작업" 요청 시 사용
allowed-tools: mcp__linear-server__get_issue, mcp__linear-server__update_issue, Task, Bash, TodoWrite, WebSearch, Read
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
┌─────────────────────────┐
│  워크플로우 분기 실행     │ Step 3: Progressive Disclosure
│  ├─ workflows/developer │         라우팅 결정에 따라 해당 파일만 로드
│  └─ workflows/general   │
└────────┬────────────────┘
         │
         ▼
┌─────────────────────────┐
│ linear-status-reporter  │ Step 4: 결과 보고 (공통)
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
- `routing_decision.selected_target`: "developer" 또는 "general-purpose"

### Step 3: 워크플로우 분기 실행 (Progressive Disclosure)

router의 `routing_decision.selected_target`에 따라 해당 워크플로우 파일을 로드하고 실행합니다.

#### "developer" 선택 시

1. **워크플로우 파일 로드**:
   ```
   Read tool 사용:
   - file_path: "{skill_directory}/workflows/developer.md"
   ```

2. **워크플로우 실행**: developer.md의 지침에 따라 TDD 워크플로우 수행
   - Repository 준비
   - codebase-analyzer → test-writer → code-writer 순차 호출
   - local-test-validator (최대 3회 재시도)
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

### Step 4: Linear 상태 보고 (공통)

워크플로우 결과를 바탕으로 `linear-status-reporter`를 호출합니다.

**보고 형식 참조**:
```
Read tool 사용:
- file_path: "{skill_directory}/common/linear-report-format.md"
```

**호출 방법**:
```
Task tool 사용:
- subagent_type: "linear-status-reporter"
- prompt: {JSON 형식의 결과 정보}
```

성공 시 → 이슈 상태를 "Done"으로, 완료 보고 코멘트 생성
블로킹 시 → 이슈 상태를 "Blocked"로, 블로킹 보고 코멘트 생성

## Error Handling

### Researcher 실패 시
- Linear API 접근 문제인지 확인
- 이슈 ID가 올바른지 확인
- 실패 사유와 함께 Blocked 상태로 전환

### Router 실패 시
- researcher 출력 형식 확인
- 기본값으로 general-purpose 선택 후 진행
- 불확실성을 코멘트에 명시

### 워크플로우 실패 시
- 실패 원인 분석
- 부분 완료된 작업 정리
- blocking_info 구성 후 linear-status-reporter로 보고

### linear-status-reporter 실패 시
- 워크플로우 결과는 유지
- Linear 보고 실패를 에러로 기록
- 부분 성공 결과 반환

## Important Notes

1. **Progressive Disclosure**: 라우팅 결정 후 해당 워크플로우 파일만 로드하여 토큰 효율성 확보

2. **Subagent 순차 호출**: 각 subagent는 순차적으로 호출해야 합니다 (subagent는 다른 subagent를 호출할 수 없음)

3. **컨텍스트 전달**: 각 단계의 출력을 다음 단계에 완전히 전달해야 합니다

4. **Session ID 필수**: 모든 코멘트에 Session ID를 반드시 포함합니다

5. **상태 관리**: 작업 시작 시 In Progress, 완료 시 Done 또는 Blocked로 변경

6. **에러 복구**: 가능한 경우 에러 복구를 시도하고, 불가능한 경우 명확한 보고

## Quick Reference

| 단계 | Agent | 입력 | 출력 |
|------|-------|------|------|
| 1 | linear-task-researcher | issue_id | JSON (이슈 정보, 컨텍스트) |
| 2 | task-router | researcher 출력 | JSON (라우팅 결정, 지시사항) |
| 3 | 워크플로우 분기 | router 지시사항 | 작업 결과 JSON |
| 4 | linear-status-reporter | 결과 + Linear Context | 상태 업데이트 확인 |

## File Structure

```
linear-task/
├── SKILL.md                  # 이 파일 (오케스트레이터)
├── workflows/
│   ├── developer.md          # TDD 개발 워크플로우
│   └── general-purpose.md    # 일반 작업 워크플로우
└── common/
    └── linear-report-format.md  # 보고 형식 템플릿
```
