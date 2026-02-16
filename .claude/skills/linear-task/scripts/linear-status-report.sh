#!/bin/bash
set -euo pipefail

# 디버그 로깅 함수 (DEBUG=1 설정 시 stderr로 출력)
debug_log() {
    if [[ "${DEBUG:-}" == "1" ]]; then
        echo "[DEBUG][$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2
    fi
}

# linear-status-report.sh
# 워크플로우 결과의 status 필드를 기반으로 Linear 이슈 상태를 결정하고,
# comment-composer subagent가 생성한 코멘트 본문으로 코멘트를 생성합니다.
#
# 사용법:
#   {skill_directory}/scripts/linear-status-report.sh --input <file>
#
# 입력 JSON (파일):
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

# 인자 파싱
INPUT_FILE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --input) INPUT_FILE="$2"; shift 2 ;;
        *)
            jq -nc --arg opt "$1" '{success:false,issue_id:null,status_updated:false,comment_created:false,error:("알 수 없는 옵션: "+$opt),error_stage:"init",summary:("알 수 없는 옵션: "+$opt)}'
            exit 1
            ;;
    esac
done

debug_log "=== linear-status-report.sh 시작 ==="
debug_log "LINEAR_API_URL: $LINEAR_API_URL"
debug_log "INPUT_FILE: $INPUT_FILE"

# LINEAR_API_KEY 확인
debug_log "LINEAR_API_KEY 존재 여부 확인 중..."
if [[ -z "${LINEAR_API_KEY:-}" ]]; then
    debug_log "ERROR: LINEAR_API_KEY가 설정되지 않음"
    cat <<'EOF'
{"success":false,"issue_id":null,"status_updated":false,"comment_created":false,"error":"LINEAR_API_KEY 환경변수가 설정되지 않았습니다","error_stage":"init","summary":"LINEAR_API_KEY 미설정"}
EOF
    exit 1
fi
debug_log "LINEAR_API_KEY 확인 완료 (길이: ${#LINEAR_API_KEY})"

# 입력 파일 검증
if [[ -z "$INPUT_FILE" ]]; then
    debug_log "ERROR: --input 인자가 지정되지 않음"
    jq -nc '{success:false,issue_id:null,status_updated:false,comment_created:false,error:"--input <file> 인자가 필요합니다",error_stage:"init",summary:"--input 인자 누락"}'
    exit 1
fi

if [[ ! -f "$INPUT_FILE" ]]; then
    debug_log "ERROR: 입력 파일을 찾을 수 없음: $INPUT_FILE"
    jq -nc --arg f "$INPUT_FILE" '{success:false,issue_id:null,status_updated:false,comment_created:false,error:("입력 파일을 찾을 수 없습니다: "+$f),error_stage:"init",summary:"입력 파일 없음"}'
    exit 1
fi

# 입력 파일에서 JSON 읽기
debug_log "입력 파일에서 JSON 읽기 시작... (파일: $INPUT_FILE)"
INPUT=$(cat "$INPUT_FILE")
debug_log "입력 JSON 수신 완료 (길이: ${#INPUT})"

if [[ -z "$INPUT" ]]; then
    debug_log "ERROR: 입력 파일이 비어 있음: $INPUT_FILE"
    jq -nc --arg f "$INPUT_FILE" '{success:false,issue_id:null,status_updated:false,comment_created:false,error:("입력 파일이 비어 있습니다: "+$f),error_stage:"init",summary:"입력 파일 비어있음"}'
    exit 1
fi

# 필수 필드 파싱
debug_log "필수 필드 파싱 중..."
ISSUE_ID=$(echo "$INPUT" | jq -r '.issue_id // empty')
TEAM_ID=$(echo "$INPUT" | jq -r '.team_id // empty')
STATUS=$(echo "$INPUT" | jq -r '.status // empty')
COMMENT_BODY=$(echo "$INPUT" | jq -r '.comment_body // empty')

debug_log "파싱 결과 - ISSUE_ID: $ISSUE_ID, TEAM_ID: $TEAM_ID, STATUS: $STATUS, COMMENT_BODY 길이: ${#COMMENT_BODY}"

if [[ -z "$ISSUE_ID" || -z "$TEAM_ID" || -z "$STATUS" || -z "$COMMENT_BODY" ]]; then
    debug_log "ERROR: 필수 필드 누락 - ISSUE_ID='$ISSUE_ID', TEAM_ID='$TEAM_ID', STATUS='$STATUS', COMMENT_BODY 비어있음=${COMMENT_BODY:+false}"
    jq -nc --arg iid "$ISSUE_ID" '{success:false,issue_id:$iid,status_updated:false,comment_created:false,error:"필수 필드 누락 (issue_id, team_id, status, comment_body)",error_stage:"init",summary:"필수 필드 누락"}'
    exit 1
fi

# status 기반으로 대상 상태 결정
debug_log "status 기반 대상 상태 결정 중... (STATUS=$STATUS)"
if [[ "$STATUS" == "success" ]]; then
    TARGET_STATE_NAME="Done"
else
    TARGET_STATE_NAME="In Review"
fi
debug_log "대상 상태 결정 완료: TARGET_STATE_NAME=$TARGET_STATE_NAME"

# Linear GraphQL API 호출 헬퍼
linear_api() {
    local query="$1"
    debug_log "Linear API 호출 중... (요청 크기: ${#query})"
    local response
    response=$(curl -s -X POST "$LINEAR_API_URL" \
        -H "Content-Type: application/json" \
        -H "Authorization: $LINEAR_API_KEY" \
        -d "$query")
    debug_log "Linear API 응답 수신 (응답 크기: ${#response})"
    echo "$response"
}

