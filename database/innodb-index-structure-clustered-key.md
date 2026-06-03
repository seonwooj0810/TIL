# InnoDB 인덱스 구조와 clustered key

> **Primary source:** MySQL 8.0 Reference Manual §15.6.2 "InnoDB Index Types" / §15.6.2.1 "Clustered and Secondary Indexes" (구 §14)
> **Secondary:** Jeremy Cole, "InnoDB index structures" 시리즈 (blog.jcole.us); High Performance MySQL 4th ed. Ch.8
> **Date:** 2026-06-03
> **Status:** draft

## 왜 봤나

- [[btree-vs-lsm-tree-tradeoffs]]에서 "InnoDB의 clustered index는 B+Tree"라고만 정리하고 넘어갔는데, 정작 "clustered가 정확히 뭘 의미하나", "secondary index 조회가 왜 두 번 타나"를 설명 못 했다.
- 막연히 "PK 인덱스 = clustered index"라고 외우고 있었는데, PK가 없으면 어떻게 되는지, secondary index 리프에 뭐가 들어있는지가 흐릿했다.

## 핵심 한 문장

> InnoDB의 모든 테이블은 **clustered index 그 자체로 저장**된다 — 즉 row 데이터가 PK 순서로 B+Tree 리프에 직접 들어있고, secondary index의 리프는 row 위치(파일 오프셋)가 아니라 **PK 값**을 가리키므로 secondary 조회는 본질적으로 "secondary 트리 → clustered 트리"의 2단계 탐색이 된다.

## 내부 동작

### Clustered index = 테이블 그 자체

MySQL Reference Manual §15.6.2.1에 따르면 InnoDB는 테이블 데이터를 별도 힙에 두고 인덱스가 그곳을 가리키는 구조(heap-organized)가 **아니다**. 대신 테이블 자체가 하나의 clustered index B+Tree이고, **row 전체가 그 트리의 리프 페이지에 PK 순서로 저장**된다(index-organized table).

clustered key 선택 규칙(매뉴얼이 명시한 우선순위):

| 순위 | 조건 | clustered key |
| --- | --- | --- |
| 1 | PRIMARY KEY 있음 | 그 PK |
| 2 | PK 없고 NOT NULL UNIQUE 인덱스 있음 | 첫 번째 그 UNIQUE 키 |
| 3 | 둘 다 없음 | 내부 생성 `GEN_CLUST_INDEX`의 6바이트 `DB_ROW_ID` |

즉 PK를 안 만들어도 InnoDB는 숨은 row id로 clustered index를 **반드시** 만든다. "PK = clustered index"는 1순위 케이스일 뿐이다.

리프에 저장되는 실제 row 포맷(매뉴얼 §15.10 + Jeremy Cole 분석)에는 사용자 컬럼 외에 두 개의 숨은 시스템 컬럼이 함께 들어간다:

- `DB_TRX_ID` (6B): 마지막으로 이 row를 변경한 트랜잭션 id
- `DB_ROLL_PTR` (7B): undo log 레코드를 가리키는 roll pointer

이 둘이 MVCC의 핵심이다 — [[innodb-mvcc-undo-log-read-view]]에서 본 Read View가 `DB_TRX_ID`를 보고 가시성을 판정하고, 안 보이면 `DB_ROLL_PTR`을 따라 undo log로 과거 버전을 복원한다.

```
clustered index (PK = id 기준 정렬)
            [ 50 | 90 ]                 <- internal node: PK separator only
           /    |      \
  +--------+ +--------+ +--------+
  | id=10  | | id=50  | | id=90  |      <- leaf: row 전체 저장
  | name.. | | name.. | | name.. |          + DB_TRX_ID, DB_ROLL_PTR
  | trx,roll| | trx,roll| ...                (PK 순서로 물리 정렬)
  +--------+ +--------+ +--------+
       └────────▶───────────▶            리프 sibling 링크 (범위 스캔)
```

### Secondary index — 리프가 PK를 가리킨다

가장 중요한 차이. secondary index도 B+Tree지만, 리프에 저장되는 값은 **물리적 row 주소(파일 오프셋/페이지 번호)가 아니라 clustered key(PK) 값**이다(§15.6.2.1).

```
secondary index (key = name)
        [ "K" | "S" ]
       /     |      \
  +---------+ +---------+
  |"Alice"  | |"Kim"    |     <- leaf: (인덱스 컬럼, PK값)
  | →id=90  | | →id=50  |        물리 주소가 아니라 PK!
  +---------+ +---------+
```

그래서 `WHERE name = 'Kim'` 조회는 두 단계를 탄다:

1. secondary index B+Tree 탐색 → `name='Kim'` 리프에서 PK `id=50`을 얻음.
2. 그 PK로 **clustered index를 다시 탐색** → 실제 row를 읽음.

