#!/bin/bash
set -euo pipefail

# Agent Supervisor Script
# This script monitors Linear issues and triggers appropriate actions

LOG_PREFIX="[agent-supervisor]"

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

# Get issues by state type
get_issues_by_state() {
    local state_type="$1"
    local query=$(cat <<EOF
{
    "query": "query { issues(filter: { state: { type: { eq: \\"$state_type\\" } } }, first: 1, orderBy: createdAt) { nodes { id identifier title state { id name type } children { nodes { id identifier title state { id name type } } } } } }"
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
        echo "$command $issue_id" | claude --dangerously-skip-permissions
    else
        echo "$command" | claude --dangerously-skip-permissions
    fi
}

# Process Todo issues
process_todo_issues() {
    log "Checking for Todo issues..."

    local result=$(get_issues_by_state "unstarted")
    local issue=$(echo "$result" | jq -r '.data.issues.nodes[0] // empty')

    if [[ -z "$issue" || "$issue" == "null" ]]; then
        log "No Todo issues found"
        return 0
    fi

    local issue_id=$(echo "$issue" | jq -r '.id')
    local issue_identifier=$(echo "$issue" | jq -r '.identifier')
    local sub_tasks=$(echo "$issue" | jq -r '.children.nodes')
    local sub_task_count=$(echo "$sub_tasks" | jq 'length')

    log "Found Todo issue: $issue_identifier (ID: $issue_id)"

    # Case a: No sub-tasks exist
    if [[ "$sub_task_count" -eq 0 ]]; then
        log "No sub-tasks found. Running /linear-plan..."
        run_claude "/linear-plan" "$issue_identifier"
        return 0
    fi

    # Check sub-task states
    local in_progress_count=$(echo "$sub_tasks" | jq '[.[] | select(.state.type == "started")] | length')
    local todo_count=$(echo "$sub_tasks" | jq '[.[] | select(.state.type == "unstarted")] | length')
    local done_count=$(echo "$sub_tasks" | jq '[.[] | select(.state.type == "completed")] | length')
    local blocked_count=$(echo "$sub_tasks" | jq '[.[] | select(.state.name == "Blocked" or .state.name == "blocked")] | length')

    log "Sub-task stats - Todo: $todo_count, In Progress: $in_progress_count, Done: $done_count, Blocked: $blocked_count"

    # Case b: All sub-tasks are Todo or Done
    if [[ "$in_progress_count" -eq 0 && "$blocked_count" -eq 0 && "$todo_count" -gt 0 ]]; then
        # Get first Todo sub-task
        local first_todo_subtask=$(echo "$sub_tasks" | jq -r '[.[] | select(.state.type == "unstarted")][0]')
        local subtask_id=$(echo "$first_todo_subtask" | jq -r '.id')
        local subtask_identifier=$(echo "$first_todo_subtask" | jq -r '.identifier')

        log "Updating issue and sub-task to In Progress..."

        # Update parent issue to In Progress
        update_issue_state_by_name "$issue_id" "In Progress"

        # Update sub-task to In Progress
        update_issue_state_by_name "$subtask_id" "In Progress"

        log "Running /linear-task for sub-task: $subtask_identifier"
        run_claude "/linear-task" "$subtask_identifier"
        return 0
    fi

    log "Todo issue has sub-tasks in progress or blocked state. Skipping."
    return 0
}

# Process In Progress issues
process_in_progress_issues() {
    log "Checking for In Progress issues..."

    local result=$(get_issues_by_state "started")
    local issue=$(echo "$result" | jq -r '.data.issues.nodes[0] // empty')

    if [[ -z "$issue" || "$issue" == "null" ]]; then
        log "No In Progress issues found"
        return 0
    fi

    local issue_id=$(echo "$issue" | jq -r '.id')
    local issue_identifier=$(echo "$issue" | jq -r '.identifier')
    local sub_tasks=$(echo "$issue" | jq -r '.children.nodes')
    local sub_task_count=$(echo "$sub_tasks" | jq 'length')

    log "Found In Progress issue: $issue_identifier (ID: $issue_id)"

    if [[ "$sub_task_count" -eq 0 ]]; then
        log "No sub-tasks found for In Progress issue. Skipping."
        return 0
    fi

    # Check sub-task states
    local in_progress_count=$(echo "$sub_tasks" | jq '[.[] | select(.state.type == "started")] | length')
    local todo_count=$(echo "$sub_tasks" | jq '[.[] | select(.state.type == "unstarted")] | length')
    local done_count=$(echo "$sub_tasks" | jq '[.[] | select(.state.type == "completed")] | length')
    local blocked_count=$(echo "$sub_tasks" | jq '[.[] | select(.state.name == "Blocked" or .state.name == "blocked")] | length')
    local total_count=$sub_task_count

    log "Sub-task stats - Todo: $todo_count, In Progress: $in_progress_count, Done: $done_count, Blocked: $blocked_count, Total: $total_count"

    # Case b: Any sub-task is blocked
    if [[ "$blocked_count" -gt 0 ]]; then
        log "Found blocked sub-task. Updating issue to Blocked..."
        update_issue_state_by_name "$issue_id" "Blocked"
        return 0
    fi

    # Case c: All sub-tasks are done
    if [[ "$done_count" -eq "$total_count" ]]; then
        log "All sub-tasks done. Updating issue to In Review..."
        update_issue_state_by_name "$issue_id" "In Review"
        return 0
    fi

    # Case a: All sub-tasks are Todo or Done (no in-progress)
    if [[ "$in_progress_count" -eq 0 && "$blocked_count" -eq 0 ]]; then
        log "No sub-tasks in progress. Updating issue to Todo..."
        update_issue_state_by_name "$issue_id" "Todo"
        return 0
    fi

    log "In Progress issue has sub-tasks still being worked on. Skipping."
    return 0
}

# Main function
main() {
    log "Starting Agent Supervisor..."

    check_env

    # Process Todo issues first
    process_todo_issues

    # Process In Progress issues
    process_in_progress_issues

    log "Agent Supervisor completed."
}

main "$@"
