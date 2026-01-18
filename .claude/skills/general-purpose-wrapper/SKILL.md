---
name: general-purpose-wrapper
description: General-purpose 작업 수행 후 Linear 상태 보고를 수행하는 래퍼 스킬. linear-task에서 일반 작업(문서, 리서치, 분석 등) 라우팅 시 사용합니다.
allowed-tools: Task
---

# General Purpose Wrapper Skill

일반 목적 작업을 수행하고 Linear 이슈 상태를 업데이트하는 래퍼 스킬입니다.

## Architecture

```
┌─────────────────────┐
│ general-purpose-    │ (이 Skill)
│      wrapper        │
└─────────┬───────────┘
          │
          ▼
┌─────────────────────┐
│   general-purpose   │ Step 1: 실제 작업 수행
│     (built-in)      │
└─────────┬───────────┘
          │
          ▼
┌─────────────────────┐
│ linear-status-      │ Step 2: 결과 보고
│    reporter         │
└─────────────────────┘
```

## Input Format

이 skill은 다음 형식의 args를 받습니다:

```
작업 내용: {agent_instructions}
완료 기준: {success_criteria}

[Linear Context]
issue_id: {issue_id}
team_id: {team_id}
session_id: {session_id}
routing_decision: {routing_decision JSON}
work_summary: {work_summary JSON}
```

## Workflow

### Step 1: Linear 컨텍스트 파싱

입력에서 Linear 컨텍스트를 추출합니다:
- `issue_id`
- `team_id`
- `session_id`
- `routing_decision` (JSON)
- `work_summary` (JSON)

이 정보는 Step 2에서 linear-status-reporter에 전달됩니다.

### Step 2: general-purpose 호출

**Task tool 사용**:
```
subagent_type: "general-purpose"
prompt: "다음 작업을 수행해주세요:
  작업 내용: {agent_instructions}
  완료 기준: {success_criteria}"
```

**결과 수집**:
- 작업 성공/실패 여부
- 수행한 작업 요약
- 생성된 산출물 목록

### Step 3: linear-status-reporter 호출

general-purpose의 결과를 바탕으로 linear-status-reporter를 호출합니다.

**Task tool 사용**:
```
subagent_type: "linear-status-reporter"
prompt: JSON 형식의 결과 정보
```

#### 성공 시 Input

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

#### 블로킹 시 Input

```json
{
  "issue_id": "{issue_id}",
  "team_id": "{team_id}",
  "session_id": "{session_id}",
  "status": "blocked",
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
  "blocking_info": {
    "stage": "general-purpose",
    "reason": "{실패 사유}",
    "attempted_actions": ["{시도한 작업들}"],
    "required_actions": ["{필요한 조치들}"],
    "collected_info": "{수집된 정보 요약}"
  }
}
```

## Output Format

작업 완료 후 **반드시** 다음 JSON 형식으로 반환합니다:

### 성공 시

```json
{
  "success": true,
  "status": "completed",
  "work_result": {
    "executor": "general-purpose",
    "summary": "수행한 작업 요약",
    "deliverables": ["산출물 1", "산출물 2"]
  },
  "linear_report": {
    "reported": true,
    "issue_id": "이슈 ID",
    "new_status": "Done",
    "comment_created": true
  }
}
```

### 실패 시

```json
{
  "success": false,
  "status": "blocked",
  "error_stage": "general-purpose | linear-status-reporter",
  "error": "에러 메시지",
  "work_result": {
    "partial_summary": "부분 완료된 작업 (있는 경우)"
  },
  "linear_report": {
    "reported": true,
    "issue_id": "이슈 ID",
    "new_status": "Blocked",
    "comment_created": true
  }
}
```

## Error Handling

### general-purpose 실패 시

1. 실패 원인 분석
2. `blocking_info` 생성
3. linear-status-reporter 호출하여 Blocked 상태로 업데이트
4. 실패 결과 반환

### linear-status-reporter 실패 시

1. general-purpose 결과는 유지
2. Linear 보고 실패를 에러로 기록
3. 부분 성공 결과 반환 (`linear_report.reported: false`)

## Important Notes

1. **순차적 호출**: general-purpose 완료 후 linear-status-reporter 호출
2. **컨텍스트 보존**: Linear 컨텍스트를 정확히 파싱하여 전달
3. **에러 복구**: general-purpose 실패해도 Linear 상태는 업데이트
4. **PR 정보 없음**: general-purpose는 코드 작업이 아니므로 `pr_info`는 null
5. **Session ID 필수**: 모든 보고에 Session ID를 포함