이 2단계를 **bookmark lookup** 또는 흔히 **back to table / 테이블 되짚기**라 부른다. 그래서 secondary index 조회 비용은 대략 `(secondary 트리 높이) + (clustered 트리 높이)` 만큼의 페이지 접근이 된다.

**왜 물리 주소가 아니라 PK인가?** 매뉴얼이 시사하는 이유: clustered index는 page split·row 이동이 일어나면 row의 물리 위치가 바뀐다. 만약 secondary가 물리 주소를 들고 있었다면 row가 움직일 때마다 모든 secondary index를 갱신해야 한다. PK를 들고 있으면 row가 어디로 움직이든 PK는 불변이라 secondary index를 건드릴 필요가 없다. 대신 읽기 시 한 번 더 트리를 타는 비용을 지불하는 트레이드오프다.

### Covering index — 2단계를 1단계로

secondary index가 **쿼리에 필요한 모든 컬럼을 이미 담고 있으면** clustered index 되짚기를 생략할 수 있다(covering index). 예: `INDEX(name, age)`에 대해 `SELECT name, age WHERE name='Kim'`은 secondary 리프만으로 답이 나온다. `EXPLAIN`의 `Extra`에 `Using index`로 나타난다. PK는 모든 secondary 리프에 암묵적으로 포함되므로, `SELECT id ...`도 covering이 될 수 있다.

### PK 설계가 secondary index 크기를 좌우한다

모든 secondary index 리프가 PK 값을 복제해서 들고 있으므로, **PK가 크면(예: 36바이트 UUID 문자열) 모든 secondary index가 그만큼 부풀어 오른다**. 이것이 "InnoDB에서 PK는 짧은 단조증가 정수(AUTO_INCREMENT BIGINT)가 유리하다"는 통념의 실제 근거다. 단조증가면 리프 끝에만 append되어 page split이 줄고, 짧으면 secondary index 전체가 작아진다. 랜덤 UUID를 PK로 쓰면 삽입이 트리 중간 곳곳에서 일어나 page split과 단편화가 심해진다고 알려져 있다.

## 검증

`EXPLAIN`으로 secondary index 되짚기 여부를 직접 확인하는 흐름:

```sql
CREATE TABLE member (
  id   BIGINT AUTO_INCREMENT PRIMARY KEY,   -- clustered key
  name VARCHAR(50),
  age  INT,
  KEY idx_name (name)                       -- secondary
);

-- (1) 되짚기 발생: SELECT * 라 name 인덱스에 없는 컬럼 필요
EXPLAIN SELECT * FROM member WHERE name = 'Kim';
--   key: idx_name,  Extra: (NULL)        ← clustered 되짚기

-- (2) covering: 필요한 컬럼이 secondary + PK 안에 다 있음
EXPLAIN SELECT id, name FROM member WHERE name = 'Kim';
--   key: idx_name,  Extra: Using index   ← 되짚기 없음
```

(1)과 (2)의 `Extra` 차이가 2단계 탐색의 존재를 그대로 드러낸다. 또 `idx_name`만으로 `SELECT id`가 covering이 되는 것은 secondary 리프에 PK가 들어있다는 증거다.

## 잘못 알고 있던 것

- **"PK가 없으면 clustered index가 없다"** — 아니다. PK가 없으면 NOT NULL UNIQUE 키, 그것도 없으면 숨은 6바이트 `DB_ROW_ID`로 InnoDB가 **항상** clustered index를 만든다. 테이블 = clustered index이므로 예외가 없다.
- **"secondary index 리프는 row의 물리 주소(포인터)를 가리킨다"** — MyISAM은 그랬지만 InnoDB는 **PK 값**을 가리킨다. 그래서 secondary 조회가 2단계가 되고, PK 길이가 모든 secondary index 크기에 영향을 준다.
- **"인덱스만 타면 무조건 빠르다"** — secondary index를 타도 covering이 아니면 매 행마다 clustered 되짚기(랜덤 I/O)가 붙는다. 매칭 행이 많으면 옵티마이저가 인덱스를 버리고 full scan을 고르기도 한다.

## 더 파고들 만한 것

- InnoDB **change buffer**가 secondary index의 랜덤 갱신을 어떻게 지연·병합하는지 ([[btree-vs-lsm-tree-tradeoffs]]에서 메모만 남김).
- **adaptive hash index**가 자주 타는 B+Tree 경로를 어떻게 해시로 단축하는지.
- 다중 컬럼 인덱스의 **leftmost prefix** 규칙과 정렬(ORDER BY) 활용 조건.

## 참고

- MySQL 8.0 Reference Manual §15.6.2.1 — Clustered and Secondary Indexes
- MySQL 8.0 Reference Manual §15.10 — InnoDB Row Formats (숨은 시스템 컬럼)
- Jeremy Cole, "The physical structure of InnoDB index pages" (blog.jcole.us)
- High Performance MySQL, 4th ed., Ch.8 — Indexing for High Performance
