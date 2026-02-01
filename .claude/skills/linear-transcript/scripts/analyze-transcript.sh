#!/bin/bash
set -euo pipefail

# Usage: analyze-transcript.sh <session_id>
# Analyzes transcript from S3 and outputs tool usage statistics

SESSION_ID="${1:-}"
if [[ -z "$SESSION_ID" ]]; then
  echo "Usage: $0 <session_id>" >&2
  exit 1
fi

# 1. S3에서 transcript 다운로드
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# 메인 transcript 다운로드
if ! aws s3 cp "s3://${AWS_S3_BUCKET_NAME}/${SESSION_ID}.jsonl" "$TEMP_DIR/transcript.jsonl" --region "$AWS_REGION" 2>/dev/null; then
  echo "{\"error\": \"Transcript not found for session: $SESSION_ID\"}" >&2
  exit 1
fi

# subagents 폴더 다운로드 (없을 수도 있음)
aws s3 cp "s3://${AWS_S3_BUCKET_NAME}/${SESSION_ID}/" "$TEMP_DIR/subagents/" --recursive --region "$AWS_REGION" 2>/dev/null || true

# 모든 jsonl 파일을 합쳐서 분석
cat "$TEMP_DIR"/transcript.jsonl "$TEMP_DIR"/subagents/*.jsonl 2>/dev/null > /tmp/transcript.jsonl

# 2. 도구 호출과 결과를 매칭하여 분석
jq -s --arg session_id "$SESSION_ID" '
  # 도구 호출 추출 (id, name, input, agentId 포함)
  [.[] | select(.type == "assistant") |
    (if has("agentId") then .agentId else null end) as $aid |
    .message.content[]?
    | select(.type == "tool_use")
    | {id: .id, name: .name, input: .input, agentId: $aid}] as $uses |

  # 도구 결과를 id로 인덱싱
  ([.[] | select(has("toolUseResult"))
    | {key: .message.content[0].tool_use_id,
       value: {is_error: (.message.content[0].is_error // false),
               content: .message.content[0].content}}]
    | from_entries) as $results_map |

  # 각 도구 호출에 결과 매칭 (중복 없이)
  [$uses[] | . as $use |
    ($results_map[$use.id] // {is_error: false, content: null}) as $result |
    {name: $use.name, id: $use.id, input: $use.input, agentId: $use.agentId,
     is_error: $result.is_error,
     error: (if $result.is_error then $result.content else null end)}] as $matched |

  # agent별 그룹화 통계
  ($matched | group_by(.agentId) | map(
    . as $agent_items |
    {
      agentId: .[0].agentId,
      total_tool_calls: length,
      tools_summary: ($agent_items | group_by(.name) | map({
        name: .[0].name,
        count: length,
        success: [.[] | select(.is_error == false)] | length,
        failure: [.[] | select(.is_error == true)] | length
      }) | sort_by(-.count)),
      denied_tools: [$agent_items[] | select(.is_error == true) | {name, id, input, error}],
      success_count: ([$agent_items[] | select(.is_error == false)] | length),
      failure_count: ([$agent_items[] | select(.is_error == true)] | length),
      success_rate: (if length > 0 then (([$agent_items[] | select(.is_error == false)] | length) / length * 100 | floor) else 0 end)
    }
  ) | sort_by(if .agentId == null then 0 else 1 end)) as $by_agent |

  {
    session_id: $session_id,
    total_tool_calls: ($uses | length),
    tools_summary: (
      $matched | group_by(.name) | map({
        name: .[0].name,
        count: length,
        success: [.[] | select(.is_error == false)] | length,
        failure: [.[] | select(.is_error == true)] | length
      }) | sort_by(-.count)
    ),
    denied_tools: [
      $matched[] | select(.is_error == true) |
      {name, id, input, error}
    ],
    success_count: ([$matched[] | select(.is_error == false)] | length),
    failure_count: ([$matched[] | select(.is_error == true)] | length),
    success_rate: (
      if ($matched | length) > 0 then
        (([$matched[] | select(.is_error == false)] | length) / ($matched | length) * 100 | floor)
      else 0 end
    ),
    by_agent: $by_agent
  }
' /tmp/transcript.jsonl
