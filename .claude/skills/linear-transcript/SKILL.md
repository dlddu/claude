---
name: linear-transcript
description: Linear 이슈의 세션 transcript에서 도구 사용 내역(성공/실패)을 분석합니다
allowed-tools: mcp__linear-server__*, Bash(.claude/skills/linear-transcript/scripts/analyze-transcript.sh:*), Bash(aws sts get-caller-identity:*)
---

# Linear Transcript Analyzer

주어진 Linear 이슈에 연결된 세션의 transcript를 분석하여 도구 사용 내역을 보여줍니다.

## Input

- Issue ID: $ARGUMENTS

## Instructions

### Step 1: Linear 이슈 정보 조회

1. `mcp__linear-server__get_issue`를 사용하여 이슈 정보를 가져옵니다
   - 파라미터: `id` (이슈 ID, 예: "DLD-25")
2. 이슈의 제목과 설명을 확인합니다

### Step 2: Session ID 추출

다음 위치에서 Session ID를 추출합니다:

1. **이슈 description**: `**Claude Session ID**: \`XXX\`` 패턴 검색
2. **이슈 comments**: `mcp__linear-server__list_comments`로 조회 후 동일 패턴 검색
   - 파라미터: `issueId` (이슈 ID, 예: "DLD-25")

Session ID 추출 정규식: `\*\*Claude Session ID\*\*: \`([^\`]+)\``

### Step 3: AWS 자격 증명 확인

> **중요**: 아래 명령어를 **정확히** 그대로 실행해야 합니다 (allowed-tools 패턴과 일치 필요)

```bash
aws sts get-caller-identity --region ap-northeast-2
```

### Step 4: Transcript 분석

각 Session ID에 대해 분석 스크립트를 실행합니다:

> **중요**: **상대 경로**로 실행해야 합니다. 전체 경로를 사용하면 권한이 거부됩니다.

```bash
.claude/skills/linear-transcript/scripts/analyze-transcript.sh "$SESSION_ID"
```

### Step 5: 결과 출력

JSON 결과를 터미널에 정리하여 출력합니다:

```markdown
## Issue: {identifier} - {title}

### 발견된 세션
| Session ID | 출처 |
|------------|------|
| {session_id} | {description/comment} |

### 도구 사용 분석

#### Session: {session_id}

**요약**
- 총 도구 호출: {total_tool_calls}회
- 성공: {success_count}회
- 실패: {failure_count}회
- 성공률: {success_rate}%

**도구별 통계**
| Tool | 호출 횟수 | 성공 | 실패 |
|------|----------|------|------|
| {name} | {count} | {success} | {failure} |

**거부된 도구 (denied_tools)**
| Tool | ID | 입력 파라미터 | 에러 |
|------|-----|-------------|------|
| {name} | {id} | {input} | {error} |
```

## Error Handling

- Session ID를 찾을 수 없는 경우: "이슈에서 Session ID를 찾을 수 없습니다" 출력
- DynamoDB 조회 실패: "Transcript를 조회할 수 없습니다: {session_id}" 출력
- AWS 자격 증명 없음: AWS 환경 변수 설정 안내 출력

## Output Format

분석이 완료되면 다음을 출력합니다:

1. 이슈 정보 요약
2. 발견된 세션 목록
3. 각 세션별 도구 사용 분석:
   - 총 호출 횟수, 성공/실패 통계
   - 도구별 성공/실패 분류
   - **denied_tools**: 거부된 도구의 전체 context (name, id, input, error)
4. 성공률

이 데이터는 최소 권한 원칙을 유지하며 `allowed-tools` 설정을 개선하는 데 활용할 수 있습니다.
