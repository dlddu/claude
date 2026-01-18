#!/bin/bash

# Skip in devcontainer environment
if [[ "$SKIP_SESSION_HOOKS" == "true" ]]; then
    exit 0
fi

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

# Subagent 디렉토리 경로 도출
SESSION_DIR="${TRANSCRIPT_FILE%.jsonl}"
SUBAGENTS_DIR="$SESSION_DIR/subagents"

# 메인 transcript S3 업로드
aws s3 cp "$TRANSCRIPT_FILE" "s3://${AWS_S3_BUCKET_NAME}/${SESSION_ID}.jsonl" --region "$AWS_REGION"

# subagents 폴더가 있으면 그대로 업로드
if [[ -d "$SUBAGENTS_DIR" ]]; then
    aws s3 cp "$SUBAGENTS_DIR" "s3://${AWS_S3_BUCKET_NAME}/${SESSION_ID}/" --recursive --region "$AWS_REGION"
fi