# --- Step 1: 팀 워크플로우 상태 조회 ---
debug_log "--- Step 1: 팀 워크플로우 상태 조회 시작 (TEAM_ID=$TEAM_ID) ---"
STATES_QUERY=$(jq -n --arg tid "$TEAM_ID" '{
    query: "query($teamId: ID!) { workflowStates(filter: { team: { id: { eq: $teamId } } }) { nodes { id name type } } }",
    variables: { teamId: $tid }
}')

STATES_RESPONSE=$(linear_api "$STATES_QUERY")

# 에러 확인
if echo "$STATES_RESPONSE" | jq -e '.errors' > /dev/null 2>&1; then
    ERROR_MSG=$(echo "$STATES_RESPONSE" | jq -r '.errors[0].message // "상태 조회 실패"')
    debug_log "ERROR: 워크플로우 상태 조회 실패 - $ERROR_MSG"
    jq -nc --arg iid "$ISSUE_ID" --arg err "$ERROR_MSG" '{success:false,issue_id:$iid,status_updated:false,comment_created:false,error:$err,error_stage:"status_lookup",summary:("Linear 상태 조회 실패: "+$err)}'
    exit 1
fi
debug_log "워크플로우 상태 조회 성공"

# 대상 상태 ID 찾기
debug_log "대상 상태 '$TARGET_STATE_NAME' ID 조회 중..."
TARGET_STATE_ID=$(echo "$STATES_RESPONSE" | jq -r --arg name "$TARGET_STATE_NAME" '.data.workflowStates.nodes[] | select(.name == $name) | .id' | head -1)

if [[ -z "$TARGET_STATE_ID" ]]; then
    debug_log "ERROR: 대상 상태 '$TARGET_STATE_NAME'을 찾을 수 없음"
    debug_log "사용 가능한 상태 목록: $(echo "$STATES_RESPONSE" | jq -r '[.data.workflowStates.nodes[].name] | join(", ")')"
    jq -nc --arg iid "$ISSUE_ID" --arg sname "$TARGET_STATE_NAME" '{success:false,issue_id:$iid,status_updated:false,comment_created:false,error:("상태 \u0027"+$sname+"\u0027을 찾을 수 없습니다"),error_stage:"status_lookup",summary:"대상 상태를 찾을 수 없음"}'
    exit 1
fi
debug_log "대상 상태 ID 확인: TARGET_STATE_ID=$TARGET_STATE_ID"

# --- Step 2: 이슈 상태 업데이트 ---
debug_log "--- Step 2: 이슈 상태 업데이트 시작 (ISSUE_ID=$ISSUE_ID -> $TARGET_STATE_NAME) ---"
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
        debug_log "이슈 상태 업데이트 성공: $TARGET_STATE_NAME"
    else
        debug_log "WARNING: 이슈 상태 업데이트 실패 (issueUpdate.success=false)"
    fi
else
    debug_log "WARNING: 이슈 상태 업데이트 응답 파싱 실패"
    debug_log "UPDATE_RESPONSE: $UPDATE_RESPONSE"
fi

# --- Step 3: 코멘트 생성 ---
debug_log "--- Step 3: 코멘트 생성 시작 (ISSUE_ID=$ISSUE_ID, 코멘트 길이: ${#COMMENT_BODY}) ---"
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
        debug_log "코멘트 생성 성공: COMMENT_ID=$COMMENT_ID"
    else
        debug_log "WARNING: 코멘트 생성 실패 (commentCreate.success=false)"
    fi
else
    debug_log "WARNING: 코멘트 생성 응답 파싱 실패"
    debug_log "COMMENT_RESPONSE: $COMMENT_RESPONSE"
fi

# 코멘트 생성 실패 시 (상태 업데이트는 성공했을 수 있음)
if [[ "$COMMENT_CREATED" == "false" ]]; then
    ERROR_MSG=$(echo "$COMMENT_RESPONSE" | jq -r '.errors[0].message // "코멘트 생성 실패"' 2>/dev/null || echo "코멘트 생성 실패")
    debug_log "ERROR: 코멘트 생성 최종 실패 - $ERROR_MSG (상태 업데이트=$STATUS_UPDATED)"
    jq -nc --arg iid "$ISSUE_ID" --argjson su "$STATUS_UPDATED" --arg ns "$TARGET_STATE_NAME" --arg err "$ERROR_MSG" '{success:false,issue_id:$iid,status_updated:$su,new_status:$ns,comment_created:false,error:$err,error_stage:"comment_create",summary:("코멘트 생성 실패: "+$err)}'
    exit 0
fi

# --- 최종 결과 출력 ---
debug_log "=== 최종 결과: success=true, status_updated=$STATUS_UPDATED, new_status=$TARGET_STATE_NAME, comment_id=$COMMENT_ID ==="
debug_log "=== linear-status-report.sh 완료 ==="
jq -nc --arg iid "$ISSUE_ID" --argjson su "$STATUS_UPDATED" --arg ns "$TARGET_STATE_NAME" --arg cid "$COMMENT_ID" '{success:true,issue_id:$iid,status_updated:$su,new_status:$ns,comment_created:true,comment_id:$cid,summary:("이슈 상태가 "+$ns+"(으)로 업데이트되고 보고 코멘트가 작성되었습니다.")}'
