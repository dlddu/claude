#!/bin/bash
set -euo pipefail

# linear-status-report.sh
# 워크플로우 결과 JSON을 stdin으로 받아 Linear 이슈 상태를 업데이트하고 코멘트를 생성합니다.
#
# 사용법:
#   echo '<report_json>' | ./scripts/linear-status-report.sh
#
# 환경변수:
#   LINEAR_API_KEY: Linear API 키 (필수)
#
# 종료 코드:
#   0: 정상 완료
#   1: 에러

LINEAR_API_URL="https://api.linear.app/graphql"

# LINEAR_API_KEY 확인
if [[ -z "${LINEAR_API_KEY:-}" ]]; then
    cat <<'EOF'
{"success":false,"issue_id":null,"status_updated":false,"comment_created":false,"error":"LINEAR_API_KEY 환경변수가 설정되지 않았습니다","error_stage":"init","summary":"LINEAR_API_KEY 미설정"}
EOF
    exit 1
fi

# stdin에서 JSON 읽기
INPUT=$(cat)

# 필수 필드 파싱
ISSUE_ID=$(echo "$INPUT" | jq -r '.issue_id // empty')
TEAM_ID=$(echo "$INPUT" | jq -r '.team_id // empty')
STATUS=$(echo "$INPUT" | jq -r '.status // empty')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')

if [[ -z "$ISSUE_ID" || -z "$TEAM_ID" || -z "$STATUS" ]]; then
    cat <<EOF
{"success":false,"issue_id":"$ISSUE_ID","status_updated":false,"comment_created":false,"error":"필수 필드 누락 (issue_id, team_id, status)","error_stage":"init","summary":"필수 필드 누락"}
EOF
    exit 1
fi

# Linear GraphQL API 호출 헬퍼
linear_api() {
    local query="$1"
    curl -s -X POST "$LINEAR_API_URL" \
        -H "Content-Type: application/json" \
        -H "Authorization: $LINEAR_API_KEY" \
        -d "$query"
}

# 대상 상태 이름 결정
if [[ "$STATUS" == "success" ]]; then
    TARGET_STATE_NAME="Done"
else
    TARGET_STATE_NAME="In Review"
fi

# --- Step 1: 팀 워크플로우 상태 조회 ---
STATES_QUERY=$(jq -n --arg tid "$TEAM_ID" '{
    query: "query($teamId: String!) { workflowStates(filter: { team: { id: { eq: $teamId } } }) { nodes { id name type } } }",
    variables: { teamId: $tid }
}')

STATES_RESPONSE=$(linear_api "$STATES_QUERY")

# 에러 확인
if echo "$STATES_RESPONSE" | jq -e '.errors' > /dev/null 2>&1; then
    ERROR_MSG=$(echo "$STATES_RESPONSE" | jq -r '.errors[0].message // "상태 조회 실패"')
    cat <<EOF
{"success":false,"issue_id":"$ISSUE_ID","status_updated":false,"comment_created":false,"error":"$ERROR_MSG","error_stage":"status_lookup","summary":"Linear 상태 조회 실패: $ERROR_MSG"}
EOF
    exit 1
fi

# 대상 상태 ID 찾기
TARGET_STATE_ID=$(echo "$STATES_RESPONSE" | jq -r --arg name "$TARGET_STATE_NAME" '.data.workflowStates.nodes[] | select(.name == $name) | .id' | head -1)

if [[ -z "$TARGET_STATE_ID" ]]; then
    cat <<EOF
{"success":false,"issue_id":"$ISSUE_ID","status_updated":false,"comment_created":false,"error":"상태 '$TARGET_STATE_NAME'을 찾을 수 없습니다","error_stage":"status_lookup","summary":"대상 상태를 찾을 수 없음"}
EOF
    exit 1
fi

# --- Step 2: 이슈 상태 업데이트 ---
UPDATE_QUERY=$(jq -n --arg iid "$ISSUE_ID" --arg sid "$TARGET_STATE_ID" '{
    query: "mutation($issueId: String!, $stateId: String!) { issueUpdate(id: $issueId, input: { stateId: $stateId }) { success issue { id state { name } } } }",
    variables: { issueId: $iid, stateId: $sid }
}')

UPDATE_RESPONSE=$(linear_api "$UPDATE_QUERY")

STATUS_UPDATED=false
if echo "$UPDATE_RESPONSE" | jq -e '.data.issueUpdate.success' > /dev/null 2>&1; then
    UPDATE_SUCCESS=$(echo "$UPDATE_RESPONSE" | jq -r '.data.issueUpdate.success')
    if [[ "$UPDATE_SUCCESS" == "true" ]]; then
        STATUS_UPDATED=true
    fi
fi

