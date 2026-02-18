# Linear Status Report Procedure

워크플로우 결과의 `status` 필드와 comment-composer subagent가 생성한 코멘트 본문을 받아
Linear API를 호출하여 이슈 상태 업데이트 및 코멘트 생성을 수행하는 절차입니다.
`{skill_directory}/scripts/linear-status-report.sh` 스크립트를 실행하여 처리합니다.

## 스크립트 실행

워크플로우 결과 필드와 subagent 출력을 조합한 JSON을 파일에 저장한 후 `--input` 인자로 전달하여 스크립트를 실행합니다:

```bash
echo '{script_input}' > /tmp/status-report-input.json && DEBUG=1 {skill_directory}/scripts/linear-status-report.sh --input /tmp/status-report-input.json
```

> **CRITICAL**: 반드시 위의 정확한 명령어 형식을 사용하세요. JSON을 파일로 저장한 뒤 `--input`으로 전달해야 합니다.
> 아래 패턴은 **절대 사용하지 마세요**:
> - ❌ `echo '{json}' | ./linear-status-report.sh` (stdin 파이핑 — 스크립트가 stdin을 읽지 않음)
> - ❌ `./linear-status-report.sh '{json}'` (위치 인자 — 스크립트가 위치 인자를 받지 않음)
> - ❌ `./linear-status-report.sh --input '{json}'` (인라인 JSON — 반드시 파일 경로를 전달)

> `{skill_directory}`는 이 스킬의 디렉토리 경로입니다.

## 스크립트 입력

워크플로우 결과의 `issue_id`, `team_id`, `status`와 subagent가 생성한 `comment_body`를 조합한 JSON:

```json
{
  "issue_id": "이슈 ID",
  "team_id": "팀 ID",
  "status": "success | blocked",
  "comment_body": "Markdown 코멘트 본문 (subagent 생성)"
}
```

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
  "error_stage": "init | status_lookup | comment_create",
  "summary": "에러 요약"
}
```

## 상태 매핑

스크립트가 `status` 필드를 기반으로 대상 Linear 상태를 결정합니다:

| 입력 status | Linear 상태 |
|---|---|
| `success` | Done |
| `blocked` | In Review |

## 에러 처리

- 스크립트 종료 코드가 1인 경우: 초기화 실패 또는 상태 조회 실패. stdout의 JSON에서 `error_stage`와 `error`를 확인합니다.
- 입력 파일이 없거나 비어있는 경우: `error_stage`가 `init`이고 `error`에 파일 경로가 포함됩니다.
- 상태 업데이트 실패 시에도 코멘트 생성은 시도합니다.
- 스크립트 자체가 실행 불가한 경우: status를 `blocked`로, `blocking_info.stage`를 `linear_status_report`로 설정합니다.
