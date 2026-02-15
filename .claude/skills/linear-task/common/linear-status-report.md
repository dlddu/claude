# Linear Status Report Procedure

워크플로우 결과를 기반으로 Linear 이슈 상태를 업데이트하고 보고 코멘트를 생성하는 절차입니다.
`scripts/linear-status-report.sh` 스크립트를 실행하여 처리합니다.

## 스크립트 실행

워크플로우 결과 JSON을 stdin으로 전달하여 스크립트를 실행합니다:

```bash
echo '{report_json}' | {repository_root}/scripts/linear-status-report.sh
```

> `{report_json}`은 `common/linear-report-format.md`에 정의된 형식의 JSON입니다.
> `{repository_root}`는 이 repository의 루트 경로입니다 (예: `/home/user/claude`).

## 스크립트 출력

스크립트는 stdout에 JSON을 출력합니다:

### 성공 시

```json
{
  "success": true,
  "issue_id": "이슈 ID",
  "status_updated": true,
  "new_status": "Done",
  "comment_created": true,
  "comment_id": "생성된 코멘트 ID",
  "summary": "이슈 상태가 Done(으)로 업데이트되고 보고 코멘트가 작성되었습니다."
}
```

### 실패 시

```json
{
  "success": false,
  "issue_id": "이슈 ID",
  "status_updated": false,
  "error": "에러 메시지",
  "error_stage": "init | status_lookup | status_update | comment_create",
  "summary": "에러 요약"
}
```

## 상태 매핑

| 워크플로우 status | Linear 상태 |
|---|---|
| `success` | Done |
| `blocked` | In Review |

## 에러 처리

- 스크립트 종료 코드가 1인 경우: 초기화 실패 또는 상태 조회 실패. stdout의 JSON에서 `error_stage`와 `error`를 확인합니다.
- 상태 업데이트 실패 시에도 코멘트 생성은 시도합니다.
- 스크립트 자체가 실행 불가한 경우: status를 `blocked`로, `blocking_info.stage`를 `linear_status_report`로 설정합니다.
