# PostgreSQL TOAST는 "큰 값"이 아니라 "큰 행"에 반응한다 — 가장 큰 컬럼부터 압축·외부화하는 4단계 루프

> **Primary source:** PostgreSQL 18 Docs §66.2 "TOAST" (storage-toast.html) / `src/backend/access/heap/heaptoast.c` `heap_toast_insert_or_update()` · `src/backend/access/table/toast_helper.c` `toast_tuple_find_biggest_attribute()` (postgres master)
> **Secondary:** `src/include/access/heaptoast.h`(임계값 매크로), `src/backend/access/common/toast_internals.c` `toast_compress_datum()`, `src/common/pg_lzcompress.c` `strategy_default_data`
> **Date:** 2026-10-02
> **Status:** draft
> 블로그: https://velog.io/@jungseonw00/postgresql-toast-four-pass-loop

## 왜 봤나

- 흔한 설명은 "2KB가 넘는 값은 TOAST 테이블로 간다"이다. 하지만 이 문장으로는 1.5KB짜리 `text` 컬럼이 압축돼 있는 이유도, 3KB짜리 값이 그대로 본 테이블에 남아 있는 이유도 설명이 안 된다.
- 판단 단위가 **행(튜플) 전체**이고, 목표 크기 아래가 될 때까지 **가장 큰 컬럼 하나씩** 처리하는 루프라는 점을 소스로 확인했다.

## 핵심 한 문장

> 힙 튜플이 `TOAST_TUPLE_THRESHOLD`(8KB 페이지에서 약 2KB)를 넘으면, 토스터는 4개 패스를 돌며 매번 그 시점에 **가장 큰 적격 컬럼 하나**를 골라 압축하거나 TOAST 테이블로 내보내고, 행 데이터가 `TOAST_TUPLE_TARGET` 아래로 내려가는 순간 멈춘다.

## 내부 동작

### 1. 언제 토스터가 불리나 — 행 단위 임계값

`heapam.c`의 삽입 경로는 `HeapTupleHasExternal(tup) || tup->t_len > TOAST_TUPLE_THRESHOLD`일 때 토스터를 부른다. UPDATE 경로도 `newtup->t_len > TOAST_TUPLE_THRESHOLD`로 같은 비교를 한다. 비교 대상은 **튜플 길이 `t_len`**이지 특정 컬럼 크기가 아니다.

임계값은 `heaptoast.h`에서 이렇게 정의된다.

```c
#define MaximumBytesPerTuple(tuplesPerPage) \
    MAXALIGN_DOWN((BLCKSZ - \
        MAXALIGN(SizeOfPageHeaderData + (tuplesPerPage) * sizeof(ItemIdData))) \
        / (tuplesPerPage))
#define TOAST_TUPLES_PER_PAGE      4
#define TOAST_TUPLE_THRESHOLD      MaximumBytesPerTuple(TOAST_TUPLES_PER_PAGE)
#define TOAST_TUPLE_TARGET         TOAST_TUPLE_THRESHOLD
#define TOAST_TUPLES_PER_PAGE_MAIN 1
#define TOAST_TUPLE_TARGET_MAIN    MaximumBytesPerTuple(TOAST_TUPLES_PER_PAGE_MAIN)
```

뜻은 "한 페이지에 튜플 4개가 들어가게 하라"이다. 8KB 블록이면 대략 `(8192 − 헤더·line pointer 4개) / 4`라서 docs가 말하는 "보통 2kB"가 된다. MAIN 전용 목표는 "페이지에 1개"라 거의 페이지 전체 크기다. 이 차이가 아래 4패스 중 마지막 패스의 성격을 정한다.

### 2. 4패스 루프 (heap_toast_insert_or_update)

먼저 `maxDataLen = RelationGetToastTupleTarget(rel, TOAST_TUPLE_TARGET) − hoff`를 계산한다(`hoff` = MAXALIGN된 튜플 헤더 + null 비트맵). 테이블별 `toast_tuple_target` 옵션이 여기서 반영된다. 그다음 소스 주석에 적힌 순서대로 돈다.

