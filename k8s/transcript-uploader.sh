#!/bin/bash

# Transcript Uploader Sidecar
# Uploads transcript files to S3 every 30 seconds
# Handles SIGTERM for graceful shutdown (K8s native sidecar)

LOG_PREFIX="[transcript-uploader]"
UPLOAD_INTERVAL=30
CLAUDE_DIR="/root/.claude"
SHUTDOWN_REQUESTED=false
SLEEP_PID=""

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

upload_transcript() {
    local transcript_file="$1"
    local session_id

    # Extract session ID from path (e.g., /root/.claude/projects/.../sessions/abc123.jsonl -> abc123)
    session_id=$(basename "$transcript_file" .jsonl)

    if [[ -z "$session_id" ]]; then
        log_error "Failed to extract session ID from $transcript_file"
        return 1
    fi

    # Upload main transcript
    if aws s3 cp "$transcript_file" "s3://${AWS_S3_BUCKET_NAME}/${session_id}.jsonl" --region "$AWS_REGION" 2>/dev/null; then
        log "Uploaded $transcript_file -> s3://${AWS_S3_BUCKET_NAME}/${session_id}.jsonl"
    else
        log_error "Failed to upload $transcript_file"
        return 1
    fi

    # Upload subagents if exists
    local session_dir="${transcript_file%.jsonl}"
    local subagents_dir="$session_dir/subagents"

    if [[ -d "$subagents_dir" ]]; then
        if aws s3 cp "$subagents_dir" "s3://${AWS_S3_BUCKET_NAME}/${session_id}/" --recursive --region "$AWS_REGION" 2>/dev/null; then
            log "Uploaded subagents -> s3://${AWS_S3_BUCKET_NAME}/${session_id}/"
        else
            log_error "Failed to upload subagents for $session_id"
        fi
    fi
}

find_and_upload_transcripts() {
    # Find all active transcript files (modified within last 30 minutes)
    local transcripts
    transcripts=$(find "$CLAUDE_DIR" -name "*.jsonl" -mmin -30 2>/dev/null || true)

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

    if ! check_aws_credentials; then
        exit 1
    fi

    log "AWS credentials verified. Watching for transcripts..."

    # Main loop
    while [[ "$SHUTDOWN_REQUESTED" == "false" ]]; do
        find_and_upload_transcripts
        # Use sleep with wait to allow signal handling
        sleep "$UPLOAD_INTERVAL" &
        SLEEP_PID=$!
        wait "$SLEEP_PID" 2>/dev/null || true
        SLEEP_PID=""
    done

    # Final upload before exit
    find_and_upload_transcripts
    log "Shutdown complete"
}

main "$@"
