# Linux listen backlog는 무엇을 세는가 — SYN 큐·accept 큐 두 관문과 오버플로 시 조용히 버려지는 3번째 ACK

> **Primary source:** Linux 커널 소스(torvalds/linux master) — `net/socket.c`, `net/ipv4/af_inet.c`, `include/net/sock.h`, `include/net/inet_connection_sock.h`, `net/ipv4/tcp_input.c` `tcp_conn_request()`, `net/ipv4/tcp_minisocks.c` `tcp_check_req()`, `net/ipv4/tcp_ipv4.c`, `net/ipv4/inet_connection_sock.c`, `net/ipv4/tcp_diag.c`
> **Secondary:** listen(2) man page (man-pages 6.19), `Documentation/networking/ip-sysctl.rst`
> **Date:** 2026-09-30
> **Status:** draft

## 왜 봤나

- `backlog`는 흔히 "동시 연결 수"나 "SYN 대기열 크기"로 오해된다. 실제로는 **두 관문**(핸드셰이크 중인 요청 / 완성됐지만 `accept()` 안 된 소켓)이 다른 카운터로 관리되고 backlog는 둘에 다르게 관여한다.
- accept 큐가 넘칠 때 커널이 RST 없이 **3번째 ACK를 무시**한다는 점이 "connect는 성공인데 첫 요청이 멈춘다"는 현상을 설명한다.

## 핵심 한 문장

> `backlog`는 `min(backlog, somaxconn)`으로 잘려 `sk_max_ack_backlog` 하나에 저장되고, 커널은 이 값을 **완성된 연결(accept 큐)의 상한**이자 **SYN 요청 수(qlen)의 쿠키 전환 임계값**으로 함께 쓰며, 두 비교 모두 `>`라서 실제로는 backlog+1개까지 들어간다.

## 내부 동작

### 1) listen(): backlog가 저장되는 곳

`__sys_listen_socket()`은 `(unsigned int)backlog > somaxconn`이면 조용히 `somaxconn`으로 자르고, `__inet_listen_sk()`가 `WRITE_ONCE(sk->sk_max_ack_backlog, backlog)`로 저장한다. 이미 LISTEN이면 backlog만 조정된다. somaxconn 기본값은 Linux 5.4부터 4096, 이전은 128이다(listen(2)).

### 2) 두 관문과 세 개의 숫자

```
 client            server (LISTEN socket sk)
  SYN  ───────▶  tcp_conn_request()
                   ├─ [관문 A] qlen > sk_max_ack_backlog ? → syncookie 또는 drop
                   ├─ [관문 B] sk_ack_backlog > sk_max_ack_backlog ? → SYN drop
                   └─ request_sock 생성 (SYN_RECV, qlen++)
       ◀─────── SYN-ACK
  ACK  ───────▶  tcp_check_req() → syn_recv_sock()
                   ├─ [관문 B] sk_acceptq_is_full ? → listen_overflow
                   └─ child sock 생성 → inet_csk_reqsk_queue_add()
                        rskq_accept_head/tail 연결리스트에 append, sk_ack_backlog++
  app  accept()  ◀─ 큐 head에서 꺼냄, sk_ack_backlog--
```

| 숫자 | 위치 | 의미 |
| --- | --- | --- |
| `sk_max_ack_backlog` | `struct sock` | `min(backlog, somaxconn)` |
| `sk_ack_backlog` | `struct sock` | accept 대기 중인 완성 소켓 수 (`sk_acceptq_added/removed`로 ±1) |
| `qlen` | `icsk_accept_queue`(`request_sock_queue`)의 atomic | SYN_RECV 요청 수 (`reqsk_queue_len()`) |

accept 큐는 `rskq_lock` 아래 `rskq_accept_head`/`tail`로 잇는 단일 연결리스트(FIFO)이고, "SYN 큐"의 크기는 `qlen` 카운터로 관리된다.

### 3) 관문 비교는 `>` — backlog+1

