# TCP SACK 손실 복구: scoreboard와 NextSeg()가 재전송 순서를 정하는 법

> **Primary source:** RFC 2018 (TCP Selective Acknowledgment Options) §2~§4 / RFC 6675 (A Conservative Loss Recovery Algorithm Based on Selective Acknowledgment (SACK) for TCP) §2~§5
> **Secondary:** RFC 5681 (TCP Congestion Control)
> **Date:** 2026-08-17
> **Status:** draft
> 블로그: https://velog.io/@jungseonw00/tcp-sack-scoreboard-nextseg

## 왜 봤나

- "SACK를 켜면 TCP가 알아서 손실난 세그먼트만 재전송한다"는 설명은 절반만 맞다. RFC 2018은 receiver가 "무엇을 받았는지"를 sender에게 알려주는 **옵션 포맷**만 정의하고, 그 정보로 "무엇을 언제 재전송할지"를 정하는 **의사결정 알고리즘**은 별도 문서인 RFC 6675(옛 RFC 3517)의 몫이다. 이 둘을 하나로 뭉뚱그리면 "SACK 정보가 왔는데 왜 그 세그먼트가 아직도 재전송 안 되지?" 같은 질문에 답할 수 없다.
- cumulative ACK만 쓰는 고전 TCP는 한 윈도우에 여러 세그먼트가 빠지면 RTT당 하나씩만 알아낼 수 있다는 구조적 한계가 있고, SACK+scoreboard 조합이 이를 어떻게 깨는지 인과 사슬을 끝까지 보고 싶었다.

## 핵심 한 문장

> SACK 옵션(RFC 2018)은 receiver가 수신 큐의 비연속 블록을 advisory하게 알려주는 통신 프로토콜일 뿐이고, sender는 그 정보를 scoreboard에 누적해 `IsLost()`로 손실을 판정하고 `NextSeg()`의 5단계 우선순위로 다음 전송 대상을 고르는 **별도의 상태 기계**(RFC 6675)를 돌린다.

## 내부 동작

### 1. SACK 옵션 자체의 포맷 (RFC 2018 §2~§3)

```
TCP Sack-Permitted Option (SYN에서만 교환, Kind=4):
+---------+---------+
| Kind=4  | Length=2|
+---------+---------+

TCP SACK Option (연결 성립 후, Kind=5):
+--------+--------+--------+--------+
| Kind=5 | Length |  Left Edge #1   |
+--------+--------+--------+--------+
|          Right Edge #1            |
+--------+--------+--------+--------+
|                ...                |
+--------+--------+--------+--------+
```

- 블록 하나 = Left Edge/Right Edge 32비트 시퀀스 번호 쌍. n개 블록이면 `length = 8n + 2` 바이트이고, TCP 옵션 공간은 40바이트가 상한이라 **최대 4블록**(타임스탬프 옵션과 함께 쓰면 10+2바이트를 먼저 소모하므로 **최대 3블록**)까지만 실을 수 있다. 즉 손실 패턴이 복잡할수록 한 ACK에 다 못 싣고 여러 ACK에 걸쳐 정보가 나눠진다.
- Sack-Permitted은 SYN에서만 협상되고 이후 세그먼트에서는 절대 보내면 안 된다(RFC 2018 §2 MUST NOT).
- SACK은 "이 블록을 받았다"는 advisory 신호일 뿐, ACK 번호(cumulative acknowledgment)의 의미를 바꾸지 않는다 — receiver가 나중에 그 데이터를 버려도(reneging) 프로토콜 위반이 아니다.

### 2. Sender가 유지하는 상태 변수 (RFC 6675 §2)

| 변수 | 의미 |
|---|---|
| `HighACK` | 누적 ACK된 최고 시퀀스 |
| `HighData` | 지금까지 전송한 최고 시퀀스 |
| `HighRxt` | 이번 recovery 구간에서 재전송한 최고 시퀀스 |
| `RescueRxt` | "구조용" 재전송으로 보낸 최고 시퀀스 |
| `Pipe` | in-flight로 추정되는 바이트 수 |
| `DupAcks` | 마지막 cumulative ACK 이후 누적된 duplicate ACK 수 |
| `DupThresh` | 손실 판정 임계치, RFC 5681 기준 **3** |

