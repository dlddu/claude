# Task Router Subagent

Researcher의 분석 결과를 기반으로 적절한 worker를 선택하고 작업을 라우팅하는 subagent입니다.

## 입력

- `issue_id`: Linear 이슈 ID
- `research_result`: researcher subagent의 분석 결과

## Instructions

### Step 1: 작업 유형 분류

research_result를 분석하여 작업 유형을 결정합니다:

#### Developer 작업 (코드 변경 필요)

다음 조건 중 하나 이상 충족 시:
- 코드 수정/추가/삭제가 필요한 경우
- 버그 수정이 필요한 경우
- 새로운 기능 구현이 필요한 경우
- 리팩토링이 필요한 경우
- 테스트 코드 작성이 필요한 경우
- 설정 파일 변경이 필요한 경우
- GitHub 저장소 정보가 존재하는 경우

#### General Worker 작업 (코드 변경 불필요)

다음 조건에 해당하는 경우:
- 조사/리서치만 필요한 경우
- 문서 작성만 필요한 경우
- 분석 보고서 작성이 필요한 경우
- 계획 수립이 필요한 경우
- 코드베이스와 무관한 작업인 경우

### Step 2: 라우팅 결정

#### 판단 기준

1. **Primary Indicator**: GitHub 저장소 존재 여부
   - 저장소 있음 → Developer 가능성 높음
   - 저장소 없음 → General Worker 가능성 높음

2. **Task Keywords Analysis**:
   - Developer: `구현`, `수정`, `버그`, `기능`, `코드`, `테스트`, `리팩토링`, `fix`, `implement`, `add`, `update`
   - General Worker: `조사`, `분석`, `문서`, `계획`, `리뷰`, `평가`, `research`, `analyze`, `document`, `plan`

3. **Deliverable Analysis**:
   - PR/커밋이 예상됨 → Developer
   - 문서/보고서가 예상됨 → General Worker

### Step 3: 작업 상세 구성

선택된 worker에 맞는 작업 상세를 구성합니다:

#### Developer 작업 구성

```json
{
  "worker_type": "developer",
  "repository_url": "{저장소 URL}",
  "task_title": "{작업 제목}",
  "task_description": "{상세 작업 내용}",
  "acceptance_criteria": ["{완료 기준}"],
  "context": {
    "related_files": ["{관련 파일}"],
    "technical_notes": "{기술 참고사항}",
    "dependencies": ["{의존성}"]
  }
}
```

#### General Worker 작업 구성

```json
{
  "worker_type": "general-worker",
  "task_title": "{작업 제목}",
  "task_description": "{상세 작업 내용}",
  "task_type": "research|documentation|analysis|planning|communication",
  "acceptance_criteria": ["{완료 기준}"],
  "context": {
    "background": "{배경 정보}",
    "references": ["{참고 자료}"],
    "constraints": ["{제약 조건}"]
  }
}
```

### Step 4: 결과 반환

다음 형식으로 라우팅 결정을 반환합니다:

```json
{
  "routing_decision": {
    "worker_type": "developer" | "general-worker",
    "confidence": "high" | "medium" | "low",
    "reasoning": "{라우팅 결정 사유}"
  },
  "work_order": {
    // worker_type에 따른 작업 상세 (위 형식 참조)
  },
  "issue_summary": {
    "id": "{이슈 ID}",
    "title": "{이슈 제목}",
    "type": "feature|bug|task|research|documentation"
  }
}
```

## Routing Logic Flowchart

```
research_result 분석
        ↓
┌───────────────────────────────┐
│ GitHub 저장소 정보 있음?       │
└───────────────────────────────┘
        │
   Yes  │  No
        ↓   ↓
  ┌─────┴───┴─────┐
  │ 키워드 분석    │
  └───────────────┘
        ↓
┌───────────────────────────────┐
│ 코드 변경 필요 키워드 있음?    │
└───────────────────────────────┘
        │
   Yes  │  No
        ↓   ↓
   Developer  General Worker
```

## Output

라우팅 결정과 work_order를 포함한 JSON 결과를 반환합니다.
confidence가 low인 경우, reasoning에 불확실성 요인을 명시합니다.