```c
// include/net/sock.h
static inline bool sk_acceptq_is_full(const struct sock *sk)
{
	return READ_ONCE(sk->sk_ack_backlog) > READ_ONCE(sk->sk_max_ack_backlog);
}
// include/net/inet_connection_sock.h
static inline int inet_csk_reqsk_queue_is_full(const struct sock *sk)
{
	return inet_csk_reqsk_queue_len(sk) > READ_ONCE(sk->sk_max_ack_backlog);
}
```

`sock.h`에는 "`>=`여야 한다고 생각하면 commit 64a146513f8f ("[NET]: Revert incorrect accept queue backlog changes.")를 보라"는 주석이 붙어 있다. 즉 off-by-one처럼 보이는 `>`는 의도적으로 유지된 것이다. 결과적으로 `backlog=0`이어도 완성 소켓 1개는 들어간다.

### 4) SYN 도착: `tcp_conn_request()`의 판정 순서

1. `isn != 0`(TIME_WAIT 소켓과 매칭된 SYN)이면 아래 한도·쿠키 검사를 건너뛴다.
2. `tcp_syncookies == 2`이거나 `inet_csk_reqsk_queue_is_full()`이면 `tcp_syn_flood_action()` → syncookies 켜짐: `want_cookie=true`(`TCPReqQFullDoCookies`++), 꺼짐: `TCPReqQFullDrop`++ 후 drop. 첫 발생 시 "Possible SYN flooding on port …" 로그를 남긴다.
3. `sk_acceptq_is_full()`이면 `LINUX_MIB_LISTENOVERFLOWS`++ 후 **SYN 자체를 drop**. accept 큐가 꽉 찼으면 새 핸드셰이크를 시작조차 하지 않는다.
4. 쿠키가 아닌 경우, **syncookies가 꺼져 있을 때만** `tcp_max_syn_backlog`가 등장한다: `max_syn_backlog - qlen < max_syn_backlog >> 2`이고 `tcp_peer_is_proven()`이 아니면 drop. 즉 남은 여유가 1/4 미만이면 "살아 있음이 입증된 목적지"에게만 마지막 1/4을 내준다(소스 주석 "last quarter of backlog is filled with destinations, proven to be alive").

정리하면 기본값(`tcp_syncookies=1`)에서 SYN 단계의 실질 임계값은 `tcp_max_syn_backlog`가 아니라 **`sk_max_ack_backlog`**(쿠키 전환 시점)다. listen(2)도 "syncookies가 켜져 있으면 논리적 최대 길이가 없고 이 설정은 무시된다"고 적는다.

### 5) 3번째 ACK: accept 큐 오버플로의 상태 전이

`tcp_check_req()`가 ACK를 검증한 뒤 `syn_recv_sock()`(IPv4는 `tcp_v4_syn_recv_sock()`)을 부르고, 여기서 `sk_acceptq_is_full()`이면 `exit_overflow`: `LISTENOVERFLOWS`++ → `tcp_listendrop()`(`LISTENDROPS`++) → `NULL` 반환. `tcp_check_req()`는 `listen_overflow`로 가서:

```c
if (!READ_ONCE(sock_net(sk)->ipv4.sysctl_tcp_abort_on_overflow)) {
	inet_rsk(req)->acked = 1;   // ACK는 받았다고 표시만 하고
	return NULL;                // 세그먼트는 버린다 (RST 없음)
}
// abort_on_overflow=1 이면 embryonic_reset: RST 전송
```

```
client: SYN_SENT ──SYN-ACK 수신──▶ ESTABLISHED (connect() 성공!)
server: request_sock SYN_RECV, acked=1 (child 소켓 없음)
        └─ reqsk 타이머 → syn_ack_recalc(): defer_accept 없으면 resend=1
           → SYN-ACK 재전송 → client가 ACK 재전송 → 그때 큐에 자리가 있으면 child 생성
           → num_timeout >= tcp_synack_retries 면 request 만료
```

ip-sysctl 문서는 `tcp_abort_on_overflow` 기본 FALSE의 이유를 "burst로 인한 overflow라면 회복된다"고 설명한다.
## 검증

