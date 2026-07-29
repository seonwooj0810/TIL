# Kafka 로그 컴팩션과 log cleaner: 키별 "최신 값 하나"를 남기는 방법

> **Primary source:** Apache Kafka Documentation — Log Compaction (§Design) / Kafka 소스 `LogCleaner.scala`·`Cleaner`·`SkimpyOffsetMap`·`LogCleanerManager`
> **Secondary:** KIP-58 (Make Log Compaction point configurable), Confluent "Kafka Internals" 문서
> **Date:** 2026-07-29
> **Status:** draft
> 블로그: https://velog.io/@jungseonw00/kafka-log-compaction-log-cleaner

## 왜 봤나

- `__consumer_offsets`나 CDC 스냅샷 토픽처럼 "키별 최신 상태만 필요한" 토픽이 왜 무한히 커지지 않는지 궁금했다.
- 막연히 "compaction = 오래된 메시지 삭제"라고 알고 있었는데, retention(시간 기반 삭제)과 뭐가 다른지, 삭제(tombstone)는 어떻게 사라지는지 설명하지 못했다.

## 핵심 한 문장

> 로그 컴팩션은 **파티션 로그의 tail 구간을 key→마지막 offset 맵으로 스캔한 뒤 다시 쓰면서, 각 키의 "가장 최근 레코드 하나"만 남기는** 백그라운드 재작성 과정이다. offset은 절대 재부여하지 않고 구멍만 생긴다.

## 내부 동작

### 로그의 두 구간: clean / dirty

컴팩션 대상 토픽(`cleanup.policy=compact`)의 각 파티션 로그는 개념적으로 두 부분으로 나뉜다.

```
     cleaned (이미 컴팩션됨)        dirty (아직 미처리)      active seg
 |------------------------------|------------------------|===========|
 0                          cleaner point            log end offset
 └ 키가 이미 유일화된 구간 ┘   └ 중복 키가 남아있는 구간 ┘  └ 쓰기 중 ┘
```

- **cleaner point(= cleaner checkpoint)**: `cleaner-offset-checkpoint` 파일에 파티션별로 저장되는 "여기까지 컴팩션 완료" offset. 다음 라운드는 이 지점부터 dirty 끝까지만 본다.
- **active segment는 절대 컴팩션하지 않는다.** 지금 append 중인 세그먼트는 건드리지 않으므로, 방금 쓴 같은 키의 두 레코드가 잠깐 공존할 수 있다. 즉 컴팩션은 "언젠가는 유일해진다"는 최종 보장이지 즉시성 보장이 아니다.

### 언제 도는가 — dirty ratio

log cleaner 스레드(`log.cleaner.threads`, 기본 1)는 매 라운드마다 **가장 더러운 로그**를 고른다. 지저분함의 척도가 dirty ratio다.

```
dirty ratio = dirtyBytes / (dirtyBytes + cleanBytes)
```

`min.cleanable.dirty.ratio`(기본 0.5)를 넘는 로그만 후보가 되고, 그중 ratio가 가장 높은 것을 먼저 청소한다. 이 임계값이 컴팩션의 CPU/IO 비용과 중복 잔존량 사이의 트레이드오프 노브다 — 낮추면 더 자주 돌아 중복이 적지만 재작성 IO가 늘고, 높이면 IO는 아끼지만 오래된 중복이 오래 남는다.

### 2단계 알고리즘: OffsetMap 구축 → 재복사

`Cleaner.clean`은 dirty 구간을 두 번 훑는다.

**1단계 — build offset map.** dirty 구간을 앞에서 뒤로 스캔하며 `SkimpyOffsetMap`에 `key → 그 키가 등장한 마지막(가장 큰) offset`을 채운다. 이름이 "skimpy"인 이유: 원본 키를 저장하지 않고 **키의 MD5 해시(16B) + 8B offset = 24B 슬롯**만 오픈 어드레싱 해시테이블에 넣는다. 맵 용량은 `log.cleaner.dedupe.buffer.size`(스레드로 나눔) / 24 로 정해진다. 그래서 이 버퍼가 한 라운드에 유일화할 수 있는 키 개수의 상한이며, dirty 구간이 너무 크면 한 번에 다 못 담아 여러 세그먼트 그룹으로 쪼개 처리한다.

**2단계 — recopy & swap.** clean 구간 시작부터 dirty 끝까지 세그먼트들을 순서대로 읽으며, 각 레코드에 대해 유지/폐기를 판정해 새 세그먼트로 복사한다. 판정 규칙(핵심):

```
retain(record) 조건:
  1) offsetMap.get(record.key) <= record.offset   // 이 키의 최신이 나(또는 맵에 없음)
     └ 즉 나보다 뒤에 같은 키가 또 있으면 폐기
  2) record.value != null (tombstone 아님)
     또는  tombstone이지만 아직 delete.retention.ms 안 지남
```

