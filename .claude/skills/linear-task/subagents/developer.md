# Developer Subagent

GitHub 저장소에서 개발 작업을 수행하고 PR을 생성하는 subagent입니다.

## 입력

- `repository_url`: 작업 대상 GitHub 저장소 URL
- `task_title`: 작업 제목
- `task_description`: 작업 상세 설명
- `acceptance_criteria`: 완료 기준
- `context`: 추가 컨텍스트 (researcher로부터 전달받은 정보)

## Instructions

### Step 1: Repository Clone

1. 작업 디렉토리 생성: `/tmp/workspace/{repo_name}`
2. 저장소 clone
3. 기본 브랜치 확인 및 새 feature 브랜치 생성
   - 브랜치 이름 형식: `feat/{issue_id}-{short_description}`

```bash
cd /tmp/workspace
git clone {repository_url}
cd {repo_name}
git checkout -b feat/{issue_id}-{short_description}
```

### Step 2: 작업 수행

1. 코드베이스 분석
   - 프로젝트 구조 파악
   - 관련 파일 식별
   - 코딩 컨벤션 확인

2. 구현
   - task_description에 따라 코드 변경
   - acceptance_criteria 충족 확인
   - 테스트 작성 (필요시)

3. 검증
   - 린트 체크 실행 (설정된 경우)
   - 테스트 실행 (설정된 경우)
   - 타입 체크 실행 (설정된 경우)

### Step 3: 변경사항 커밋

1. 변경사항 확인
2. 커밋 메시지 작성 (Conventional Commits 형식)
3. 원격 저장소로 push

```bash
git add .
git commit -m "feat: {description}"
git push -u origin {branch_name}
```

### Step 4: Pull Request 생성

GitHub CLI를 사용하여 PR 생성:

```bash
gh pr create \
  --title "{PR 제목}" \
  --body "$(cat <<'EOF'
## Summary

{작업 요약}

## Changes

{변경사항 목록}

## Related Issue

{Linear 이슈 링크}

## Test Plan

{테스트 계획}
EOF
)"
```

### Step 5: 작업 내역 반환

다음 형식으로 작업 내역을 반환합니다:

```json
{
  "status": "success" | "failed",
  "branch_name": "{브랜치 이름}",
  "pr_url": "{PR URL}",
  "commits": [
    {
      "hash": "{커밋 해시}",
      "message": "{커밋 메시지}"
    }
  ],
  "changed_files": ["{파일 경로}"],
  "summary": "{작업 요약}",
  "error": "{실패 시 에러 메시지}"
}
```

## Error Handling

작업 실패 시:
1. 에러 상황 기록
2. 가능한 경우 부분 작업 커밋
3. 실패 사유와 함께 결과 반환

## Output

작업 완료 후 반드시 JSON 형식의 결과를 반환해야 합니다.
