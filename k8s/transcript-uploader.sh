#!/bin/bash

# Transcript Uploader Sidecar
# Uploads transcript files to the transcript viewer every 30 seconds
# via its presigned-URL upload API.
# Handles SIGTERM for graceful shutdown (K8s native sidecar)

LOG_PREFIX="[transcript-uploader]"
UPLOAD_INTERVAL=30
CLAUDE_DIR="/root/.claude"
SHUTDOWN_REQUESTED=false
SLEEP_PID=""

# Accepted upload file names: "<name>.jsonl" or "subagents/<name>.jsonl"
FILE_NAME_PATTERN='^(subagents/)?[A-Za-z0-9._-]+\.jsonl$'

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

# URL-encode a string for safe use in URL path segments and query values.
urlencode() {
    jq -rn --arg s "$1" '$s|@uri'
}

# Upload a single file to the transcript viewer using the 2-step presigned URL flow:
#   1. POST .../api/transcripts/upload-url/<session_id>?file_name=<file_name> -> { url, method }
#   2. <method> the file contents to the returned presigned URL
# Args: $1 = local file path, $2 = session id, $3 = file_name (as stored by the API)
upload_file() {
    local file="$1"
    local session_id="$2"
    local file_name="$3"

    local request_url="${TRANSCRIPT_UPLOAD_API_URL%/}/api/transcripts/upload-url/$(urlencode "$session_id")?file_name=$(urlencode "$file_name")"

    # Step 1: request a presigned upload URL
    local response
    if ! response=$(curl -sf -X POST "$request_url" 2>/dev/null); then
        log_error "Failed to request upload URL for $file_name"
        return 1
    fi

    local url method
    url=$(echo "$response" | jq -r '.url // empty')
    method=$(echo "$response" | jq -r '.method // "PUT"')

    if [[ -z "$url" ]]; then
        log_error "Upload URL response missing 'url' for $file_name"
        return 1
    fi

    # Step 2: upload the file contents to the presigned URL
    if ! curl -sf -X "$method" --data-binary @"$file" \
        -H "Content-Type: application/jsonl" "$url" 2>/dev/null; then
        log_error "Failed to upload $file_name to presigned URL"
        return 1
    fi

    return 0
}

upload_transcript() {
    local transcript_file="$1"
    local session_id

    # Extract session ID from path (e.g., /root/.claude/projects/.../abc123.jsonl -> abc123)
    session_id=$(basename "$transcript_file" .jsonl)

    if [[ -z "$session_id" ]]; then
        log_error "Failed to extract session ID from $transcript_file"
        return 1
    fi

    # Upload main transcript
    local main_file_name="${session_id}.jsonl"
    if [[ ! "$main_file_name" =~ $FILE_NAME_PATTERN ]]; then
        log_error "Invalid transcript file name '$main_file_name', skipping"
        return 1
    fi

    if upload_file "$transcript_file" "$session_id" "$main_file_name"; then
        log "Uploaded $transcript_file (file_name=$main_file_name)"
    else
        log_error "Failed to upload $transcript_file"
        return 1
    fi

    # Upload subagent transcripts individually, if any
    local subagents_dir="${transcript_file%.jsonl}/subagents"

    if [[ -d "$subagents_dir" ]]; then
        local subagent_file file_name
        for subagent_file in "$subagents_dir"/*.jsonl; do
            [[ -e "$subagent_file" ]] || continue
            file_name="subagents/$(basename "$subagent_file")"
            if [[ ! "$file_name" =~ $FILE_NAME_PATTERN ]]; then
                log_error "Invalid subagent file name '$file_name', skipping"
                continue
            fi
            if upload_file "$subagent_file" "$session_id" "$file_name"; then
                log "Uploaded subagent $subagent_file (file_name=$file_name)"
            else
                log_error "Failed to upload subagent $subagent_file"
            fi
        done
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
    if [[ -z "${TRANSCRIPT_UPLOAD_API_URL:-}" ]]; then
        log_error "TRANSCRIPT_UPLOAD_API_URL is not set"
        exit 1
    fi

    log "Uploading transcripts to ${TRANSCRIPT_UPLOAD_API_URL%/}. Watching for transcripts..."

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
