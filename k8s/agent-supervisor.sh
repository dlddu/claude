#!/bin/bash
set -euo pipefail

# Agent Supervisor Script
# This script monitors Linear issues and triggers appropriate actions

LOG_PREFIX="[agent-supervisor]"

# State name configuration (can be customized per Linear workspace)
STATE_BACKLOG="Backlog" # 작업 대기 (main, sub issue)
STATE_TODO="Todo" # 계획 완료 후 사용자 검토 대기 중 (main issue)
STATE_IN_PROGRESS="In Progress" # 작업 중 (main, sub issue)
STATE_IN_REVIEW="In Review" # 모든 작업 완료 후 사용자 검토 대기 중 (main issue)
STATE_DONE="Done" # 확인 완료 (main issue), 작업 완료 (sub issue)
STATE_BLOCKED="Blocked" # 작업 중단 (main, sub issue)

log() {
    echo "$LOG_PREFIX $(date -u +"%Y-%m-%dT%H:%M:%SZ") $1"
}

log_error() {
    echo "$LOG_PREFIX $(date -u +"%Y-%m-%dT%H:%M:%SZ") ERROR: $1" >&2
}

# Check required environment variables
check_env() {
    local required_vars=("LINEAR_API_KEY" "CLAUDE_CODE_OAUTH_TOKEN")
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            log_error "$var is not set"
            exit 1
        fi
    done
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

# Get issues by state name
get_issues_by_state() {
    local state_name="$1"
    local query=$(cat <<EOF
{
    "query": "query { issues(filter: { parent: { null: true }, state: { name: { eq: \\"$state_name\\" } } }, first: 1, sort: { createdAt: { order: Ascending } }) { nodes { id identifier title createdAt state { id name type } children { nodes { id identifier title createdAt state { id name type } } } } } }"
}
EOF
)
    linear_query "$query"
}

# Update issue state
update_issue_state() {
    local issue_id="$1"
    local state_name="$2"
    local query=$(cat <<EOF
{
    "query": "mutation { issueUpdate(id: \\"$issue_id\\", input: { stateId: \\"$state_name\\" }) { success issue { id identifier state { name } } } }"
}
EOF
)
    linear_query "$query"
}

# Get state ID by name and team
get_state_id() {
    local team_id="$1"
    local state_name="$2"
    local query=$(cat <<EOF
{
    "query": "query { workflowStates(filter: { team: { id: { eq: \\"$team_id\\" } }, name: { eq: \\"$state_name\\" } }) { nodes { id name type } } }"
}
EOF
)
    local result=$(linear_query "$query")
    echo "$result" | jq -r '.data.workflowStates.nodes[0].id // empty'
}

# Get team ID from issue
get_team_id() {
    local issue_id="$1"
    local query=$(cat <<EOF
{
    "query": "query { issue(id: \\"$issue_id\\") { team { id } } }"
}
EOF
)
    local result=$(linear_query "$query")
    echo "$result" | jq -r '.data.issue.team.id // empty'
}

# Update issue state by state name
update_issue_state_by_name() {
    local issue_id="$1"
    local state_name="$2"

    local team_id=$(get_team_id "$issue_id")
    if [[ -z "$team_id" ]]; then
        log_error "Failed to get team ID for issue $issue_id"
        return 1
    fi

    local state_id=$(get_state_id "$team_id" "$state_name")
    if [[ -z "$state_id" ]]; then
        log_error "Failed to get state ID for state '$state_name'"
        return 1
    fi

    update_issue_state "$issue_id" "$state_id"
}

# Run claude command with slash command
run_claude() {
    local command="$1"
    local issue_id="${2:-}"

    log "Running claude command: $command ${issue_id:-}"

    if [[ -n "$issue_id" ]]; then
        echo "$command $issue_id" | claude -p
    else
        echo "$command" | claude -p
    fi
}

# Process Backlog issues
process_backlog_issues() {
    log "Checking for $STATE_BACKLOG issues..."

    local result=$(get_issues_by_state "$STATE_BACKLOG")
    local issue=$(echo "$result" | jq -r '.data.issues.nodes | sort_by(.createdAt)[0] // empty')

    if [[ -z "$issue" || "$issue" == "null" ]]; then
        log "No $STATE_BACKLOG issues found"
        return 0
    fi

    local issue_id=$(echo "$issue" | jq -r '.id')
    local issue_identifier=$(echo "$issue" | jq -r '.identifier')
    local sub_issues=$(echo "$issue" | jq -r '.children.nodes')
    local sub_issue_count=$(echo "$sub_issues" | jq 'length')

    log "Found $STATE_BACKLOG issue: $issue_identifier (ID: $issue_id)"

    # Case a: No sub-issues exist
    if [[ "$sub_issue_count" -eq 0 ]]; then
        log "No sub-issues found. Updating issue to $STATE_TODO and running /linear-plan..."
        update_issue_state_by_name "$issue_id" "$STATE_TODO"
        run_claude "/linear-plan" "$issue_identifier"
        return 0
    fi

    # Check sub-issue states
    local in_progress_count=$(echo "$sub_issues" | jq --arg state "$STATE_IN_PROGRESS" '[.[] | select(.state.name == $state)] | length')
    local backlog_count=$(echo "$sub_issues" | jq --arg state "$STATE_BACKLOG" '[.[] | select(.state.name == $state)] | length')
    local done_count=$(echo "$sub_issues" | jq --arg state "$STATE_DONE" '[.[] | select(.state.name == $state)] | length')
    local blocked_count=$(echo "$sub_issues" | jq --arg state "$STATE_BLOCKED" '[.[] | select(.state.name == $state)] | length')

    log "Sub-issue stats - $STATE_BACKLOG: $backlog_count, $STATE_IN_PROGRESS: $in_progress_count, $STATE_DONE: $done_count, $STATE_BLOCKED: $blocked_count"
    # Case b: All sub-issues are Backlog or Done
    if [[ "$in_progress_count" -eq 0 && "$blocked_count" -eq 0 && "$backlog_count" -gt 0 ]]; then
        # Get first Backlog sub-issue (sorted by createdAt ascending - oldest first)
        local first_backlog_subissue=$(echo "$sub_issues" | jq -r --arg state "$STATE_BACKLOG" '[.[] | select(.state.name == $state)] | sort_by(.createdAt)[0]')
        local subissue_id=$(echo "$first_backlog_subissue" | jq -r '.id')
        local subissue_identifier=$(echo "$first_backlog_subissue" | jq -r '.identifier')

        log "Updating issue and sub-issue to $STATE_IN_PROGRESS..."

        # Update parent issue to In Progress
        update_issue_state_by_name "$issue_id" "$STATE_IN_PROGRESS"

        # Update sub-issue to In Progress
        update_issue_state_by_name "$subissue_id" "$STATE_IN_PROGRESS"

        log "Running /linear-task for sub-issue: $subissue_identifier"
        run_claude "/linear-task" "$subissue_identifier"
        return 0
    fi

    log "Backlog issue has sub-issues in progress or blocked state. Skipping."
    return 0
}

# Process In Progress issues
process_in_progress_issues() {
    log "Checking for $STATE_IN_PROGRESS issues..."

    local result=$(get_issues_by_state "$STATE_IN_PROGRESS")
    local issue=$(echo "$result" | jq -r '.data.issues.nodes | sort_by(.createdAt)[0] // empty')

    if [[ -z "$issue" || "$issue" == "null" ]]; then
        log "No $STATE_IN_PROGRESS issues found"
        return 0
    fi

    local issue_id=$(echo "$issue" | jq -r '.id')
    local issue_identifier=$(echo "$issue" | jq -r '.identifier')
    local sub_issues=$(echo "$issue" | jq -r '.children.nodes')
    local sub_issue_count=$(echo "$sub_issues" | jq 'length')

    log "Found $STATE_IN_PROGRESS issue: $issue_identifier (ID: $issue_id)"

    if [[ "$sub_issue_count" -eq 0 ]]; then
        log "No sub-issues found for $STATE_IN_PROGRESS issue. Skipping."
        return 0
    fi

    # Check sub-issue states
    local in_progress_count=$(echo "$sub_issues" | jq --arg state "$STATE_IN_PROGRESS" '[.[] | select(.state.name == $state)] | length')
    local todo_count=$(echo "$sub_issues" | jq --arg state "$STATE_TODO" '[.[] | select(.state.name == $state)] | length')
    local done_count=$(echo "$sub_issues" | jq --arg state "$STATE_DONE" '[.[] | select(.state.name == $state)] | length')
    local blocked_count=$(echo "$sub_issues" | jq --arg state "$STATE_BLOCKED" '[.[] | select(.state.name == $state)] | length')
    local total_count=$sub_issue_count

    log "Sub-issue stats - $STATE_TODO: $todo_count, $STATE_IN_PROGRESS: $in_progress_count, $STATE_DONE: $done_count, $STATE_BLOCKED: $blocked_count, Total: $total_count"

    # Case b: Any sub-issue is blocked
    if [[ "$blocked_count" -gt 0 ]]; then
        log "Found blocked sub-issue. Updating issue to $STATE_BLOCKED..."
        update_issue_state_by_name "$issue_id" "$STATE_BLOCKED"
        return 0
    fi

    # Case c: All sub-issues are done
    if [[ "$done_count" -eq "$total_count" ]]; then
        log "All sub-issues done. Updating issue to $STATE_IN_REVIEW..."
        update_issue_state_by_name "$issue_id" "$STATE_IN_REVIEW"
        return 0
    fi

    # Case a: All sub-issues are Todo or Done (no in-progress)
    if [[ "$in_progress_count" -eq 0 && "$blocked_count" -eq 0 ]]; then
        log "No sub-issues in progress. Updating issue to $STATE_BACKLOG..."
        update_issue_state_by_name "$issue_id" "$STATE_BACKLOG"
        return 0
    fi

    log "In Progress issue has sub-issues still being worked on. Skipping."
    return 0
}

# Main function
main() {
    log "Starting Agent Supervisor..."

    check_env

    # Process Backlog issues first
    process_backlog_issues

    # Process In Progress issues
    process_in_progress_issues

    log "Agent Supervisor completed."
}

main "$@"
