# Score-Based Auto-Merge Procedure

pr-reviewer subagent의 출력에서 점수를 추출하고, 점수에 따라 자동 머지 또는 블로킹을 수행하는 절차입니다.

## Step 1: pr-reviewer 출력에서 점수 추출

pr-reviewer subagent (Task tool)의 출력은 다음 JSON 구조를 포함합니다:

```json
{
  "success": true,
  "pr_number": 123,
  "review_result": {
    "total_score": 85,
    "breakdown": {
      "requirements_coverage": { "score": 90, "weight": 0.4, "contribution": 36 },
      "hardcoding_check": { "score": 80, "weight": 0.3, "contribution": 24 },
      "general_quality": { "score": 83, "weight": 0.3, "contribution": 25 },
      "binary_file_check": { "penalty": 0 }
    },
    "overall_summary": "..."
  },
  "comment_posted": true
}
```

**추출 절차**:

1. pr-reviewer Task tool의 반환값에서 JSON을 파싱합니다
2. `success` 필드를 확인합니다:
   - `success: false`인 경우 → 리뷰 자체가 실패. status를 `blocked`로 설정하고, `error` 필드의 내용을 실패 사유로 기록합니다
   - `success: true`인 경우 → 다음 단계로 진행
3. `review_result.total_score` 값을 숫자로 추출합니다
4. `comment_posted` 값을 기록합니다

**JSON 파싱 실패 시**:
- pr-reviewer의 출력이 유효한 JSON이 아닌 경우, 출력 텍스트에서 `"total_score": {숫자}` 패턴을 검색합니다
- 패턴도 찾을 수 없는 경우, status를 `blocked`로 설정하고 "pr-reviewer 출력 파싱 실패"를 사유로 기록합니다

## Step 2: 점수 기반 분기 처리

추출한 `total_score`를 `AUTO_MERGE_THRESHOLD` (워크플로우 Configuration 참조)와 비교합니다.

### Case A: total_score >= AUTO_MERGE_THRESHOLD (자동 머지)

```bash
cd /tmp/{repo_name}
gh pr merge {pr_number} --squash --delete-branch
```

- 워크플로우 결과:
  - `status`: `success`
  - `pr.merged`: `true`
  - `pr.merge_method`: `squash`
- PR이 자동으로 머지되고 브랜치가 삭제됩니다

**머지 명령 실패 시**:
- 종료 코드가 0이 아닌 경우 머지 실패로 판단합니다
- 일반적 실패 원인:
  - `merge conflict`: 베이스 브랜치와 충돌 발생
  - `required status checks`: 필수 status check 미통과
  - `review required`: 필수 리뷰 미완료 (branch protection rule)
  - `branch protection`: 기타 branch protection 위반
- 머지 실패 시:
  - `status`: `blocked`
  - `pr.merged`: `false`
  - `blocking_info.stage`: `auto_merge`
  - `blocking_info.reason`: 머지 실패 에러 메시지

### Case B: total_score < AUTO_MERGE_THRESHOLD (블로킹)

- 머지 명령을 실행하지 않습니다
- 워크플로우 결과:
  - `status`: `blocked`
  - `pr.merged`: `false`
  - `blocking_info.stage`: `pr_review`
  - `blocking_info.reason`: `"리뷰 점수 {total_score}점으로 AUTO_MERGE_THRESHOLD({AUTO_MERGE_THRESHOLD})점 미만. 수동 검토 필요."`
- PR은 열린 상태로 유지됩니다

## Step 3: 워크플로우 결과에 리뷰 정보 기록

점수 처리 결과와 관계없이 다음 정보를 워크플로우 결과 JSON에 포함합니다:

```json
{
  "workflow_stages": {
    "pr_review": {
      "status": "completed",
      "total_score": "{total_score}",
      "breakdown": "{review_result.breakdown에서 각 항목의 score 추출}",
      "comment_posted": "{comment_posted}"
    }
  },
  "pr": {
    "merged": true | false,
    "merge_method": "squash" | null
  }
}
```
