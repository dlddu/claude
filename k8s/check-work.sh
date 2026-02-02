#!/bin/bash
set -euo pipefail

# Work Checker Script
# This script checks for Linear issues that need work and triggers agent-supervisor

LOG_PREFIX="[work-checker]"

# State name configuration (must match agent-supervisor.sh)
STATE_BACKLOG="Backlog"
STATE_IN_PROGRESS="In Progress"

log() {
    echo "$LOG_PREFIX $(date -u +"%Y-%m-%dT%H:%M:%SZ") $1"
}

log_error() {
    echo "$LOG_PREFIX $(date -u +"%Y-%m-%dT%H:%M:%SZ") ERROR: $1" >&2
}

# Check required environment variables
check_env() {
    if [[ -z "${LINEAR_API_KEY:-}" ]]; then
        log_error "LINEAR_API_KEY is not set"
        exit 1
    fi
}

# GraphQL query to Linear API
linear_query() {
    local query="$1"
    curl -s -X POST \
        -H "Content-Type: application/json" \
        -H "Authorization: $LINEAR_API_KEY" \
        -d "$query" \
        "https://api.linear.app/graphql"
}

# Check if work exists (Backlog or In Progress issues)
check_work_exists() {
    local backlog_query=$(cat <<EOF
{
    "query": "query { issues(filter: { parent: { null: true }, state: { name: { eq: \"$STATE_BACKLOG\" } } }, first: 1) { nodes { id identifier } } }"
}
EOF
)
    local in_progress_query=$(cat <<EOF
{
    "query": "query { issues(filter: { parent: { null: true }, state: { name: { eq: \"$STATE_IN_PROGRESS\" } } }, first: 1) { nodes { id identifier } } }"
}
EOF
)

    # Check Backlog issues
    local backlog_result=$(linear_query "$backlog_query")
    local backlog_count=$(echo "$backlog_result" | jq '.data.issues.nodes | length')

    if [[ "$backlog_count" -gt 0 ]]; then
        local identifier=$(echo "$backlog_result" | jq -r '.data.issues.nodes[0].identifier')
        log "Found $STATE_BACKLOG issue: $identifier"
        return 0
    fi

    # Check In Progress issues
    local in_progress_result=$(linear_query "$in_progress_query")
    local in_progress_count=$(echo "$in_progress_result" | jq '.data.issues.nodes | length')

    if [[ "$in_progress_count" -gt 0 ]]; then
        local identifier=$(echo "$in_progress_result" | jq -r '.data.issues.nodes[0].identifier')
        log "Found $STATE_IN_PROGRESS issue: $identifier"
        return 0
    fi

    return 1
}

# Create agent-supervisor Job from CronJob template
create_job() {
    local job_name="agent-supervisor-$(date +%s)"
    log "Creating job: $job_name"

    if kubectl create job "$job_name" --from=cronjob/agent-supervisor; then
        log "Job created successfully: $job_name"
    else
        log_error "Failed to create job: $job_name"
        exit 1
    fi
}

# Main function
main() {
    log "Starting work check..."

    check_env

    if check_work_exists; then
        create_job
    else
        log "No work to do"
    fi

    log "Work check completed"
}

main "$@"
