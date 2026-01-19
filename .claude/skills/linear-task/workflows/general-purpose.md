# General Purpose Workflow

일반 목적 작업(문서, 리서치, 분석 등)을 수행하는 워크플로우입니다.

## Architecture

```
General Purpose Workflow
       │
       └─ Step 1: general-purpose subagent 호출
```

## Input Requirements

이 워크플로우는 다음 정보가 필요합니다:
- `agent_instructions`: 작업 지시사항
- `success_criteria`: 완료 기준

## Workflow Steps

### Step 1: general-purpose 호출

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

## Output Format

워크플로우 완료 후 다음 JSON 형식으로 결과를 반환합니다:

### 성공 시

```json
{
  "workflow": "general-purpose",
  "success": true,
  "status": "completed",
  "summary": "수행한 작업 요약",
  "deliverables": ["산출물 1", "산출물 2"],
  "details": {
    "actions_taken": ["수행한 작업 1", "수행한 작업 2"],
    "findings": "조사/분석 결과 (해당하는 경우)",
    "recommendations": "권장 사항 (해당하는 경우)"
  }
}
```

### 실패 시

```json
{
  "workflow": "general-purpose",
  "success": false,
  "status": "failed",
  "summary": "실패 사유 요약",
  "partial_results": {
    "completed_actions": ["완료된 작업"],
    "remaining_actions": ["미완료 작업"]
  },
  "error": {
    "reason": "실패 사유",
    "attempted_actions": ["시도한 작업들"],
    "required_actions": ["해결에 필요한 조치"]
  }
}
```

## Error Handling

### 작업 실패 시

1. 실패 원인 분석
2. 부분 완료된 작업 정리
3. `blocking_info` 구조로 상세 정보 제공:
   - `stage`: "general-purpose"
   - `reason`: 실패 사유
   - `attempted_actions`: 시도한 작업들
   - `required_actions`: 필요한 조치들
   - `collected_info`: 수집된 정보 요약

## Important Notes

1. **PR 정보 없음**: 이 워크플로우는 코드 작업이 아니므로 PR 정보가 없습니다
2. **Repository 불필요**: GitHub repository가 필요하지 않습니다
3. **유연한 작업 범위**: 문서 작성, 리서치, 분석, 계획 수립 등 다양한 작업 지원