리눅스에서 accept 하지 않는 서버를 띄워 accept 큐를 일부러 채운다.

```python
# backlog_demo.py — 서버: listen(1) 후 accept() 하지 않음
import socket, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 9999)); s.listen(1)
time.sleep(600)
```

```bash
python3 backlog_demo.py &
nstat -n                                   # 카운터 기준점 리셋
for i in 1 2 3 4; do (sleep 30 | nc 127.0.0.1 9999 &) ; done
ss -lnt 'sport = :9999'        # LISTEN 행: Recv-Q=sk_ack_backlog, Send-Q=sk_max_ack_backlog
ss -tan 'dport = :9999'        # 클라이언트 쪽 상태
nstat -az TcpExtListenOverflows TcpExtListenDrops
```

확인 포인트:
- LISTEN 행에서 Send-Q 1, Recv-Q가 **2**까지 오르면 `>` 비교(backlog+1)가 보인다. 두 값의 의미는 `net/ipv4/tcp_diag.c`(`idiag_rqueue = sk_ack_backlog`, `idiag_wqueue = sk_max_ack_backlog`)에 있다.
- 순차 연결이면 세 번째 SYN은 accept 큐가 이미 찬 뒤 도착해 **SYN 단계에서 drop**된다: 3·4번째 클라이언트는 SYN-SENT로 남고 `ListenOverflows`가 증가한다.
- 3번째 ACK 무시 경로(클라이언트 ESTABLISHED / 서버 SYN-RECV + SYN-ACK 재전송)는 여러 핸드셰이크가 **동시에** 진행 중일 때 큐가 차야 나오므로 burst에서 관찰된다(타이밍 의존).
- `listen(1)`을 `listen(100000)`으로 바꿔도 Send-Q는 `somaxconn`에서 멈춘다.

## 잘못 알고 있던 것

- **"backlog = SYN 대기열(반쯤 열린 연결) 크기"** → Linux 2.2 이후 backlog는 **완성된 연결** 큐 길이다(listen(2)). 다만 같은 `sk_max_ack_backlog`가 qlen의 쿠키 전환 임계값으로도 쓰이고, `tcp_max_syn_backlog`는 syncookies off일 때 "마지막 1/4 보호"에만 관여한다. 그래서 `tcp_max_syn_backlog`만 올려서는 효과가 없고 애플리케이션 backlog와 `somaxconn`을 함께 봐야 한다.
- **"큐가 넘치면 클라이언트가 곧바로 ECONNREFUSED를 받는다"** → 기본 설정(`tcp_abort_on_overflow=0`)에서 커널은 SYN을 조용히 drop하거나(accept 큐가 이미 꽉 찬 상태의 SYN) 3번째 ACK를 무시한다. 후자는 클라이언트 입장에서는 `connect()`가 **성공**한 것이라, 증상은 거절이 아니라 "첫 요청이 수 초씩 멈추다 되거나 타임아웃"으로 나타난다. RST로 즉시 실패시키려면 `tcp_abort_on_overflow=1`이지만, 문서는 burst 회복을 포기하는 것이라 권하지 않는다.

## 더 파고들 만한 것

- SYN cookie 인코딩: MSS 인덱스·타임스탬프 옵션에 wscale/SACK을 싣는 방식과 쿠키 모드에서 잃는 TCP 옵션.
- `TCP_DEFER_ACCEPT`: `syn_ack_recalc()`의 `rskq_defer_accept` 분기 — 데이터가 올 때까지 child 생성을 미루는 상태 전이.

## 참고

- listen(2) — https://man7.org/linux/man-pages/man2/listen.2.html
- ip-sysctl — https://github.com/torvalds/linux/blob/master/Documentation/networking/ip-sysctl.rst (`tcp_abort_on_overflow`, `tcp_max_syn_backlog`, `tcp_syncookies`, `tcp_synack_retries`)
- 커널 소스 — https://github.com/torvalds/linux (2026-09-30 master 기준, 줄 번호 대신 함수명)