여러 원본 세그먼트를 하나의 새 세그먼트로 **병합(grouping)** 하기도 한다. 작은 세그먼트들이 컴팩션으로 더 작아지므로, `segment.bytes`/`max.compaction.lag`를 넘지 않는 선에서 묶어 세그먼트 수 폭발과 파일 핸들 낭비를 막는다. 다 쓰면 원본 세그먼트를 새 것으로 원자적 교체하고 cleaner point를 dirty 끝으로 전진시킨다.

### offset은 유지, 연속성은 깨진다

컴팩션의 결정적 성질: **살아남은 레코드의 offset은 원래 값 그대로다.** 재부여하지 않는다. 그래서 컴팩션된 로그를 순차 소비하면 offset이 `5, 6, 9, 13...`처럼 **구멍(gap)** 이 생긴다. 컨슈머는 이걸 정상으로 다뤄야 하고(다음 fetch offset은 "마지막+1"), 이 offset 안정성 덕분에 컴팩션 중에도 진행 중인 컨슈머의 offset이 어긋나지 않는다.

### tombstone: 삭제를 "전파"하고 나서 지우기

`value=null` 레코드가 tombstone이다. 컴팩션은 tombstone을 만나면 그 키의 이전 값들을 전부 지운다(삭제 표현). 그런데 tombstone 자체를 즉시 없애면, 그 사이 오프라인이던 컨슈머는 "삭제됐다"는 사실을 영영 못 본다. 그래서 tombstone은 **컴팩션되어 로그의 clean 구간에 편입된 시점부터 `delete.retention.ms`(기본 24h) 동안 유지**된 뒤에야 다음 라운드에서 제거된다. 이 유예가 "모든 컨슈머가 삭제를 관측할 시간"을 보장한다.

```
상태 전이 (한 키의 생애):
  put(k,v1) → put(k,v2) → ... → put(k,vN) → delete(k=null) → (전파 대기) → 소멸
  compaction 후:      vN만 남음        →   tombstone만 남음  →  delete.retention.ms 후 완전 소멸
```

## 검증

`SkimpyOffsetMap`의 유지 판정을 소스 논리대로 따라가 본 흐름(개념 재현):

```scala
// 1단계: dirty 구간 스캔 → key의 최신 offset 기록
for (record <- dirtySegment.records)
  offsetMap.put(record.key, record.offset)   // 같은 키면 큰 offset으로 덮임

// 2단계: 전체 재복사하며 유지 판정
def shouldRetain(r: Record): Boolean = {
  val latest = offsetMap.get(r.key)           // 없으면 -1
  if (r.offset < latest) false                // 뒤에 같은 키 최신본 존재 → 폐기
  else if (r.value == null)                   // tombstone
    now - tombstoneTimestamp <= deleteRetentionMs
  else true
}
```

입력→예상: 키 A에 대해 offset 3(v1), 7(v2)이 dirty에 있으면 map[A]=7. 재복사 시 offset 3은 `3 < 7`이라 폐기, offset 7만 새 세그먼트로 복사된다. 이후 offset 12에 `A=null`이 오면 v2(7)도 폐기되고 tombstone(12)만 남았다가 24h 뒤 소멸.

## 잘못 알고 있던 것

- **"컴팩션 = 오래된 메시지 삭제(retention)"** — 아니다. `cleanup.policy`는 `delete`(시간/크기 기반 세그먼트 통째 삭제)와 `compact`(키별 최신만 유지)가 **직교하는 별개 정책**이고, `compact,delete`로 둘 다 켤 수도 있다. 컴팩션은 "시간"이 아니라 "같은 키의 더 새로운 레코드가 있는가"로 지운다.
- **"컴팩션하면 offset이 촘촘하게 다시 매겨진다"** — 아니다. offset은 불변이고 구멍이 생긴다. offset 재부여는 컨슈머 커밋과 replication을 다 깨뜨리므로 절대 하지 않는다.
- **"tombstone은 값이 없으니 바로 사라진다"** — 아니다. `delete.retention.ms` 동안 일부러 남겨 컨슈머가 삭제를 관측하게 한다. 이 값을 너무 짧게 잡으면 느린 컨슈머가 삭제 이벤트를 놓친다.

## 더 파고들 만한 것

- `__consumer_offsets` / KRaft 메타데이터 로그가 컴팩션에 의존하는 방식 (컴팩션이 곧 상태 스냅샷).
- `min.compaction.lag.ms` / `max.compaction.lag.ms`가 dirty ratio 트리거와 어떻게 상호작용하는지.
- `SkimpyOffsetMap`의 MD5 해시 충돌 확률과 그로 인한 (이론상) 오폐기 가능성.

## 참고

- Apache Kafka Documentation — Log Compaction
- Kafka 소스: `core/src/main/scala/kafka/log/LogCleaner.scala`, `LogCleanerManager.scala`, `SkimpyOffsetMap`
- KIP-58: Make Log Compaction point configurable