# --- Step 3: 코멘트 본문 구성 ---
build_success_comment() {
    local selected_target confidence task_type complexity estimated_scope
    local summary changes pr_url pr_branch verification

    selected_target=$(echo "$INPUT" | jq -r '.routing_decision.selected_target // "unknown"')
    confidence=$(echo "$INPUT" | jq -r '.routing_decision.confidence // "unknown"')
    task_type=$(echo "$INPUT" | jq -r '.work_summary.task_type // "unknown"')
    complexity=$(echo "$INPUT" | jq -r '.work_summary.complexity // "unknown"')
    estimated_scope=$(echo "$INPUT" | jq -r '.work_summary.estimated_scope // "unknown"')
    summary=$(echo "$INPUT" | jq -r '.work_result.summary // "N/A"')
    verification=$(echo "$INPUT" | jq -r '.work_result.verification // "N/A"')
    pr_url=$(echo "$INPUT" | jq -r '.work_result.pr_info.url // empty')
    pr_branch=$(echo "$INPUT" | jq -r '.work_result.pr_info.branch // empty')

    # 변경 사항 목록 구성
    local changes_list
    changes_list=$(echo "$INPUT" | jq -r '.work_result.changes[]? // empty' | sed 's/^/- /')
    if [[ -z "$changes_list" ]]; then
        changes_list="- N/A"
    fi

    # PR 정보 섹션 (있는 경우만)
    local pr_section=""
    if [[ -n "$pr_url" && "$pr_url" != "null" ]]; then
        pr_section=$(cat <<PRSEC

### PR 정보
- PR URL: $pr_url
- Branch: $pr_branch
PRSEC
)
    fi

    cat <<COMMENT
## 작업 완료 보고

**Claude Session ID**: \`$SESSION_ID\`
**Routing Decision**: \`$selected_target\` (confidence: $confidence)

### 이슈 분석 결과
- **작업 유형**: $task_type
- **복잡도**: $complexity
- **범위**: $estimated_scope

### 수행한 작업
$summary

### 변경 사항
$changes_list
$pr_section

### 검증 결과
$verification
COMMENT
}

build_blocked_comment() {
    local selected_target confidence stage reason collected_info

    selected_target=$(echo "$INPUT" | jq -r '.routing_decision.selected_target // "unknown"')
    confidence=$(echo "$INPUT" | jq -r '.routing_decision.confidence // "unknown"')
    stage=$(echo "$INPUT" | jq -r '.blocking_info.stage // "unknown"')
    reason=$(echo "$INPUT" | jq -r '.blocking_info.reason // "unknown"')
    collected_info=$(echo "$INPUT" | jq -r '.blocking_info.collected_info // "N/A"')

    # 시도한 작업 목록
    local attempted_list
    attempted_list=$(echo "$INPUT" | jq -r '.blocking_info.attempted_actions[]? // empty' | sed 's/^/- /')
    if [[ -z "$attempted_list" ]]; then
        attempted_list="- N/A"
    fi

    # 필요한 조치 목록
    local required_list
    required_list=$(echo "$INPUT" | jq -r '.blocking_info.required_actions[]? // empty' | sed 's/^/- /')
    if [[ -z "$required_list" ]]; then
        required_list="- N/A"
    fi

    cat <<COMMENT
## 작업 블로킹 보고

**Claude Session ID**: \`$SESSION_ID\`
**Routing Decision**: \`$selected_target\` (confidence: $confidence)

### 블로킹 단계
$stage 단계에서 블로킹

### 블로킹 사유
$reason

### 시도한 작업
$attempted_list

### 해결을 위해 필요한 조치
$required_list

### 수집된 정보
$collected_info
COMMENT
}

# 상태에 따라 코멘트 본문 생성
if [[ "$STATUS" == "success" ]]; then
    COMMENT_BODY=$(build_success_comment)
else
    COMMENT_BODY=$(build_blocked_comment)
fi

# --- Step 4: 코멘트 생성 ---
# JSON 안전하게 이스케이프하기 위해 jq 사용
COMMENT_QUERY=$(jq -n --arg iid "$ISSUE_ID" --arg body "$COMMENT_BODY" '{
    query: "mutation($issueId: String!, $body: String!) { commentCreate(input: { issueId: $issueId, body: $body }) { success comment { id } } }",
    variables: { issueId: $iid, body: $body }
}')

COMMENT_RESPONSE=$(linear_api "$COMMENT_QUERY")

COMMENT_CREATED=false
COMMENT_ID=""
if echo "$COMMENT_RESPONSE" | jq -e '.data.commentCreate.success' > /dev/null 2>&1; then
    COMMENT_SUCCESS=$(echo "$COMMENT_RESPONSE" | jq -r '.data.commentCreate.success')
    if [[ "$COMMENT_SUCCESS" == "true" ]]; then
        COMMENT_CREATED=true
        COMMENT_ID=$(echo "$COMMENT_RESPONSE" | jq -r '.data.commentCreate.comment.id // empty')
    fi
fi

# 코멘트 생성 실패 시 (상태 업데이트는 성공했을 수 있음)
if [[ "$COMMENT_CREATED" == "false" ]]; then
    ERROR_MSG=$(echo "$COMMENT_RESPONSE" | jq -r '.errors[0].message // "코멘트 생성 실패"' 2>/dev/null || echo "코멘트 생성 실패")
    cat <<EOF
{"success":false,"issue_id":"$ISSUE_ID","status_updated":$STATUS_UPDATED,"new_status":"$TARGET_STATE_NAME","comment_created":false,"error":"$ERROR_MSG","error_stage":"comment_create","summary":"코멘트 생성 실패: $ERROR_MSG"}
EOF
    exit 0
fi

# --- 최종 결과 출력 ---
cat <<EOF
{"success":true,"issue_id":"$ISSUE_ID","status_updated":$STATUS_UPDATED,"new_status":"$TARGET_STATE_NAME","comment_created":true,"comment_id":"$COMMENT_ID","summary":"이슈 상태가 ${TARGET_STATE_NAME}(으)로 업데이트되고 보고 코멘트가 작성되었습니다."}
EOF
