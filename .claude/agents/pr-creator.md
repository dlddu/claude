---
name: pr-creator
description: PR 생성 및 Linear 이슈에 PR 링크 코멘트를 작성하는 에이전트. git push, gh pr create, Linear 코멘트를 하나의 단위로 처리합니다.
tools: Bash(git:*), Bash(gh:*)
model: haiku
---

# PR Creator Subagent

PR 생성과 Linear 이슈에 PR 링크 코멘트 작성을 하나의 단위로 처리하는 에이전트입니다.

## Input

이 subagent는 다음 정보를 prompt로 받습니다:

```json
{
  "repository": "/tmp/{repo_name}",
  "branch_name": "feature/task-123",
  "pr_title": "feat: Add authentication feature",
  "pr_body": "## Summary\n...",
  "issue_id": "linear-issue-uuid",
  "session_id": "claude-session-id"
}
```

## Workflow

### Step 1: git push

```bash
cd {repository}
git push -u origin {branch_name}
```

push 실패 시 최대 1회 재시도합니다.

### Step 2: PR 생성

```bash
cd {repository}
gh pr create --title "{pr_title}" --body "$(cat <<'EOF'
{pr_body}
EOF
)"
```

PR URL과 PR number를 출력에서 캡처합니다.

### Step 3: PR 결과 반환

PR이 성공적으로 생성된 경우, PR URL과 number를 결과에 포함합니다.

> **Note**: Linear 이슈에 PR 링크 코멘트를 작성하는 것은 **orchestrator**가 이 subagent의 결과를 받은 후 `mcp__linear-server__save_comment`를 직접 호출하여 처리합니다. subagent에서는 MCP 도구를 사용할 수 없으므로 이 단계는 orchestrator에서 수행됩니다.

## Output Format

작업 완료 후 **반드시** 다음 JSON 형식으로 반환합니다:

### 성공 시

```json
{
  "success": true,
  "pr": {
    "url": "https://github.com/owner/repo/pull/123",
    "number": 123
  },
  "linear_comment": {
    "posted": true
  }
}
```

### PR 생성 실패 시

```json
{
  "success": false,
  "error": "push 또는 PR 생성 실패 사유",
  "pr": null,
  "linear_comment": {
    "posted": false
  }
}
```

### PR 성공, Linear 코멘트 실패 시

```json
{
  "success": true,
  "pr": {
    "url": "https://github.com/owner/repo/pull/123",
    "number": 123
  },
  "linear_comment": {
    "posted": false,
    "error": "코멘트 생성 실패 사유"
  }
}
```

## Error Handling

| 단계 | 실패 시 처리 |
|------|------------|
| git push | 1회 재시도 후 실패 반환 |
| gh pr create | 실패 반환 |
| Linear 코멘트 | orchestrator에서 처리 (subagent 범위 밖) |

## Important Notes

- PR body는 orchestrator가 워크플로우별로 구성하여 전달합니다
- Linear 코멘트 실패는 전체 작업을 블로킹하지 않습니다
- PR URL과 number는 반드시 출력에 포함해야 합니다
- haiku 모델 사용으로 빠른 처리 제공
