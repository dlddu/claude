#!/bin/bash
set -euo pipefail

# test-linear-status-report.sh
# linear-status-report.sh 스크립트에 대한 테스트 코드
#
# 테스트 범위:
#   1. 입력 검증 (필수 필드, JSON 파싱)
#   2. LINEAR_API_KEY 체크
#   3. status → Linear 상태 매핑
#   4. API 호출 (curl mock)
#   5. 특수 문자 / 긴 입력 처리
#   6. 입력 파일 에러 처리

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_SCRIPT="$SCRIPT_DIR/../scripts/linear-status-report.sh"

# 테스트 카운터
PASS=0
FAIL=0
TOTAL=0
FAILED_TESTS=()

# --- 유틸리티 ---

setup() {
    # curl mock 디렉토리 설정
    MOCK_DIR=$(mktemp -d)
    MOCK_CURL="$MOCK_DIR/curl"

    # 입력 파일 디렉토리 설정
    INPUT_DIR=$(mktemp -d)
    INPUT_FILE="$INPUT_DIR/input.json"

    # 기본 curl mock: 성공 응답
    create_curl_mock "default"

    # PATH에 mock 디렉토리 추가 (실제 curl보다 먼저 탐색)
    export ORIGINAL_PATH="$PATH"
    export PATH="$MOCK_DIR:$PATH"
    export LINEAR_API_KEY="test-api-key-123"
}

teardown() {
    export PATH="$ORIGINAL_PATH"
    rm -rf "$MOCK_DIR"
    rm -rf "$INPUT_DIR"
    unset LINEAR_API_KEY 2>/dev/null || true
}

# 입력 파일 작성 헬퍼
write_input() {
    echo "$1" > "$INPUT_FILE"
}

# curl mock 생성 함수
# $1: mock type (default, states_error, update_fail, comment_fail)
create_curl_mock() {
    local mock_type="${1:-default}"

    cat > "$MOCK_CURL" << 'MOCK_SCRIPT'
#!/bin/bash
# curl mock - stdin과 인자를 분석하여 적절한 응답 반환
BODY=""
WRITE_OUT=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -d) BODY="$2"; shift 2 ;;
        -w) WRITE_OUT="$2"; shift 2 ;;
        *) shift ;;
    esac
done

# GraphQL 쿼리에서 작업 유형 판별
if printf '%s' "$BODY" | grep -q "workflowStates"; then
    # Step 1: 상태 조회
MOCK_SCRIPT

    case "$mock_type" in
        states_error)
            cat >> "$MOCK_CURL" << 'EOF'
    echo '{"errors":[{"message":"Authentication failed"}]}'
EOF
            ;;
        state_not_found)
            cat >> "$MOCK_CURL" << 'EOF'
    echo '{"data":{"workflowStates":{"nodes":[{"id":"state-1","name":"Todo","type":"unstarted"},{"id":"state-2","name":"In Progress","type":"started"}]}}}'
EOF
            ;;
        *)
            cat >> "$MOCK_CURL" << 'EOF'
    echo '{"data":{"workflowStates":{"nodes":[{"id":"state-done","name":"Done","type":"completed"},{"id":"state-review","name":"In Review","type":"started"},{"id":"state-todo","name":"Todo","type":"unstarted"}]}}}'
EOF
            ;;
    esac

    cat >> "$MOCK_CURL" << 'MOCK_MIDDLE'
elif printf '%s' "$BODY" | grep -q "issueUpdate"; then
    # Step 2: 이슈 업데이트
MOCK_MIDDLE

    case "$mock_type" in
        update_fail)
            cat >> "$MOCK_CURL" << 'EOF'
    echo '{"data":{"issueUpdate":{"success":false,"issue":null}}}'
EOF
            ;;
        *)
            cat >> "$MOCK_CURL" << 'EOF'
    echo '{"data":{"issueUpdate":{"success":true,"issue":{"id":"issue-1","state":{"name":"Done"}}}}}'
EOF
            ;;
    esac

    cat >> "$MOCK_CURL" << 'MOCK_MIDDLE2'
elif printf '%s' "$BODY" | grep -q "commentCreate"; then
    # Step 3: 코멘트 생성
MOCK_MIDDLE2

    case "$mock_type" in
        comment_fail)
            cat >> "$MOCK_CURL" << 'EOF'
    echo '{"errors":[{"message":"Comment creation failed"}]}'
EOF
            ;;
        *)
            cat >> "$MOCK_CURL" << 'EOF'
    echo '{"data":{"commentCreate":{"success":true,"comment":{"id":"comment-123"}}}}'
EOF
            ;;
    esac

    cat >> "$MOCK_CURL" << 'MOCK_END'
else
    echo '{"errors":[{"message":"Unknown query"}]}'
fi

# -w 옵션 처리 (예: '\n%{http_code}' → '\n200')
if [[ -n "$WRITE_OUT" ]]; then
    printf '%s' "$WRITE_OUT" | sed 's/%{http_code}/200/g'
fi
MOCK_END

    chmod +x "$MOCK_CURL"
}

# JSON 출력에서 특정 필드 값 확인
# $1: 테스트 이름
# $2: jq expression
# $3: 예상 값
# $4: 실제 출력
assert_json_field() {
    local test_name="$1"
    local jq_expr="$2"
    local expected="$3"
    local output="$4"

    TOTAL=$((TOTAL + 1))

    local actual
    actual=$(printf '%s' "$output" | jq -r "$jq_expr" 2>/dev/null || echo "__JQ_PARSE_ERROR__")

    if [[ "$actual" == "$expected" ]]; then
        PASS=$((PASS + 1))
        printf "  ✓ %s\n" "$test_name"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$test_name")
        printf "  ✗ %s\n" "$test_name"
        printf "    expected: %s\n" "$expected"
        printf "    actual:   %s\n" "$actual"
    fi
}

