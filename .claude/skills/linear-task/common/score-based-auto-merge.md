# Score-Based Auto-Merge Procedure

pr-reviewer 결과에서 점수를 파싱하고 자동 머지를 수행하는 절차입니다.
`{skill_directory}/scripts/auto-merge.sh` 스크립트를 실행하여 처리합니다.

## 스크립트 실행

pr-reviewer subagent의 출력(JSON 텍스트)을 stdin으로 전달하여 스크립트를 실행합니다:

```bash
echo '{pr_reviewer_output}' | {skill_directory}/scripts/auto-merge.sh \
  --repo /tmp/{repo_name} \
  --pr {pr_number} \
  --threshold {AUTO_MERGE_THRESHOLD}
```

> `{pr_reviewer_output}`은 pr-reviewer Task tool이 반환한 전체 JSON 텍스트입니다.
> `{skill_directory}`는 이 스킬의 디렉토리 경로입니다.

## 스크립트 출력

스크립트는 stdout에 JSON을 출력합니다:

```json
{
  "status": "success | blocked",
  "total_score": 85,
  "merged": true | false,
  "merge_method": "squash | null",
  "blocking_stage": "pr_review | auto_merge | null",
  "blocking_reason": "사유 또는 null"
}
```

## 워크플로우 결과 매핑

스크립트 출력을 워크플로우 결과 JSON에 다음과 같이 매핑합니다:

| 스크립트 출력 필드 | 워크플로우 결과 필드 |
|---|---|
| `status` | 워크플로우 최종 `status` |
| `total_score` | `workflow_stages.pr_review.total_score` |
| `merged` | `pr.merged` |
| `merge_method` | `pr.merge_method` |
| `blocking_stage` | `blocking_info.stage` (blocked인 경우) |
| `blocking_reason` | `blocking_info.reason` (blocked인 경우) |

## 에러 처리

- 스크립트 종료 코드가 1인 경우: 리뷰 실패 또는 파싱 실패. stdout의 JSON에서 `blocking_reason`을 확인합니다.
- 스크립트 자체가 실행 불가한 경우: status를 `blocked`로, `blocking_info.stage`를 `auto_merge`로 설정합니다.