```
           ┌───────────── while (data_size > maxDataLen) ─────────────┐
 Pass 1    │ 대상: EXTENDED/EXTERNAL, 아직 압축 안 됐고 INCOMPRESSIBLE 아님 │
           │ biggest = 가장 큰 컬럼                                       │
           │  EXTENDED → 압축 시도 / EXTERNAL → INCOMPRESSIBLE 표시        │
           │  압축 후에도 그 값 하나가 maxDataLen 초과 → 즉시 외부화       │
           └──────────────────────────────────────────────────────────┘
 Pass 2    while (> maxDataLen && toast 테이블 있음):
             EXTENDED/EXTERNAL 중 가장 큰 인라인 값 → 외부화
 Pass 3    while (> maxDataLen):
             MAIN 중 가장 큰 값 → 압축 시도
 ---- maxDataLen = TOAST_TUPLE_TARGET_MAIN − hoff  (목표를 페이지 1개 크기로 완화)
 Pass 4    while (> maxDataLen && toast 테이블 있음):
             MAIN 중 가장 큰 값 → 외부화 (최후의 수단)
```

알아둘 점:

- **탐욕적(greedy)·컬럼 하나씩.** 매 반복마다 `heap_compute_data_size()`로 행 크기를 다시 재고, 넘으면 다음으로 큰 컬럼을 고른다. 행이 목표 아래로 내려가면 나머지 컬럼은 손대지 않는다. 그래서 같은 테이블에서도 행마다 어떤 컬럼이 압축·외부화되는지가 다르다.
- **Pass 1의 "즉시 외부화".** 압축해도 그 값 혼자 목표를 넘으면 바로 밖으로 내보낸다. 주석에 따르면 "긴 필드 1개 + 짧은 필드 여러 개"인 경우에 짧은 필드까지 압축하지 않으려는 최적화다.
- **Pass 4 직전에 목표가 커진다.** 그래서 docs가 MAIN을 "압축은 허용, 외부 저장은 안 함(실제로는 다른 방법이 없을 때만 함)"이라고 설명한다.

### 3. "가장 큰 컬럼"을 고르는 규칙 (toast_tuple_find_biggest_attribute)

```c
biggest_size = MAXALIGN(TOAST_POINTER_SIZE);       // 시작값이 포인터 크기
if (for_compression) skip_colflags |= TOASTCOL_INCOMPRESSIBLE;
for each attr:
    skip if IGNORE/INCOMPRESSIBLE, 이미 external, (압축 패스면) 이미 compressed
    skip if storage 패스 조건 불일치 (MAIN vs EXTENDED/EXTERNAL)
    if (tai_size > biggest_size) pick
```

**후보의 하한이 TOAST 포인터 크기**라는 점이 중요하다. 포인터보다 작은 값을 외부화하면 오히려 커지므로 아예 후보가 되지 않는다. docs에 따르면 디스크 TOAST 포인터는 값 크기와 무관하게 18바이트다. (master에는 chunk_id를 8바이트 OID로 쓰는 `TOAST_OID8_POINTER_SIZE` 분기도 있지만, PG18 docs 기준 설명은 18바이트다.)

### 4. 압축이 "실패"로 처리되는 조건

`toast_tuple_try_compression()`은 `toast_compress_datum()`이 NULL을 돌려주면 그 컬럼에 `TOASTCOL_INCOMPRESSIBLE`을 붙이고, 이후 압축 패스에서 건너뛴다. NULL이 되는 경우는 두 가지다.

1. **pglz 전략 기준 미달.** `pg_lzcompress.c`의 기본 전략: 32바이트 미만은 압축하지 않음, 25% 이상 줄어야 함, 처음 1KB 안에서 매치를 못 찾으면 포기.
2. **실제 이득이 2바이트 이하.** `VARSIZE(tmp) < valsize - 2`일 때만 성공으로 친다. 주석에 따르면 압축 형식은 4바이트 헤더와 정렬 패딩(최대 3바이트)이 붙고, 짧은 비압축 값은 1바이트 헤더에 패딩도 없을 수 있어서다.

### 5. varlena 헤더가 상태를 인코딩한다

docs §66.2에 따르면 TOAST는 varlena 길이 워드에서 2비트를 가져다 쓴다(그래서 값 하나의 상한이 1GB). 상태는 이렇게 갈린다.

| 헤더 비트 | 의미 |
|---|---|
| 둘 다 0 | 일반 4바이트 헤더, 비압축 인라인 |
| 최하/최상위 비트 1 | 1바이트 헤더(127바이트 미만 짧은 값, 정렬 없음) |
| 1바이트 헤더인데 나머지 비트 0 | TOAST 포인터(종류는 둘째 바이트) |
| 첫 비트 0, 인접 비트 1 | 인라인 압축, 나머지 비트 = 압축 후 크기 |