# === 테스트 시작 ===

echo "=========================================="
echo " linear-status-report.sh 테스트"
echo "=========================================="
echo ""

# ─────────────────────────────────────────────
# 그룹 1: LINEAR_API_KEY 검증
# ─────────────────────────────────────────────
echo "--- 그룹 1: LINEAR_API_KEY 검증 ---"

setup

# Test 1.1: LINEAR_API_KEY 미설정
TOTAL=$((TOTAL + 1))
write_input '{"issue_id":"id","team_id":"tid","status":"success","comment_body":"body"}'
output=$(unset LINEAR_API_KEY; bash "$TARGET_SCRIPT" --input "$INPUT_FILE" 2>&1) && exit_code=0 || exit_code=$?
if [[ "$exit_code" -eq 1 ]] && printf '%s' "$output" | grep -q "LINEAR_API_KEY"; then
    PASS=$((PASS + 1))
    printf "  ✓ LINEAR_API_KEY 미설정 시 에러 반환\n"
else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("LINEAR_API_KEY 미설정")
    printf "  ✗ LINEAR_API_KEY 미설정 시 에러 반환\n"
    printf "    exit=%s output=%s\n" "$exit_code" "$(printf '%s' "$output" | head -c 200)"
fi

# Test 1.2: LINEAR_API_KEY 빈 문자열
TOTAL=$((TOTAL + 1))
write_input '{"issue_id":"id","team_id":"tid","status":"success","comment_body":"body"}'
output=$(LINEAR_API_KEY="" bash "$TARGET_SCRIPT" --input "$INPUT_FILE" 2>&1) && exit_code=0 || exit_code=$?
if [[ "$exit_code" -eq 1 ]] && printf '%s' "$output" | grep -q "LINEAR_API_KEY"; then
    PASS=$((PASS + 1))
    printf "  ✓ LINEAR_API_KEY 빈 문자열 시 에러 반환\n"
else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("LINEAR_API_KEY 빈 문자열")
    printf "  ✗ LINEAR_API_KEY 빈 문자열 시 에러 반환\n"
    printf "    exit=%s output=%s\n" "$exit_code" "$(printf '%s' "$output" | head -c 200)"
fi

teardown

echo ""

# ─────────────────────────────────────────────
# 그룹 2: 필수 필드 검증
# ─────────────────────────────────────────────
echo "--- 그룹 2: 필수 필드 검증 ---"

setup

# Test 2.1: 모든 필수 필드 존재 → 파싱 성공 (curl mock으로 전체 플로우)
TOTAL=$((TOTAL + 1))
write_input '{"issue_id":"iss-1","team_id":"team-1","status":"success","comment_body":"test body"}'
output=$(bash "$TARGET_SCRIPT" --input "$INPUT_FILE" 2>&1) && exit_code=0 || exit_code=$?
if [[ "$exit_code" -eq 0 ]]; then
    PASS=$((PASS + 1))
    printf "  ✓ 모든 필수 필드 존재 → 성공\n"
else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("모든 필수 필드 존재")
    printf "  ✗ 모든 필수 필드 존재 → 성공\n"
    printf "    exit=%s output=%s\n" "$exit_code" "$(printf '%s' "$output" | head -c 300)"
fi

# Test 2.2: issue_id 누락
TOTAL=$((TOTAL + 1))
write_input '{"team_id":"team-1","status":"success","comment_body":"body"}'
output=$(bash "$TARGET_SCRIPT" --input "$INPUT_FILE" 2>&1) && exit_code=0 || exit_code=$?
if [[ "$exit_code" -eq 1 ]] && printf '%s' "$output" | grep -q "필수 필드 누락"; then
    PASS=$((PASS + 1))
    printf "  ✓ issue_id 누락 시 에러\n"
else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("issue_id 누락")
    printf "  ✗ issue_id 누락 시 에러\n"
    printf "    exit=%s output=%s\n" "$exit_code" "$(printf '%s' "$output" | head -c 200)"
fi

# Test 2.3: team_id 누락
TOTAL=$((TOTAL + 1))
write_input '{"issue_id":"iss-1","status":"success","comment_body":"body"}'
output=$(bash "$TARGET_SCRIPT" --input "$INPUT_FILE" 2>&1) && exit_code=0 || exit_code=$?
if [[ "$exit_code" -eq 1 ]] && printf '%s' "$output" | grep -q "필수 필드 누락"; then
    PASS=$((PASS + 1))
    printf "  ✓ team_id 누락 시 에러\n"
else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("team_id 누락")
    printf "  ✗ team_id 누락 시 에러\n"
    printf "    exit=%s output=%s\n" "$exit_code" "$(printf '%s' "$output" | head -c 200)"
fi

# Test 2.4: status 누락
TOTAL=$((TOTAL + 1))
write_input '{"issue_id":"iss-1","team_id":"team-1","comment_body":"body"}'
output=$(bash "$TARGET_SCRIPT" --input "$INPUT_FILE" 2>&1) && exit_code=0 || exit_code=$?
if [[ "$exit_code" -eq 1 ]] && printf '%s' "$output" | grep -q "필수 필드 누락"; then
    PASS=$((PASS + 1))
    printf "  ✓ status 누락 시 에러\n"
else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("status 누락")
    printf "  ✗ status 누락 시 에러\n"
    printf "    exit=%s output=%s\n" "$exit_code" "$(printf '%s' "$output" | head -c 200)"
fi

# Test 2.5: comment_body 누락
TOTAL=$((TOTAL + 1))
write_input '{"issue_id":"iss-1","team_id":"team-1","status":"success"}'
output=$(bash "$TARGET_SCRIPT" --input "$INPUT_FILE" 2>&1) && exit_code=0 || exit_code=$?
if [[ "$exit_code" -eq 1 ]] && printf '%s' "$output" | grep -q "필수 필드 누락"; then
    PASS=$((PASS + 1))
    printf "  ✓ comment_body 누락 시 에러\n"
