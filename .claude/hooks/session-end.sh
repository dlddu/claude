#!/bin/bash

INPUT="$(cat)"
SESSION_ID="$(echo "$INPUT" | jq -r .session_id)"
TRANSCRIPT_FILE="$(echo "$INPUT" | jq -r .transcript_path)"

if [[ -z "$SESSION_ID" || "$SESSION_ID" == "null" ]]; then
    echo "Error: session_id is missing"
    echo "Usage: echo '{\"session_id\": \"...\", \"transcript_path\": \"/path/to/file.jsonl\"}' | $0"
    exit 1
fi

if [[ -z "$TRANSCRIPT_FILE" || "$TRANSCRIPT_FILE" == "null" || ! -f "$TRANSCRIPT_FILE" ]]; then
    echo "Error: transcript_path is missing or file does not exist"
    echo "Usage: echo '{\"session_id\": \"...\", \"transcript_path\": \"/path/to/file.jsonl\"}' | $0"
    exit 1
fi

# AWS 자격 증명 확인 (access key 또는 instance profile)
if ! aws sts get-caller-identity --region "$AWS_REGION" &>/dev/null; then
    echo "Error: AWS credentials not configured"
    echo "Please set AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY or use an instance profile"
    exit 1
fi

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
DATE_BUCKET="${TIMESTAMP:0:10}"

# 임시 파일 생성 (스크립트 종료 시 삭제)
ITEM_FILE=$(mktemp)
trap "rm -f $ITEM_FILE" EXIT

# DynamoDB item JSON 생성
jq -n \
    --arg session_id "$SESSION_ID" \
    --arg timestamp "$TIMESTAMP" \
    --arg date_bucket "$DATE_BUCKET" \
    --rawfile transcript "$TRANSCRIPT_FILE" \
    '{
        "session_id": {"S": $session_id},
        "timestamp": {"S": $timestamp},
        "date_bucket": {"S": $date_bucket},
        "transcript": {"S": $transcript}
    }' > "$ITEM_FILE"

aws dynamodb put-item \
    --region "$AWS_REGION" \
    --table-name "$AWS_DYNAMODB_TABLE_NAME" \
    --item "file://$ITEM_FILE"
