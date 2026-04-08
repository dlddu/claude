#!/bin/bash

# Transcript Uploader Sidecar
# Uploads transcript files to S3 every 30 seconds
# Handles SIGTERM for graceful shutdown (K8s native sidecar)

LOG_PREFIX="[transcript-uploader]"
UPLOAD_INTERVAL=30
CLAUDE_DIR="/root/.claude"
SHUTDOWN_REQUESTED=false
SLEEP_PID=""

# Base credentials (saved before assuming role)
BASE_AWS_ACCESS_KEY_ID=""
BASE_AWS_SECRET_ACCESS_KEY=""
# Epoch seconds when assumed-role credentials expire (0 = not yet assumed)
ROLE_CREDS_EXPIRES_AT=0
# Refresh assumed credentials this many seconds before expiry
ROLE_CREDS_REFRESH_BUFFER=300

log() {
    echo "$LOG_PREFIX $(date -u +"%Y-%m-%dT%H:%M:%SZ") $1"
}

log_error() {
    echo "$LOG_PREFIX $(date -u +"%Y-%m-%dT%H:%M:%SZ") ERROR: $1" >&2
}

# Graceful shutdown handler
shutdown_handler() {
    log "Received SIGTERM, performing final upload..."
    SHUTDOWN_REQUESTED=true
    # Kill sleep process to exit immediately
    [[ -n "$SLEEP_PID" ]] && kill "$SLEEP_PID" 2>/dev/null
}

check_aws_credentials() {
    if ! aws sts get-caller-identity --region "$AWS_REGION" &>/dev/null; then
        log_error "AWS credentials not configured"
        return 1
    fi
    return 0
}

# Assume the configured IAM role and export temporary credentials.
# No-op if AWS_ASSUME_ROLE_ARN is unset. Caches until near expiry.
assume_role() {
    [[ -z "${AWS_ASSUME_ROLE_ARN:-}" ]] && return 0

    # Skip if current temporary credentials are still valid
    local now
    now=$(date +%s)
    if (( now < ROLE_CREDS_EXPIRES_AT - ROLE_CREDS_REFRESH_BUFFER )); then
        return 0
    fi

    # Restore base credentials to make the assume-role call
    export AWS_ACCESS_KEY_ID="$BASE_AWS_ACCESS_KEY_ID"
    export AWS_SECRET_ACCESS_KEY="$BASE_AWS_SECRET_ACCESS_KEY"
    unset AWS_SESSION_TOKEN

    local creds_json
    if ! creds_json=$(aws sts assume-role \
        --role-arn "$AWS_ASSUME_ROLE_ARN" \
        --role-session-name "transcript-uploader-$$" \
        --region "$AWS_REGION" 2>/dev/null); then
        log_error "Failed to assume role: $AWS_ASSUME_ROLE_ARN"
        return 1
    fi

    export AWS_ACCESS_KEY_ID
    export AWS_SECRET_ACCESS_KEY
    export AWS_SESSION_TOKEN
    AWS_ACCESS_KEY_ID=$(echo "$creds_json" | jq -r '.Credentials.AccessKeyId')
    AWS_SECRET_ACCESS_KEY=$(echo "$creds_json" | jq -r '.Credentials.SecretAccessKey')
    AWS_SESSION_TOKEN=$(echo "$creds_json" | jq -r '.Credentials.SessionToken')

    local expiration
    expiration=$(echo "$creds_json" | jq -r '.Credentials.Expiration')
    ROLE_CREDS_EXPIRES_AT=$(date -d "$expiration" +%s 2>/dev/null || echo 0)

    log "Assumed role (expires at $expiration)"
    return 0
}

build_s3_path() {
    local suffix="$1"
    if [[ -n "${AWS_S3_PATH_PREFIX:-}" ]]; then
        echo "s3://${AWS_S3_BUCKET_NAME}/${AWS_S3_PATH_PREFIX}/${suffix}"
    else
        echo "s3://${AWS_S3_BUCKET_NAME}/${suffix}"
    fi
}

upload_transcript() {
    local transcript_file="$1"
    local session_id

    # Extract session ID from path (e.g., /root/.claude/projects/.../sessions/abc123.jsonl -> abc123)
    session_id=$(basename "$transcript_file" .jsonl)

    if [[ -z "$session_id" ]]; then
        log_error "Failed to extract session ID from $transcript_file"
        return 1
    fi

    local s3_dest
    # Upload main transcript
    s3_dest=$(build_s3_path "${session_id}.jsonl")
    if aws s3 cp "$transcript_file" "$s3_dest" --region "$AWS_REGION" 2>/dev/null; then
        log "Uploaded $transcript_file -> $s3_dest"
    else
        log_error "Failed to upload $transcript_file"
        return 1
    fi

    # Upload subagents if exists
    local session_dir="${transcript_file%.jsonl}"
    local subagents_dir="$session_dir/subagents"

    if [[ -d "$subagents_dir" ]]; then
        s3_dest=$(build_s3_path "${session_id}/")
        if aws s3 cp "$subagents_dir" "$s3_dest" --recursive --region "$AWS_REGION" 2>/dev/null; then
            log "Uploaded subagents -> $s3_dest"
        else
            log_error "Failed to upload subagents for $session_id"
        fi
    fi
}

find_and_upload_transcripts() {
    # Find main transcript files only (exclude subagents folder)
    local transcripts
    transcripts=$(find "$CLAUDE_DIR" -path "$CLAUDE_DIR/projects/*.jsonl" ! -path "*/subagents/*" 2>/dev/null || true)

    if [[ -z "$transcripts" ]]; then
        log "No active transcripts found"
        return 0
    fi

    while IFS= read -r transcript_file; do
        if [[ -f "$transcript_file" ]]; then
            upload_transcript "$transcript_file"
        fi
    done <<< "$transcripts"
}

main() {
    log "Starting transcript uploader sidecar (interval: ${UPLOAD_INTERVAL}s)"

    # Setup SIGTERM handler for graceful shutdown
    trap shutdown_handler SIGTERM

    # Check required environment variables
    if [[ -z "${AWS_S3_BUCKET_NAME:-}" ]]; then
        log_error "AWS_S3_BUCKET_NAME is not set"
        exit 1
    fi

    if [[ -z "${AWS_REGION:-}" ]]; then
        log_error "AWS_REGION is not set"
        exit 1
    fi

    # Preserve base credentials so we can re-assume the role on refresh
    BASE_AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}"
    BASE_AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}"

    if [[ -n "${AWS_ASSUME_ROLE_ARN:-}" ]]; then
        log "Assuming role: ${AWS_ASSUME_ROLE_ARN}"
        if ! assume_role; then
            log_error "Failed to assume role at startup"
            exit 1
        fi
    fi

    if ! check_aws_credentials; then
        exit 1
    fi

    if [[ -n "${AWS_S3_PATH_PREFIX:-}" ]]; then
        log "S3 path prefix: ${AWS_S3_PATH_PREFIX}"
    fi

    log "AWS credentials verified. Watching for transcripts..."

    # Main loop
    while [[ "$SHUTDOWN_REQUESTED" == "false" ]]; do
        assume_role || log_error "Failed to refresh assumed role credentials"
        find_and_upload_transcripts
        # Use sleep with wait to allow signal handling
        sleep "$UPLOAD_INTERVAL" &
        SLEEP_PID=$!
        wait "$SLEEP_PID" 2>/dev/null || true
        SLEEP_PID=""
    done

    # Final upload before exit
    assume_role || log_error "Failed to refresh assumed role credentials"
    find_and_upload_transcripts
    log "Shutdown complete"
}

main "$@"