else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("comment_body 누락")
    printf "  ✗ comment_body 누락 시 에러\n"
    printf "    exit=%s output=%s\n" "$exit_code" "$(printf '%s' "$output" | head -c 200)"
fi

# Test 2.6: 빈 입력 파일
TOTAL=$((TOTAL + 1))
printf '' > "$INPUT_FILE"
output=$(bash "$TARGET_SCRIPT" --input "$INPUT_FILE" 2>&1) && exit_code=0 || exit_code=$?
if [[ "$exit_code" -ne 0 ]]; then
    PASS=$((PASS + 1))
    printf "  ✓ 빈 입력 파일 시 에러\n"
else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("빈 입력 파일")
    printf "  ✗ 빈 입력 파일 시 에러 (성공하면 안 됨)\n"
    printf "    exit=%s output=%s\n" "$exit_code" "$(printf '%s' "$output" | head -c 200)"
fi

# Test 2.7: 잘못된 JSON
TOTAL=$((TOTAL + 1))
write_input 'not-a-json'
output=$(bash "$TARGET_SCRIPT" --input "$INPUT_FILE" 2>&1) && exit_code=0 || exit_code=$?
if [[ "$exit_code" -ne 0 ]]; then
    PASS=$((PASS + 1))
    printf "  ✓ 잘못된 JSON 시 에러\n"
else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("잘못된 JSON")
    printf "  ✗ 잘못된 JSON 시 에러 (성공하면 안 됨)\n"
    printf "    exit=%s output=%s\n" "$exit_code" "$(printf '%s' "$output" | head -c 200)"
fi

# Test 2.8: 빈 JSON 객체
TOTAL=$((TOTAL + 1))
write_input '{}'
output=$(bash "$TARGET_SCRIPT" --input "$INPUT_FILE" 2>&1) && exit_code=0 || exit_code=$?
if [[ "$exit_code" -eq 1 ]] && printf '%s' "$output" | grep -q "필수 필드 누락"; then
    PASS=$((PASS + 1))
    printf "  ✓ 빈 JSON 객체 {} 시 필수 필드 누락 에러\n"
else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("빈 JSON 객체")
    printf "  ✗ 빈 JSON 객체 {} 시 필수 필드 누락 에러\n"
    printf "    exit=%s output=%s\n" "$exit_code" "$(printf '%s' "$output" | head -c 200)"
fi

teardown

echo ""

# ─────────────────────────────────────────────
# 그룹 3: status → Linear 상태 매핑
# ─────────────────────────────────────────────
echo "--- 그룹 3: status 매핑 ---"

setup

# Test 3.1: status=success → Done
TOTAL=$((TOTAL + 1))
write_input '{"issue_id":"iss-1","team_id":"team-1","status":"success","comment_body":"body"}'
output=$(bash "$TARGET_SCRIPT" --input "$INPUT_FILE" 2>&1) && exit_code=0 || exit_code=$?
actual_status=$(printf '%s' "$output" | jq -r '.new_status // empty' 2>/dev/null)
if [[ "$actual_status" == "Done" ]]; then
    PASS=$((PASS + 1))
    printf "  ✓ status=success → Done\n"
else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("status=success → Done")
    printf "  ✗ status=success → Done (actual: %s)\n" "$actual_status"
    printf "    output=%s\n" "$(printf '%s' "$output" | head -c 200)"
fi

# Test 3.2: status=blocked → In Review
TOTAL=$((TOTAL + 1))
write_input '{"issue_id":"iss-1","team_id":"team-1","status":"blocked","comment_body":"body"}'
output=$(bash "$TARGET_SCRIPT" --input "$INPUT_FILE" 2>&1) && exit_code=0 || exit_code=$?
actual_status=$(printf '%s' "$output" | jq -r '.new_status // empty' 2>/dev/null)
if [[ "$actual_status" == "In Review" ]]; then
    PASS=$((PASS + 1))
    printf "  ✓ status=blocked → In Review\n"
else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("status=blocked → In Review")
    printf "  ✗ status=blocked → In Review (actual: %s)\n" "$actual_status"
    printf "    output=%s\n" "$(printf '%s' "$output" | head -c 200)"
fi

# Test 3.3: 알 수 없는 status 값 → In Review (기본값)
TOTAL=$((TOTAL + 1))
write_input '{"issue_id":"iss-1","team_id":"team-1","status":"unknown","comment_body":"body"}'
output=$(bash "$TARGET_SCRIPT" --input "$INPUT_FILE" 2>&1) && exit_code=0 || exit_code=$?
actual_status=$(printf '%s' "$output" | jq -r '.new_status // empty' 2>/dev/null)
if [[ "$actual_status" == "In Review" ]]; then
    PASS=$((PASS + 1))
    printf "  ✓ 알 수 없는 status → In Review (fallback)\n"
else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("알 수 없는 status → In Review")
    printf "  ✗ 알 수 없는 status → In Review (actual: %s)\n" "$actual_status"
fi

teardown

echo ""

# ─────────────────────────────────────────────
# 그룹 4: 전체 성공 플로우 출력 검증
# ─────────────────────────────────────────────
echo "--- 그룹 4: 성공 플로우 출력 검증 ---"

setup

write_input '{"issue_id":"iss-1","team_id":"team-1","status":"success","comment_body":"test body"}'
output=$(bash "$TARGET_SCRIPT" --input "$INPUT_FILE" 2>&1) && exit_code=0 || exit_code=$?

assert_json_field "success=true" ".success" "true" "$output"
assert_json_field "issue_id 반환" ".issue_id" "iss-1" "$output"
assert_json_field "status_updated=true" ".status_updated" "true" "$output"
assert_json_field "new_status=Done" ".new_status" "Done" "$output"
assert_json_field "comment_created=true" ".comment_created" "true" "$output"
assert_json_field "comment_id 반환" ".comment_id" "comment-123" "$output"