RFC 6675의 duplicate ACK 정의는 RFC 5681의 고전적 정의와 다르다: 새 데이터를 나르거나 광고 윈도우를 바꾸더라도, `HighACK`~`HighData` 사이의 아직 안 알려진(un-SACKed) 옥텟을 새로 SACK하는 세그먼트면 duplicate ACK로 센다.

### 3. scoreboard와 `IsLost()` / `SetPipe()`

scoreboard는 각 옥텟을 SACKed/un-SACKed로 마킹하는 자료구조다. `Update()`가 들어오는 모든 ACK/SACK마다 마킹을 갱신한다.

```
IsLost(SeqNum):
  return true  if  (SeqNum 위로 도착한 비연속 SACKed 구간 수 >= DupThresh)
             or  (SeqNum 위로 SACKed된 바이트 수 > (DupThresh-1) * SMSS)
  else false
```

즉 **SACK 블록 하나 왔다고 바로 손실로 보지 않는다.** DupThresh(기본 3)개의 비연속 구간, 또는 그에 상응하는 바이트량이 쌓여야 "이 아래 옥텟은 유실됐다"고 판정한다 — 이게 고전 Reno의 "3 duplicate ACK → 즉시 재전송"과 결이 비슷하지만 판정 대상이 개별 세그먼트 단위로 정밀해진 것.

`SetPipe()`는 `HighACK`~`HighData` 구간을 훑으며 `Pipe`를 다시 계산한다: un-SACKed면서 `IsLost()`가 false인 옥텟은 "아직 네트워크에 떠 있다"고 보고 pipe++, 이미 `HighRxt` 이하로 재전송된 옥텟도 pipe++ — RFC 6675는 이 부분에서 "재전송했지만 loss로 확정되지 않은 옥텟은 이 계산에서 **두 번 카운트된다**"고 명시적으로 인정한다. Pipe가 부풀려지는 쪽으로 치우친 보수적(conservative) 설계다.

### 4. `NextSeg()` 5단계 우선순위

```
1) HighRxt보다 크고, 어떤 SACK 블록의 커버 범위 안에 있고, IsLost()==true
   인 가장 작은 S2 → 그 세그먼트 재전송 (loss 확정)
2) 1이 없고 새 데이터 + 광고 윈도우 여유 있음 → HighData+1부터 새 데이터 전송
3) 1,2 없지만 (1.a)(1.b)만 만족(=SACK 범위 안이지만 IsLost는 false)하는
   S3 있음 → "SHOULD" 재전송 (last resort)
4) 그마저 없고 아직 un-SACKed 데이터가 남음 → recovery 진입당 1회 한정
   "rescue retransmission" (ACK 클록 정지 방지, HighRxt는 갱신 안 함)
5) 다 실패 → 실패 반환
```

3, 4번은 "확신은 없지만 ACK 클록을 살려두기 위한 최후 수단"이라는 점이 원문에 명시돼 있다 — 재전송 성공 시 두 카피 중 어느 쪽이 도착했는지 sender가 구분 못 해 pipe를 과소평가할 수 있다는 트레이드오프까지 인정한다.

### 5. Loss recovery 진입 (RFC 6675 §5)

`DupAcks >= DupThresh`이거나 `IsLost(HighACK+1) == true`면 fast retransmit 진입:

```
RecoveryPoint = HighData          // 이 시퀀스까지 누적 ACK되면 recovery 종료
ssthresh = cwnd = FlightSize / 2  // RFC 5681과 동일, congestion control과 직교
HighACK+1 세그먼트 재전송, HighRxt·RescueRxt를 그 최고 시퀀스로 설정
SetPipe() 재계산
```

`ssthresh`/`cwnd` 절반 축소는 congestion control(RFC 5681) 규칙 그대로 가져다 쓸 뿐, SACK 기반 loss recovery 자체는 "무엇을 재전송할지"만 결정하고 "얼마나 보낼지"는 별개 계층에 위임한다는 점이 원문에서 반복 강조된다.

## 검증

