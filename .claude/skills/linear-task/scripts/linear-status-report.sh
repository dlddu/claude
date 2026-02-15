#!/bin/bash
set -euo pipefail

# linear-status-report.sh
# 워크플로우 결과의 status 필드를 기반으로 Linear 이슈 상태를 결정하고,
# comment-composer subagent가 생성한 코멘트 본문으로 코멘트를 생성합니다.
#
# 사용법:
#   printf '%s\n' '<script_input_json>' | {skill_directory}/scripts/linear-status-report.sh
#
# 입력 JSON (stdin):
#   {
#     "issue_id": "이슈 ID",
#     "team_id": "팀 ID",
#     "status": "success | blocked",
#     "comment_body": "Markdown 코멘트 본문"
#   }
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
ISSUE_ID=$(printf '%s\n' "$INPUT" | jq -r '.issue_id // empty')
TEAM_ID=$(printf '%s\n' "$INPUT" | jq -r '.team_id // empty')
STATUS=$(printf '%s\n' "$INPUT" | jq -r '.status // empty')
COMMENT_BODY=$(printf '%s\n' "$INPUT" | jq -r '.comment_body // empty')

if [[ -z "$ISSUE_ID" || -z "$TEAM_ID" || -z "$STATUS" || -z "$COMMENT_BODY" ]]; then
    cat <<EOF
{"success":false,"issue_id":"$ISSUE_ID","status_updated":false,"comment_created":false,"error":"필수 필드 누락 (issue_id, team_id, status, comment_body)","error_stage":"init","summary":"필수 필드 누락"}
EOF
    exit 1
fi

# status 기반으로 대상 상태 결정
if [[ "$STATUS" == "success" ]]; then
    TARGET_STATE_NAME="Done"
else
    TARGET_STATE_NAME="In Review"
fi

# Linear GraphQL API 호출 헬퍼
linear_api() {
    local query="$1"
    curl -s -X POST "$LINEAR_API_URL" \
        -H "Content-Type: application/json" \
        -H "Authorization: $LINEAR_API_KEY" \
        -d "$query"
}

# --- Step 1: 팀 워크플로우 상태 조회 ---
STATES_QUERY=$(jq -n --arg tid "$TEAM_ID" '{
    query: "query($teamId: String!) { workflowStates(filter: { team: { id: { eq: $teamId } } }) { nodes { id name type } } }",
    variables: { teamId: $tid }
}')

STATES_RESPONSE=$(linear_api "$STATES_QUERY")

# 에러 확인
if printf '%s\n' "$STATES_RESPONSE" | jq -e '.errors' > /dev/null 2>&1; then
    ERROR_MSG=$(printf '%s\n' "$STATES_RESPONSE" | jq -r '.errors[0].message // "상태 조회 실패"')
    cat <<EOF
{"success":false,"issue_id":"$ISSUE_ID","status_updated":false,"comment_created":false,"error":"$ERROR_MSG","error_stage":"status_lookup","summary":"Linear 상태 조회 실패: $ERROR_MSG"}
EOF
    exit 1
fi

# 대상 상태 ID 찾기
TARGET_STATE_ID=$(printf '%s\n' "$STATES_RESPONSE" | jq -r --arg name "$TARGET_STATE_NAME" '.data.workflowStates.nodes[] | select(.name == $name) | .id' | head -1)

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
if printf '%s\n' "$UPDATE_RESPONSE" | jq -e '.data.issueUpdate.success' > /dev/null 2>&1; then
    UPDATE_SUCCESS=$(printf '%s\n' "$UPDATE_RESPONSE" | jq -r '.data.issueUpdate.success')
    if [[ "$UPDATE_SUCCESS" == "true" ]]; then
        STATUS_UPDATED=true
    fi
fi

# --- Step 3: 코멘트 생성 ---
# JSON 안전하게 이스케이프하기 위해 jq 사용
COMMENT_QUERY=$(jq -n --arg iid "$ISSUE_ID" --arg body "$COMMENT_BODY" '{
    query: "mutation($issueId: String!, $body: String!) { commentCreate(input: { issueId: $issueId, body: $body }) { success comment { id } } }",
    variables: { issueId: $iid, body: $body }
}')

COMMENT_RESPONSE=$(linear_api "$COMMENT_QUERY")

COMMENT_CREATED=false
COMMENT_ID=""
if printf '%s\n' "$COMMENT_RESPONSE" | jq -e '.data.commentCreate.success' > /dev/null 2>&1; then
    COMMENT_SUCCESS=$(printf '%s\n' "$COMMENT_RESPONSE" | jq -r '.data.commentCreate.success')
    if [[ "$COMMENT_SUCCESS" == "true" ]]; then
        COMMENT_CREATED=true
        COMMENT_ID=$(printf '%s\n' "$COMMENT_RESPONSE" | jq -r '.data.commentCreate.comment.id // empty')
    fi
fi

# 코멘트 생성 실패 시 (상태 업데이트는 성공했을 수 있음)
if [[ "$COMMENT_CREATED" == "false" ]]; then
    ERROR_MSG=$(printf '%s\n' "$COMMENT_RESPONSE" | jq -r '.errors[0].message // "코멘트 생성 실패"' 2>/dev/null || echo "코멘트 생성 실패")
    cat <<EOF
{"success":false,"issue_id":"$ISSUE_ID","status_updated":$STATUS_UPDATED,"new_status":"$TARGET_STATE_NAME","comment_created":false,"error":"$ERROR_MSG","error_stage":"comment_create","summary":"코멘트 생성 실패: $ERROR_MSG"}
EOF
    exit 0
fi

# --- 최종 결과 출력 ---
cat <<EOF
{"success":true,"issue_id":"$ISSUE_ID","status_updated":$STATUS_UPDATED,"new_status":"$TARGET_STATE_NAME","comment_created":true,"comment_id":"$COMMENT_ID","summary":"이슈 상태가 ${TARGET_STATE_NAME}(으)로 업데이트되고 보고 코멘트가 작성되었습니다."}
EOF