teardown

echo ""

# ─────────────────────────────────────────────
# 그룹 5: API 에러 시나리오 (curl mock 변형)
# ─────────────────────────────────────────────
echo "--- 그룹 5: API 에러 시나리오 ---"

# Test 5.1: 상태 조회 API 에러
setup
create_curl_mock "states_error"

TOTAL=$((TOTAL + 1))
write_input '{"issue_id":"iss-1","team_id":"team-1","status":"success","comment_body":"body"}'
output=$(bash "$TARGET_SCRIPT" --input "$INPUT_FILE" 2>&1) && exit_code=0 || exit_code=$?
if [[ "$exit_code" -eq 1 ]] && printf '%s' "$output" | grep -q '"error_stage":"status_lookup"'; then
    PASS=$((PASS + 1))
    printf "  ✓ 상태 조회 API 에러 → error_stage=status_lookup\n"
else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("상태 조회 API 에러")
    printf "  ✗ 상태 조회 API 에러\n"
    printf "    exit=%s output=%s\n" "$exit_code" "$(printf '%s' "$output" | head -c 300)"
fi
teardown

# Test 5.2: 대상 상태를 찾을 수 없음
setup
create_curl_mock "state_not_found"

TOTAL=$((TOTAL + 1))
write_input '{"issue_id":"iss-1","team_id":"team-1","status":"success","comment_body":"body"}'
output=$(bash "$TARGET_SCRIPT" --input "$INPUT_FILE" 2>&1) && exit_code=0 || exit_code=$?
if [[ "$exit_code" -eq 1 ]] && printf '%s' "$output" | grep -q "찾을 수 없습니다"; then
    PASS=$((PASS + 1))
    printf "  ✓ Done 상태 없음 → 에러\n"
else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("Done 상태 없음")
    printf "  ✗ Done 상태 없음 → 에러\n"
    printf "    exit=%s output=%s\n" "$exit_code" "$(printf '%s' "$output" | head -c 300)"
fi
teardown

# Test 5.3: 코멘트 생성 실패 (상태 업데이트는 성공)
setup
create_curl_mock "comment_fail"

TOTAL=$((TOTAL + 1))
write_input '{"issue_id":"iss-1","team_id":"team-1","status":"success","comment_body":"body"}'
output=$(bash "$TARGET_SCRIPT" --input "$INPUT_FILE" 2>&1) && exit_code=0 || exit_code=$?
error_stage=$(printf '%s' "$output" | jq -r '.error_stage // empty' 2>/dev/null)
status_updated=$(printf '%s' "$output" | jq -r '.status_updated // empty' 2>/dev/null)
if [[ "$error_stage" == "comment_create" ]] && [[ "$status_updated" == "true" ]]; then
    PASS=$((PASS + 1))
    printf "  ✓ 코멘트 생성 실패 → error_stage=comment_create, status_updated=true\n"
else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("코멘트 생성 실패")
    printf "  ✗ 코멘트 생성 실패\n"
    printf "    error_stage=%s status_updated=%s\n" "$error_stage" "$status_updated"
    printf "    output=%s\n" "$(printf '%s' "$output" | head -c 300)"
fi
teardown

echo ""

# ─────────────────────────────────────────────
# 그룹 6: 특수 문자 및 긴 입력 처리
# ─────────────────────────────────────────────
echo "--- 그룹 6: 특수 문자 / 긴 입력 ---"

setup

# Test 6.1: comment_body에 마크다운, 한국어, 이모지 포함
TOTAL=$((TOTAL + 1))
COMPLEX_BODY='## 작업 완료 보고\n\n**Claude Session ID**: `test-session`\n- ✅ 성공\n- 페이지 렌더링 (3개)\n- [PR #78](https://github.com/test/repo/pull/78)'
INPUT_JSON=$(jq -n \
    --arg iid "iss-complex" \
    --arg tid "team-1" \
    --arg status "success" \
    --arg body "$COMPLEX_BODY" \
    '{issue_id: $iid, team_id: $tid, status: $status, comment_body: $body}')

echo "$INPUT_JSON" > "$INPUT_FILE"
output=$(bash "$TARGET_SCRIPT" --input "$INPUT_FILE" 2>&1) && exit_code=0 || exit_code=$?
if [[ "$exit_code" -eq 0 ]] && printf '%s' "$output" | jq -e '.success == true' > /dev/null 2>&1; then
    PASS=$((PASS + 1))
    printf "  ✓ 마크다운 + 한국어 + 이모지 comment_body 처리 성공\n"
else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("마크다운/한국어/이모지")
    printf "  ✗ 마크다운 + 한국어 + 이모지 comment_body 처리\n"
    printf "    exit=%s output=%s\n" "$exit_code" "$(printf '%s' "$output" | head -c 300)"
fi

# Test 6.2: comment_body에 JSON 특수 문자 (큰따옴표, 백슬래시)
TOTAL=$((TOTAL + 1))
TRICKY_BODY='Body with "quotes" and backslash \\ and tab\t end'
INPUT_JSON=$(jq -n \
    --arg iid "iss-tricky" \
    --arg tid "team-1" \
    --arg status "success" \
    --arg body "$TRICKY_BODY" \
    '{issue_id: $iid, team_id: $tid, status: $status, comment_body: $body}')

echo "$INPUT_JSON" > "$INPUT_FILE"
output=$(bash "$TARGET_SCRIPT" --input "$INPUT_FILE" 2>&1) && exit_code=0 || exit_code=$?
if [[ "$exit_code" -eq 0 ]] && printf '%s' "$output" | jq -e '.success == true' > /dev/null 2>&1; then
    PASS=$((PASS + 1))
    printf "  ✓ JSON 특수 문자 (따옴표, 백슬래시) 처리 성공\n"