- `tcpdump -i <iface> 'tcp[13] & 0x10 != 0' -vv` 로 ACK 플래그가 선 패킷을 캡처해 Wireshark에서 "TCP Option - SACK"으로 파싱되는 Left/Right Edge 필드를 직접 까볼 수 있다. 재전송 구간에서 이 필드가 어떻게 채워지는지 확인하면 §3 포맷을 그대로 확인하는 셈이다.
- Linux 커널 소스의 `net/ipv4/tcp_input.c` 안에 `tcp_sacktag_write_queue()`, `tcp_is_sackblock_valid()` 같은 함수명이 이 RFC 6675 scoreboard 로직의 실제 구현 지점이라는 것은 공개된 커널 소스 트리 구조로 확인 가능하다(정확한 라인 번호는 커널 버전마다 바뀌므로 파일명 수준까지만 단정한다).
- `ss -ti` 출력의 `retrans`, `sacked`, `lost` 필드가 바로 scoreboard가 추적하는 상태값과 대응된다 — 부하 중인 연결에서 관찰하면 개념과 실측치를 맞춰볼 수 있다.

의사 결정 흐름을 코드로 옮기면 다음과 같은 모양이 된다(교육용 축약, 실제 커널 구현과 1:1 대응 아님):

```java
boolean isLost(long seqNum, NavigableMap<Long, Long> sackedRanges,
               int dupThresh, int smss) {
    int discontiguous = 0;
    long sackedBytesAbove = 0;
    for (var e : sackedRanges.tailMap(seqNum, false).entrySet()) {
        discontiguous++;
        sackedBytesAbove += e.getValue() - e.getKey();
    }
    return discontiguous >= dupThresh
        || sackedBytesAbove > (long) (dupThresh - 1) * smss;
}
```

## 잘못 알고 있던 것

- **"SACK로 받았다고 표시된 데이터는 재전송 버퍼에서 지워도 된다"** → 틀림. RFC 6675 `Update()`에 "SACK 정보는 advisory이므로 cumulative ACK 전까지 재전송 버퍼에서 지우면 안 된다(MUST NOT)"고 못박혀 있다. Receiver가 SACK했던 데이터를 나중에 폐기(renege)할 수 있기 때문이며, 이 가능성 때문에 SACK은 "확정"이 아니라 "참고 정보"로 취급된다.
- **"SACK 블록 하나 오면 그 구간은 즉시 손실로 보고 재전송한다"** → 틀림. `IsLost()`는 DupThresh(기본 3) 임계치를 넘겨야 true를 반환하고, `NextSeg()`도 5단계 우선순위 중 조건을 만족해야 실제 전송 대상이 된다. 첫 SACK 정보만으로 재전송이 트리거되지 않는다.
- **"3 duplicate ACK 재전송(고전 fast retransmit)"과 "SACK 기반 loss recovery"가 같은 절차** → 다르다. RFC 6675의 duplicate ACK 정의 자체가 RFC 5681보다 넓다(새 데이터/윈도우 변경이 있어도 새 SACK 정보가 있으면 duplicate ACK로 카운트). 그리고 한 번의 recovery 안에서 여러 세그먼트를 scoreboard 기반으로 순차 재전송할 수 있다는 점이 고전 Reno(라운드당 하나)와의 핵심 차이다.

## 더 파고들 만한 것

- D-SACK(Duplicate SACK, RFC 2883): 이미 받은 데이터가 또 도착했을 때(불필요한 재전송) 이를 알리는 확장. 이번 노트의 "손실 탐지" 방향과 반대로 "잘못된 재전송 탐지"를 다룬다.
- Congestion control 알고리즘(CUBIC, BBR)이 RFC 6675의 pipe algorithm과 어떻게 상호작용/직교하는지 — 원문이 반복해서 "이 문서는 congestion control과 별개"라고 선을 긋는 이유를 더 깊이 볼 만하다.

## 참고

- RFC 2018 — TCP Selective Acknowledgment Options
- RFC 6675 — A Conservative Loss Recovery Algorithm Based on Selective Acknowledgment (SACK) for TCP (obsoletes RFC 3517)
- RFC 5681 — TCP Congestion Control

---

<!-- velog 글로 발전 후 -->
**velog 글:** {link}
