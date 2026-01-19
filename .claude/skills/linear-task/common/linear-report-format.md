# Linear Status Report Format

linear-status-reporter subagent에 전달할 입력 형식입니다.

## Input JSON Structure

### 성공 시 (Developer Workflow)

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
    "verification": "테스트: {tests.passed}/{tests.total} 통과, CI: {pr.ci_status}",
    "pr_review": {
      "total_score": 85,
      "requirements_coverage": 90,
      "hardcoding_check": 80,
      "general_quality": 83,
      "comment_posted": true
    }
  }
}
```

### 성공 시 (General Purpose Workflow)

```json
{
  "issue_id": "{issue_id}",
  "team_id": "{team_id}",
  "session_id": "{session_id}",
  "status": "success",
  "routing_decision": {
    "selected_target": "general-purpose",
    "confidence": "{routing_decision.confidence}",
    "reasoning": "{routing_decision.reasoning}"
  },
  "work_summary": {
    "task_type": "{work_summary.task_type}",
    "complexity": "{work_summary.complexity}",
    "estimated_scope": "{work_summary.estimated_scope}"
  },
  "work_result": {
    "executor": "general-purpose",
    "summary": "{general-purpose 작업 요약}",
    "changes": ["{생성된 산출물 목록}"],
    "pr_info": null,
    "verification": "N/A (non-code task)"
  }
}
```

### 블로킹 시 (공통)

```json
{
  "issue_id": "{issue_id}",
  "team_id": "{team_id}",
  "session_id": "{session_id}",
  "status": "blocked",
  "routing_decision": {
    "selected_target": "{developer | general-purpose}",
    "confidence": "{routing_decision.confidence}",
    "reasoning": "{routing_decision.reasoning}"
  },
  "work_summary": {
    "task_type": "{work_summary.task_type}",
    "complexity": "{work_summary.complexity}",
    "estimated_scope": "{work_summary.estimated_scope}"
  },
  "blocking_info": {
    "stage": "{실패 단계}",
    "reason": "{에러 메시지 또는 실패 사유}",
    "attempted_actions": ["{실패 전 시도한 작업들}"],
    "required_actions": ["{수정 제안 또는 다음 단계}"],
    "collected_info": "{부분 결과 또는 진단 정보}"
  }
}
```

## Field Descriptions

| 필드 | 설명 |
|------|------|
| `issue_id` | Linear 이슈 ID |
| `team_id` | Linear 팀 ID |
| `session_id` | Claude Session ID (환경변수 $CLAUDE_SESSION_ID) |
| `status` | "success" 또는 "blocked" |
| `routing_decision.selected_target` | "developer" 또는 "general-purpose" |
| `routing_decision.confidence` | "high", "medium", "low" |
| `work_result.executor` | 실행한 워크플로우 유형 |
| `work_result.pr_info` | PR 정보 (developer만 해당, general-purpose는 null) |
| `blocking_info.stage` | 실패한 단계 |

## Stage Values

### Developer Workflow Stages
- `repository_setup`
- `codebase_analysis`
- `test_writing`
- `code_writing`
- `local_validation`
- `pr_creation`
- `ci_validation`
- `pr_review`

### General Purpose Workflow Stages
- `general-purpose`