else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("JSON 특수 문자")
    printf "  ✗ JSON 특수 문자 처리\n"
    printf "    exit=%s output=%s\n" "$exit_code" "$(printf '%s' "$output" | head -c 300)"
fi

# Test 6.3: 긴 comment_body (실제 실패 사례와 유사)
TOTAL=$((TOTAL + 1))
LONG_BODY="## 작업 완료 보고

**Claude Session ID**: \`5c1b5920-9a7e-46d6-9a14-b8c301bcd26e\`
**Routing Decision**: \`developer\` (workflow: e2e-test, confidence: high)

### 작업 분석 결과
- **작업 유형**: E2E 테스트 작성
- **복잡도**: 중간
- **범위**: 단일 e2e 테스트 파일 생성 (e2e/debug-page.spec.ts), 12개의 skip된 테스트 케이스 작성

### 수행한 작업
Debug 페이지(/debug)의 E2E 테스트를 skip 상태로 12개 작성했습니다.
- 페이지 렌더링 (3개)
- API 로그 표시 (2개)
- 상세 뷰 인터랙션 (4개)
- 클립보드 복사 (2개)
- 빈 상태 (1개)

### 변경 사항
- \`e2e/debug-page.spec.ts\` (신규, 411줄)

### PR 정보
- **PR URL**: [#78](https://github.com/dlddu/kubernetes-dashboard/pull/78)
- **Branch**: \`dld-347-작업-4-1-e2e-테스트-debug-페이지-skipped\`
- **Status**: ✅ 자동 병합 완료

### 테스트 결과
- **총 E2E 테스트**: 12개
- **Skip된 테스트**: 12개
- **CI 검증**: ✅ Passed

### PR 검토 점수
- **전체 점수**: 94/100
- **요구사항 커버리지**: 98%
- **테스트 품질**: 92%
- **하드코딩 검사**: 85%

### 라우팅 결정 사유
작업이 Playwright 기반의 E2E 테스트 작성이며, 이는 명확한 코드 생성 작업입니다. Repository는 kubernetes-dashboard(웹 애플리케이션)로 macOS 네이티브 프로젝트가 아닙니다."

INPUT_JSON=$(jq -n \
    --arg iid "eb074673-17d9-4da2-88fc-853d3dbc3265" \
    --arg tid "59d63b86-2d3d-4e18-a017-820d1c2d7e88" \
    --arg status "success" \
    --arg body "$LONG_BODY" \
    '{issue_id: $iid, team_id: $tid, status: $status, comment_body: $body}')

echo "$INPUT_JSON" > "$INPUT_FILE"
output=$(bash "$TARGET_SCRIPT" --input "$INPUT_FILE" 2>&1) && exit_code=0 || exit_code=$?
if [[ "$exit_code" -eq 0 ]] && printf '%s' "$output" | jq -e '.success == true' > /dev/null 2>&1; then
    PASS=$((PASS + 1))
    printf "  ✓ 긴 comment_body (실제 실패 사례 재현) 처리 성공\n"
else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("긴 comment_body")
    printf "  ✗ 긴 comment_body 처리\n"
    printf "    exit=%s output=%s\n" "$exit_code" "$(printf '%s' "$output" | head -c 300)"
fi

teardown

echo ""

# ─────────────────────────────────────────────
# 그룹 7: 다양한 JSON 형식 파일 입력
# ─────────────────────────────────────────────
echo "--- 그룹 7: 다양한 JSON 형식 파일 입력 ---"

setup

# Test 7.1: 멀티라인 JSON 파일
TOTAL=$((TOTAL + 1))
cat > "$INPUT_FILE" << 'EOF'
{
  "issue_id": "eb074673-17d9-4da2-88fc-853d3dbc3265",
  "team_id": "59d63b86-2d3d-4e18-a017-820d1c2d7e88",
  "status": "success",
  "comment_body": "## 작업 완료 보고\n\n**Claude Session ID**: `test`"
}
EOF
output=$(bash "$TARGET_SCRIPT" --input "$INPUT_FILE" 2>&1) && exit_code=0 || exit_code=$?
if [[ "$exit_code" -eq 0 ]] && printf '%s' "$output" | jq -e '.success == true' > /dev/null 2>&1; then
    PASS=$((PASS + 1))
    printf "  ✓ 멀티라인 JSON 파일 입력 성공\n"
else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("멀티라인 JSON 파일")
    printf "  ✗ 멀티라인 JSON 파일 입력\n"
    printf "    exit=%s output=%s\n" "$exit_code" "$(printf '%s' "$output" | head -c 300)"
fi

# Test 7.2: comment_body에 literal \n (JSON escape) 포함
TOTAL=$((TOTAL + 1))
write_input '{"issue_id":"iss-1","team_id":"team-1","status":"success","comment_body":"line1\\nline2\\nline3"}'
output=$(bash "$TARGET_SCRIPT" --input "$INPUT_FILE" 2>&1) && exit_code=0 || exit_code=$?
if [[ "$exit_code" -eq 0 ]] && printf '%s' "$output" | jq -e '.success == true' > /dev/null 2>&1; then
    PASS=$((PASS + 1))
    printf "  ✓ JSON escape \\\\n 포함 comment_body 처리 성공\n"
else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("JSON escape \\n")
    printf "  ✗ JSON escape \\\\n 포함 comment_body 처리\n"
    printf "    exit=%s output=%s\n" "$exit_code" "$(printf '%s' "$output" | head -c 300)"
fi

# Test 7.3: heredoc으로 파일 작성 후 입력
TOTAL=$((TOTAL + 1))
cat > "$INPUT_FILE" <<'HEREDOC_INPUT'
{
  "issue_id": "iss-heredoc",
  "team_id": "team-1",
  "status": "success",
  "comment_body": "heredoc test body"
}
HEREDOC_INPUT
output=$(bash "$TARGET_SCRIPT" --input "$INPUT_FILE" 2>&1) && exit_code=0 || exit_code=$?
if [[ "$exit_code" -eq 0 ]] && printf '%s' "$output" | jq -e '.success == true' > /dev/null 2>&1; then
    PASS=$((PASS + 1))
    printf "  ✓ heredoc으로 파일 작성 후 입력 성공\n"
else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("heredoc 파일 입력")
    printf "  ✗ heredoc으로 파일 작성 후 입력\n"
    printf "    exit=%s output=%s\n" "$exit_code" "$(printf '%s' "$output" | head -c 300)"
fi

# Test 7.4: 실제 실패 사례의 정확한 바이트 재현
TOTAL=$((TOTAL + 1))
EXACT_CMD='{"issue_id":"eb074673","team_id":"59d63b86","status":"success","comment_body":"## 보고\\n\\n**Session**: test\\n### 결과\\n- 항목1\\n- 항목2"}'
echo "$EXACT_CMD" > "$INPUT_FILE"
output=$(bash "$TARGET_SCRIPT" --input "$INPUT_FILE" 2>&1) && exit_code=0 || exit_code=$?
if [[ "$exit_code" -eq 0 ]]; then
    PASS=$((PASS + 1))
    printf "  ✓ 원본 실패 사례 재현 → 성공 (jq가 \\\\n을 파싱)\n"
else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("원본 실패 재현")
    printf "  ✗ 원본 실패 사례 재현\n"
    printf "    exit=%s output=%s\n" "$exit_code" "$(printf '%s' "$output" | head -c 300)"
fi

teardown

echo ""

# ─────────────────────────────────────────────
# 그룹 8: 출력 JSON 형식 검증
# ─────────────────────────────────────────────
echo "--- 그룹 8: 출력 JSON 유효성 ---"

setup

# Test 8.1: 성공 시 출력이 유효한 JSON
TOTAL=$((TOTAL + 1))
write_input '{"issue_id":"iss-1","team_id":"team-1","status":"success","comment_body":"body"}'
output=$(bash "$TARGET_SCRIPT" --input "$INPUT_FILE" 2>&1) && exit_code=0 || exit_code=$?
if printf '%s' "$output" | jq empty 2>/dev/null; then
    PASS=$((PASS + 1))
    printf "  ✓ 성공 시 유효한 JSON 출력\n"
else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("성공 시 JSON 유효성")
    printf "  ✗ 성공 시 유효한 JSON 출력\n"
    printf "    output=%s\n" "$(printf '%s' "$output" | head -c 200)"
fi

teardown

# Test 8.2: 실패 시 출력이 유효한 JSON
setup
TOTAL=$((TOTAL + 1))
write_input '{"issue_id":"iss-1","team_id":"team-1","status":"success"}'
output=$(bash "$TARGET_SCRIPT" --input "$INPUT_FILE" 2>&1) && exit_code=0 || exit_code=$?
if printf '%s' "$output" | jq empty 2>/dev/null; then
    PASS=$((PASS + 1))
    printf "  ✓ 실패 시 유효한 JSON 출력\n"
else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("실패 시 JSON 유효성")
    printf "  ✗ 실패 시 유효한 JSON 출력\n"
    printf "    output=%s\n" "$(printf '%s' "$output" | head -c 200)"
fi
teardown

# Test 8.3: LINEAR_API_KEY 에러 시 유효한 JSON
TOTAL=$((TOTAL + 1))
INPUT_DIR_8=$(mktemp -d)
echo '{}' > "$INPUT_DIR_8/input.json"
output=$(unset LINEAR_API_KEY; bash "$TARGET_SCRIPT" --input "$INPUT_DIR_8/input.json" 2>&1) && exit_code=0 || exit_code=$?
if printf '%s' "$output" | jq empty 2>/dev/null; then
    PASS=$((PASS + 1))
    printf "  ✓ API KEY 에러 시 유효한 JSON 출력\n"
else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("API KEY 에러 시 JSON 유효성")
    printf "  ✗ API KEY 에러 시 유효한 JSON 출력\n"
    printf "    output=%s\n" "$(printf '%s' "$output" | head -c 200)"
fi
rm -rf "$INPUT_DIR_8"

echo ""

# ─────────────────────────────────────────────
# 그룹 9: 엣지 케이스
# ─────────────────────────────────────────────
echo "--- 그룹 9: 엣지 케이스 ---"

setup

# Test 9.1: null 값이 포함된 필드
TOTAL=$((TOTAL + 1))
write_input '{"issue_id":null,"team_id":"team-1","status":"success","comment_body":"body"}'
output=$(bash "$TARGET_SCRIPT" --input "$INPUT_FILE" 2>&1) && exit_code=0 || exit_code=$?
if [[ "$exit_code" -eq 1 ]] && printf '%s' "$output" | grep -q "필수 필드 누락"; then
    PASS=$((PASS + 1))
    printf "  ✓ null 값 필드 → 필수 필드 누락\n"
else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("null 값 필드")
    printf "  ✗ null 값 필드\n"
    printf "    exit=%s output=%s\n" "$exit_code" "$(printf '%s' "$output" | head -c 200)"
fi

# Test 9.2: 빈 문자열 값
TOTAL=$((TOTAL + 1))
write_input '{"issue_id":"","team_id":"team-1","status":"success","comment_body":"body"}'
output=$(bash "$TARGET_SCRIPT" --input "$INPUT_FILE" 2>&1) && exit_code=0 || exit_code=$?
if [[ "$exit_code" -eq 1 ]] && printf '%s' "$output" | grep -q "필수 필드 누락"; then
    PASS=$((PASS + 1))
    printf "  ✓ 빈 문자열 필드 → 필수 필드 누락\n"
else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("빈 문자열 필드")
    printf "  ✗ 빈 문자열 필드\n"
    printf "    exit=%s output=%s\n" "$exit_code" "$(printf '%s' "$output" | head -c 200)"
fi

# Test 9.3: 추가 필드가 있어도 정상 동작
TOTAL=$((TOTAL + 1))
write_input '{"issue_id":"iss-1","team_id":"team-1","status":"success","comment_body":"body","extra_field":"extra"}'
output=$(bash "$TARGET_SCRIPT" --input "$INPUT_FILE" 2>&1) && exit_code=0 || exit_code=$?
if [[ "$exit_code" -eq 0 ]] && printf '%s' "$output" | jq -e '.success == true' > /dev/null 2>&1; then
    PASS=$((PASS + 1))
    printf "  ✓ 추가 필드 있어도 정상 동작\n"
else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("추가 필드")
    printf "  ✗ 추가 필드 있어도 정상 동작\n"
    printf "    exit=%s output=%s\n" "$exit_code" "$(printf '%s' "$output" | head -c 200)"
fi

# Test 9.4: comment_body에 single quote 포함 (jq로 안전하게 이스케이프 되는지)
TOTAL=$((TOTAL + 1))
INPUT_JSON=$(jq -n \
    --arg iid "iss-quote" \
    --arg tid "team-1" \
    --arg status "success" \
    --arg body "It's a test with 'single quotes'" \
    '{issue_id: $iid, team_id: $tid, status: $status, comment_body: $body}')
echo "$INPUT_JSON" > "$INPUT_FILE"
output=$(bash "$TARGET_SCRIPT" --input "$INPUT_FILE" 2>&1) && exit_code=0 || exit_code=$?
if [[ "$exit_code" -eq 0 ]] && printf '%s' "$output" | jq -e '.success == true' > /dev/null 2>&1; then
    PASS=$((PASS + 1))
    printf "  ✓ single quote 포함 comment_body 처리 성공\n"
else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("single quote comment_body")
    printf "  ✗ single quote 포함 comment_body 처리\n"
    printf "    exit=%s output=%s\n" "$exit_code" "$(printf '%s' "$output" | head -c 300)"
fi

teardown

echo ""

# ─────────────────────────────────────────────
# 그룹 10: [보안] 출력 JSON injection 검증
# ─────────────────────────────────────────────
echo "--- 그룹 10: 출력 JSON injection 검증 ---"

setup

# Test 10.1: API 에러 메시지에 큰따옴표 포함 시 출력 JSON 유효성
cat > "$MOCK_CURL" << 'EOF'
#!/bin/bash
BODY=""
WRITE_OUT=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -d) BODY="$2"; shift 2 ;;
        -w) WRITE_OUT="$2"; shift 2 ;;
        *) shift ;;
    esac
done
if printf '%s' "$BODY" | grep -q "workflowStates"; then
    echo '{"errors":[{"message":"Invalid \"team_id\" format: expected UUID"}]}'
else
    echo '{"errors":[{"message":"Unknown"}]}'
fi
if [[ -n "$WRITE_OUT" ]]; then
    printf '%s' "$WRITE_OUT" | sed 's/%{http_code}/200/g'
fi
EOF
chmod +x "$MOCK_CURL"

TOTAL=$((TOTAL + 1))
write_input '{"issue_id":"iss-1","team_id":"team-1","status":"success","comment_body":"body"}'
output=$(bash "$TARGET_SCRIPT" --input "$INPUT_FILE" 2>&1) && exit_code=0 || exit_code=$?
if printf '%s' "$output" | jq empty 2>/dev/null; then
    PASS=$((PASS + 1))
    printf "  ✓ API 에러 메시지에 큰따옴표 포함 → 출력 JSON 유효\n"
else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("API 에러 큰따옴표 JSON injection")
    printf "  ✗ API 에러 메시지에 큰따옴표 포함 → 출력 JSON 깨짐 (injection 취약점)\n"
    printf "    output=%s\n" "$(printf '%s' "$output" | head -c 300)"
fi

teardown

# Test 10.2: issue_id에 큰따옴표가 포함된 경우
setup

TOTAL=$((TOTAL + 1))
INPUT_JSON=$(jq -n \
    --arg iid 'iss-"inject' \
    --arg tid "team-1" \
    --arg status "success" \
    --arg body "body" \
    '{issue_id: $iid, team_id: $tid, status: $status, comment_body: $body}')
echo "$INPUT_JSON" > "$INPUT_FILE"
output=$(bash "$TARGET_SCRIPT" --input "$INPUT_FILE" 2>&1) && exit_code=0 || exit_code=$?
if printf '%s' "$output" | jq empty 2>/dev/null; then
    PASS=$((PASS + 1))
    printf "  ✓ issue_id에 큰따옴표 포함 → 출력 JSON 유효 (injection 방지됨)\n"
else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("issue_id 큰따옴표 injection")
    printf "  ✗ issue_id에 큰따옴표 포함 → 출력 JSON 깨짐 (injection 취약점)\n"
    printf "    output=%s\n" "$(printf '%s' "$output" | head -c 300)"
fi

teardown

echo ""

# ─────────────────────────────────────────────
# 그룹 11: 입력 파일 에러 처리
# ─────────────────────────────────────────────
echo "--- 그룹 11: 입력 파일 에러 처리 ---"

setup

# Test 11.1: --input 인자 없이 실행 → 에러
TOTAL=$((TOTAL + 1))
output=$(bash "$TARGET_SCRIPT" 2>&1) && exit_code=0 || exit_code=$?
if [[ "$exit_code" -eq 1 ]] && printf '%s' "$output" | grep -q "input"; then
    PASS=$((PASS + 1))
    printf "  ✓ --input 인자 없이 실행 → 에러 (exit=%s)\n" "$exit_code"
else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("--input 인자 없음")
    printf "  ✗ --input 인자 없이 실행 → 에러\n"
    printf "    exit=%s output=%s\n" "$exit_code" "$(printf '%s' "$output" | head -c 200)"
fi

# Test 11.2: 존재하지 않는 파일 경로 → 에러
TOTAL=$((TOTAL + 1))
output=$(bash "$TARGET_SCRIPT" --input "/nonexistent/path/input.json" 2>&1) && exit_code=0 || exit_code=$?
if [[ "$exit_code" -eq 1 ]] && printf '%s' "$output" | grep -q "찾을 수 없습니다"; then
    PASS=$((PASS + 1))
    printf "  ✓ 존재하지 않는 파일 → 에러\n"
else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("존재하지 않는 파일")
    printf "  ✗ 존재하지 않는 파일 → 에러\n"
    printf "    exit=%s output=%s\n" "$exit_code" "$(printf '%s' "$output" | head -c 200)"
fi

# Test 11.3: 알 수 없는 옵션 → 에러
TOTAL=$((TOTAL + 1))
output=$(bash "$TARGET_SCRIPT" --unknown foo 2>&1) && exit_code=0 || exit_code=$?
if [[ "$exit_code" -eq 1 ]] && printf '%s' "$output" | grep -q "알 수 없는 옵션"; then
    PASS=$((PASS + 1))
    printf "  ✓ 알 수 없는 옵션 → 에러\n"
else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("알 수 없는 옵션")
    printf "  ✗ 알 수 없는 옵션 → 에러\n"
    printf "    exit=%s output=%s\n" "$exit_code" "$(printf '%s' "$output" | head -c 200)"
fi

# Test 11.4: null JSON 파일 ("null" 문자열)
TOTAL=$((TOTAL + 1))
write_input 'null'
output=$(bash "$TARGET_SCRIPT" --input "$INPUT_FILE" 2>&1) && exit_code=0 || exit_code=$?
if [[ "$exit_code" -eq 1 ]] && printf '%s' "$output" | grep -q "필수 필드 누락"; then
    PASS=$((PASS + 1))
    printf "  ✓ JSON null 입력 파일 → 필수 필드 누락\n"
else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("JSON null 입력 파일")
    printf "  ✗ JSON null 입력 파일\n"
    printf "    exit=%s output=%s\n" "$exit_code" "$(printf '%s' "$output" | head -c 200)"
fi

# Test 11.5: 뉴라인만 있는 파일
TOTAL=$((TOTAL + 1))
printf '\n\n\n' > "$INPUT_FILE"
output=$(bash "$TARGET_SCRIPT" --input "$INPUT_FILE" 2>&1) && exit_code=0 || exit_code=$?
if [[ "$exit_code" -ne 0 ]]; then
    PASS=$((PASS + 1))
    printf "  ✓ 뉴라인만 있는 파일 → 에러\n"
else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("뉴라인만 파일")
    printf "  ✗ 뉴라인만 있는 파일 → 성공하면 안 됨\n"
fi

# Test 11.6: JSON 배열 입력 파일 (객체가 아닌)
TOTAL=$((TOTAL + 1))
write_input '[{"issue_id":"iss-1"}]'
output=$(bash "$TARGET_SCRIPT" --input "$INPUT_FILE" 2>&1) && exit_code=0 || exit_code=$?
if [[ "$exit_code" -ne 0 ]]; then
    PASS=$((PASS + 1))
    printf "  ✓ JSON 배열 입력 파일 → 에러\n"
else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("JSON 배열 입력 파일")
    printf "  ✗ JSON 배열 입력 파일 → 성공하면 안 됨\n"
fi

# Test 11.7: 빈 파일 → 에러 JSON에 파일 경로 포함
TOTAL=$((TOTAL + 1))
printf '' > "$INPUT_FILE"
output=$(bash "$TARGET_SCRIPT" --input "$INPUT_FILE" 2>&1) && exit_code=0 || exit_code=$?
if [[ "$exit_code" -eq 1 ]] && printf '%s' "$output" | grep -q "비어 있습니다"; then
    PASS=$((PASS + 1))
    printf "  ✓ 빈 파일 → 에러 메시지에 '비어 있습니다' 포함\n"
else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("빈 파일 에러 메시지")
    printf "  ✗ 빈 파일 → 에러 메시지 확인 실패\n"
    printf "    exit=%s output=%s\n" "$exit_code" "$(printf '%s' "$output" | head -c 200)"
fi

# Test 11.8: --input 미지정 시 출력이 유효한 JSON
TOTAL=$((TOTAL + 1))
output=$(bash "$TARGET_SCRIPT" 2>&1) && exit_code=0 || exit_code=$?
if printf '%s' "$output" | jq empty 2>/dev/null; then
    PASS=$((PASS + 1))
    printf "  ✓ --input 미지정 에러 출력이 유효한 JSON\n"
else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("--input 미지정 JSON 유효성")
    printf "  ✗ --input 미지정 에러 출력이 유효한 JSON이 아님\n"
    printf "    output=%s\n" "$(printf '%s' "$output" | head -c 200)"
fi

teardown

echo ""

# === 결과 요약 ===
echo "=========================================="
echo " 테스트 결과"
echo "=========================================="
echo "  총 테스트: $TOTAL"
echo "  성공:     $PASS"
echo "  실패:     $FAIL"
echo ""

if [[ ${#FAILED_TESTS[@]} -gt 0 ]]; then
    echo "  실패한 테스트:"
    for t in "${FAILED_TESTS[@]}"; do
        echo "    - $t"
    done
    echo ""
fi

if [[ "$FAIL" -eq 0 ]]; then
    echo "  ✅ 모든 테스트 통과!"
    exit 0
else
    echo "  ❌ $FAIL개 테스트 실패"
    exit 1
fi
