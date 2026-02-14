#!/bin/bash
set -euo pipefail

# auto-merge.sh
# pr-reviewer JSON을 stdin으로 받아 점수를 파싱하고, 임계값 이상이면 PR을 머지합니다.
#
# 사용법:
#   echo '<pr-reviewer JSON>' | ./scripts/auto-merge.sh --repo /tmp/repo --pr 123 --threshold 90
#
# 종료 코드:
#   0: 정상 완료 (머지 성공 또는 블로킹 판정)
#   1: 에러 (파싱 실패, 리뷰 실패 등)

REPO_PATH=""
PR_NUMBER=""
THRESHOLD=90

# 인자 파싱
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo) REPO_PATH="$2"; shift 2 ;;
        --pr) PR_NUMBER="$2"; shift 2 ;;
        --threshold) THRESHOLD="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$REPO_PATH" || -z "$PR_NUMBER" ]]; then
    echo '{"status":"error","reason":"--repo and --pr are required"}' >&2
    exit 1
fi

# stdin에서 pr-reviewer JSON 읽기
INPUT=$(cat)

# JSON 파싱: jq 사용, 실패 시 grep fallback
parse_score() {
    local score

    # jq로 파싱 시도
    if score=$(echo "$INPUT" | jq -r '.review_result.total_score // empty' 2>/dev/null) && [[ -n "$score" ]]; then
        echo "$score"
        return 0
    fi

    # fallback: grep으로 total_score 추출
    if score=$(echo "$INPUT" | grep -oP '"total_score"\s*:\s*\K[0-9]+' | head -1) && [[ -n "$score" ]]; then
        echo "$score"
        return 0
    fi

    return 1
}

# success 필드 확인
check_success=$(echo "$INPUT" | jq -r '.success // empty' 2>/dev/null || true)
if [[ "$check_success" == "false" ]]; then
    error_msg=$(echo "$INPUT" | jq -r '.error // "unknown error"' 2>/dev/null || echo "unknown error")
    cat <<EOF
{"status":"blocked","total_score":null,"merged":false,"blocking_stage":"pr_review","blocking_reason":"리뷰 실패: $error_msg"}
EOF
    exit 1
fi

# 점수 추출
if ! SCORE=$(parse_score); then
    cat <<EOF
{"status":"blocked","total_score":null,"merged":false,"blocking_stage":"pr_review","blocking_reason":"pr-reviewer 출력에서 total_score를 파싱할 수 없습니다"}
EOF
    exit 1
fi

# 점수 비교 및 머지 실행
if [[ "$SCORE" -ge "$THRESHOLD" ]]; then
    cd "$REPO_PATH"
    if merge_output=$(gh pr merge "$PR_NUMBER" --squash --delete-branch 2>&1); then
        cat <<EOF
{"status":"success","total_score":$SCORE,"merged":true,"merge_method":"squash","blocking_stage":null,"blocking_reason":null}
EOF
    else
        cat <<EOF
{"status":"blocked","total_score":$SCORE,"merged":false,"blocking_stage":"auto_merge","blocking_reason":"머지 실패: $merge_output"}
EOF
    fi
else
    cat <<EOF
{"status":"blocked","total_score":$SCORE,"merged":false,"blocking_stage":"pr_review","blocking_reason":"리뷰 점수 ${SCORE}점으로 임계값(${THRESHOLD})점 미만. 수동 검토 필요."}
EOF
fi