외부 값은 (압축 뒤) 약 2000바이트(`TOAST_MAX_CHUNK_SIZE`, 청크 4개가 한 페이지에 들어가게 정해짐) 단위로 잘려서 TOAST 테이블에 `(chunk_id, chunk_seq, chunk_data)` 행으로 저장되고, `(chunk_id, chunk_seq)` 유니크 인덱스로 찾는다. 외부 값이 압축됐는지는 헤더가 아니라 포인터 안의 정보로 판단한다.

## 검증

PostgreSQL 14 이상 psql에서 재현할 수 있다(`pg_column_compression`은 14부터 있다).

```sql
CREATE TABLE t (id int, a text, b text);
-- (1) 압축 잘 되는 3KB 값: 행 > 임계값 → Pass 1에서 압축만으로 해결, 외부화 없음
INSERT INTO t VALUES (1, repeat('x', 3000), 'short');
-- (2) 압축 안 되는 3KB 값: INCOMPRESSIBLE → Pass 2에서 외부화
INSERT INTO t VALUES (2, (SELECT string_agg(md5(g::text), '') FROM generate_series(1,94) g), 'short');
-- (3) 1.5KB 두 개: 각 값은 작아도 행 합계가 임계값을 넘는다
INSERT INTO t VALUES (3, (SELECT string_agg(md5(g::text), '') FROM generate_series(1,47) g),
                         (SELECT string_agg(md5((g+100)::text), '') FROM generate_series(1,47) g));

SELECT id, pg_column_size(a) a_sz, pg_column_compression(a) a_cmp,
           pg_column_size(b) b_sz, octet_length(a) a_raw
FROM t ORDER BY id;

-- 외부화된 청크 직접 보기
SELECT reltoastrelid::regclass FROM pg_class WHERE relname = 't';
SELECT chunk_id, chunk_seq, length(chunk_data) FROM pg_toast.pg_toast_<oid> ORDER BY 1,2;
```

볼 것:
- id=1: `a_cmp`가 `pglz`(또는 `lz4`), `a_sz`가 수십 바이트이고, TOAST 테이블엔 해당 청크가 없다.
- id=2: `a_cmp`가 NULL, `a_sz`가 3000 근처(외부 값은 `pg_column_size`가 저장된 크기를 보여준다)이고, TOAST 테이블에 chunk_seq 0,1 두 행이 있다.
- id=3: 두 값 중 **하나만** 외부화되고, 나머지 하나는 인라인으로 남는 것을 볼 수 있다. 하나를 빼면 행이 목표 아래로 내려가서 루프가 멈추기 때문이다.
- `ALTER TABLE t SET (toast_tuple_target = 4080);`로 바꾼 뒤 같은 INSERT를 반복하면 외부화되는 행이 줄어든다(Pass 1~3의 `maxDataLen`이 커진다).

## 잘못 알고 있던 것

- **"값이 2KB를 넘으면 TOAST된다."** → 기준은 행이다. 1.5KB 값도 행이 크면 압축·외부화될 수 있고, 3KB 값도 압축이 잘 되면 본 테이블에 인라인으로 남는다. 행이 작으면 큰 값도 그대로 있다(임계값 비교가 `t_len`이다).
- **"EXTERNAL로 바꾸면 무조건 밖으로 나간다."** → EXTERNAL은 압축을 금지할 뿐, 외부화 여부는 여전히 행 크기 루프가 정한다. docs에 따르면 이 전략의 장점은 비압축 외부 값에 `substring`할 때 필요한 청크만 읽는다는 점이다.
- **"UPDATE하면 큰 값도 다시 쓰인다."** → docs에 따르면 바뀌지 않은 외부 값은 포인터가 그대로 유지돼서, TOAST 비용이 들지 않는다.

## 더 파고들 만한 것

- `pglz` vs `lz4`(`default_toast_compression`)의 압축률·속도 차이.
- 디토스트 비용: `SELECT *`가 외부 값을 전부 가져오는 경로와 TOAST 테이블의 VACUUM/블로트.

## 참고

- PostgreSQL 18 Docs §66.2 TOAST — https://www.postgresql.org/docs/current/storage-toast.html
- postgres master: `src/backend/access/heap/heaptoast.c`, `src/backend/access/table/toast_helper.c`, `src/include/access/heaptoast.h`, `src/backend/access/common/toast_internals.c`, `src/common/pg_lzcompress.c`
