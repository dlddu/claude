---
name: linear-plan
description: Linear 이슈에 대한 작업 계획을 수립하고 sub-task를 생성합니다. "이슈 계획", "작업 분할", "sub-task 생성" 요청 시 사용
allowed-tools: mcp__linear-server__*, Read, Glob, Grep, Bash, Task
---

# Linear Issue Planning

주어진 Linear 이슈에 대해 작업 계획을 수립하고 sub-task를 생성합니다.

## Instructions

### Step 1: 이슈 분석

1. 사용자가 제공한 이슈 ID를 사용하여 Linear MCP로 이슈 정보를 가져옵니다
2. 이슈의 제목, 설명, 라벨, 우선순위 등을 분석합니다
3. 관련된 코드베이스를 탐색하여 컨텍스트를 파악합니다

### Step 2: 작업 계획 수립

다음 사항을 고려하여 작업 계획을 수립합니다:

1. **기술적 분석**: 변경이 필요한 파일과 컴포넌트 식별
2. **의존성 분석**: 작업 간의 의존 관계 파악
3. **위험 요소**: 잠재적인 문제점과 주의사항 식별
4. **테스트 계획**: 필요한 테스트 범위 결정

### Step 3: Sub-task 생성

작업 계획을 기반으로 Linear에 sub-task를 생성합니다:

1. 각 sub-task는 독립적으로 완료할 수 있는 단위여야 합니다
2. sub-task의 제목은 명확하고 구체적이어야 합니다
3. sub-task의 설명에는 다음 정보를 포함합니다:
   - 작업 목표
   - 수정해야 할 파일/컴포넌트
   - 완료 기준
   - 참고 사항

### Sub-task 생성 규칙

- 최소 단위로 분할: 각 sub-task는 1-2시간 내에 완료 가능한 크기
- 순서 고려: 의존성이 있는 경우 명확하게 표시
- 테스트 포함: 코드 변경이 있는 경우 관련 테스트 작성을 sub-task에 포함

### Step 4: 이슈에 계획 코멘트 작성

작업 계획이 완료되면 원본 이슈에 코멘트를 작성합니다:

1. `mcp__linear-server__create_comment`를 사용하여 코멘트 작성
2. Bash로 `echo $CLAUDE_SESSION_ID`를 실행하여 session ID 확인
3. 코멘트에 다음 내용 포함:
   - 작업 계획 요약
   - 생성된 sub-task 목록
   - Claude Session ID

코멘트 형식:

```markdown
## 작업 계획 수립 완료

**Claude Session ID**: `{session_id}`

### 계획 요약
{작업 계획 개요}

### 생성된 Sub-tasks
- [ ] {sub-task 1 제목}
- [ ] {sub-task 2 제목}
...

### 권장 작업 순서
1. {순서 설명}
```

## Output Format

작업이 완료되면 다음을 출력합니다:

1. 이슈 요약
2. 작업 계획 개요
3. 생성된 sub-task 목록 (ID와 제목)
4. 권장 작업 순서
