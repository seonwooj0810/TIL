# Compressed Oops: 64비트 오브젝트 포인터를 32비트로 압축하는 인코딩

> **Primary source:** OpenJDK HotSpot 소스 (`src/hotspot/share/oops/compressedOops.cpp`, `compressedOops.inline.hpp`, `oops/compressedKlass.hpp`/`.cpp`, `runtime/arguments.cpp`, `utilities/globalDefinitions.hpp`, `runtime/globals.hpp`)
> **Secondary:** 없음 (버전별 세부 동작 차이는 소스 확인 범위로 한정)
> **Date:** 2026-08-14
> **Status:** draft

## 왜 봤나

- [`jvm-memory-layout.md`](./jvm-memory-layout.md)에서 남겨둔 "Compressed Class Pointers / Compressed Oops가 힙 크기에 미치는 영향" 각주를 실제로 풀어본다.
- "힙이 32GB를 안 넘으면 자동으로 압축된다"는 32GB가 **어디서 나온 숫자**인지, "compressed oops"와 "compressed class pointer"가 같은 규칙을 따르는지가 불명확했다.

## 핵심 한 문장

> Compressed Oops는 힙 안의 모든 객체가 `ObjectAlignmentInBytes`(기본 8바이트) 단위로 정렬돼 있어 64비트 포인터의 하위 비트가 항상 0이라는 성질을 이용해, 그 비트를 버리고(right-shift) 힙 베이스로부터의 오프셋만 32비트 정수(`narrowOop`)에 담는 인코딩이며, 이 덕분에 최대 32GB까지의 힙을 32비트 참조로 가리킬 수 있다.

## 내부 동작

### 1. 정렬이 압축을 가능하게 만드는 전제

`runtime/globals.hpp`의 플래그 정의(`product(int, ObjectAlignmentInBytes, 8, ... range(8, 256))`)에 따르면 `ObjectAlignmentInBytes`는 기본값 8이고, 반드시 8~256 범위의 2의 거듭제곱이어야 한다(`constraint`로 강제). `arguments.cpp`의 `set_object_alignment()`는 이 값을 그대로 `MinObjAlignmentInBytes`에 대입하고, `LogMinObjAlignmentInBytes = exact_log2(ObjectAlignmentInBytes)`를 계산한다 — 기본값 8이면 이 로그값은 3이다.

즉 힙에 배치되는 모든 객체의 시작 주소는 8의 배수다. 이 말은 **모든 유효한 오브젝트 포인터의 하위 3비트가 항상 0**이라는 뜻이고, 그 3비트는 어떤 정보도 담지 않으므로 버려도 손실이 없다. Compressed Oops는 바로 이 3비트를 우측 시프트로 잘라내고, 나머지 상위 비트만 32비트 정수(`narrowOop`)에 담는다.

### 2. 인코딩/디코딩 공식

`compressedOops.inline.hpp`의 실제 구현(발췌, 주석·assert 생략):

```cpp
inline oop CompressedOops::decode_raw(narrowOop v) {
  return cast_to_oop((uintptr_t)base() + ((uintptr_t)v << shift()));
}

inline narrowOop CompressedOops::encode_not_null(oop v) {
  uint64_t pd = (uint64_t)(pointer_delta((void*)v, (void*)base(), 1));
  assert(OopEncodingHeapMax > pd, "change encoding max if new encoding");
  narrowOop result = narrow_oop_cast(pd >> shift());
  assert(decode_raw(result) == v, "reversibility");   // 인코딩은 반드시 역연산 가능해야 함
  return result;
}
```

디코딩은 `base() + (narrowOop << shift())`, 인코딩은 `(oop − base()) >> shift()`다. `base()`와 `shift()`는 JVM 부팅 시 힙 크기에 따라 딱 한 번 정해지는 전역 상태이지 매 호출마다 계산하는 값이 아니다. 32비트 `narrowOop`가 8바이트 단위 오프셋을 담으므로 표현 가능한 힙 크기는 이론상 `2^32 × 2^3 = 2^35`바이트, 즉 32GB다.

### 3. 힙 크기에 따른 4가지 모드 — `base`/`shift`는 언제, 어떻게 정해지나

`compressedOops.cpp`의 `initialize()`가 힙 예약 크기(`heap_space.end()`)를 보고 아래 순서로 결정한다(주석 원문 그대로):

```
Unscaled  - NarrowOopHeapBaseMin + heap_size < 4GB  → 32비트 오프셋을 시프트 없이 그대로 사용
ZeroBased - NarrowOopHeapBaseMin + heap_size < 32GB → base=0, shift=3으로 인코딩
HeapBased - 그 외                                    → base=실제 힙 시작 주소, shift=3
```

핵심 조건문(간략화):

```cpp
if ((uint64_t)heap_space.end() > UnscaledOopHeapMax) {
  set_shift(LogMinObjAlignmentInBytes);         // 4GB 넘으면 시프트 필요
}
if ((uint64_t)heap_space.end() <= OopEncodingHeapMax) {
  set_base(nullptr);                            // 32GB 이하면 base=0으로 둘 수 있음
} else {
  set_base((address)heap_space.compressed_oop_base());
}
```

여기서 `UnscaledOopHeapMax`와 `OopEncodingHeapMax`는 `globalDefinitions.hpp`/`arguments.cpp`에 정의된 상수다:

- `UnscaledOopHeapMax = uint64_t(max_juint) + 1` → 정확히 `2^32`(4GB). 힙이 이보다 작으면 32비트 정수 자체로 전체 주소를 표현할 수 있어 **시프트조차 필요 없다**(`shift = 0`).
- `OopEncodingHeapMax = UnscaledOopHeapMax << LogMinObjAlignmentInBytes` → `4GB << 3 = 32GB`. 힙이 이보다 작으면 힙 시작 주소를 논리적으로 0으로 간주(`base = nullptr`)하고 시프트만으로 인코딩할 수 있다(Zero-Based).
- 힙이 32GB를 넘으면 `base`가 실제 논-널 주소가 되어, 매 인코딩/디코딩마다 덧셈/뺄셈이 추가로 들어가는 Heap-Based(또는 상위 비트가 겹치지 않으면 `DisjointBaseNarrowOop`) 모드로 떨어진다. `is_disjoint_heap_base_address()`는 `base`의 비트가 `narrowOop << shift`가 만들어내는 오프셋 범위와 겹치지 않는지를 검사하는데, 겹치지 않으면(disjoint) 덧셈 대신 OR 한 번으로 디코딩할 수 있어 더 저렴하다 — 즉 32GB를 넘겨도 힙 배치 운이 좋으면(`DisjointBaseNarrowOop`) 완전한 Heap-Based보다는 싼 경로를 탄다.

### 4. "정확히 32GB"가 아닌 이유

`arguments.cpp`의 `max_heap_for_compressed_oops()`는 이 32GB에서 한 번 더 깎아낸다:

```cpp
size_t displacement_due_to_null_page =
    align_up(os::vm_page_size(), _conservative_max_heap_alignment);
return OopEncodingHeapMax - displacement_due_to_null_page;
```

`compressedOops.cpp` 주석에 따르면 힙 베이스 바로 아래에 한 페이지를 비워두는데, 이는 "힙 베이스에 뭔가 할당될 수 있는 상황을 막고, 암묵적 null 체크(implicit null check)가 그 페이지에서 시그널을 발생시키게" 하기 위해서다. 즉 compressed-oops 모드를 유지하며 쓸 수 있는 실제 최대 힙은 32GB에서 페이지 정렬된 null-가드 영역만큼 뺀 값이다 — "32GB 미만이면 무조건 compressed oops"라는 말은 근사치일 뿐 정확한 경계값이 아니다.

### 5. Compressed Class Pointer는 별개의 인코더

`compressedKlass.hpp`는 narrow klass 포인터의 비트 수와 최대 시프트를 `UseCompactObjectHeaders` 플래그에 따라 다르게 정의한다:

```cpp
static constexpr int narrow_klass_pointer_bits_noncoh = 32;  // 기존 방식
static constexpr int narrow_klass_pointer_bits_coh    = 22;  // Compact Object Headers
static constexpr int max_shift_noncoh = 3;
static constexpr int max_shift_coh    = 10;
```

`max_klass_range_size()`는 `encoding_allows = 2^(bits + shift)`를 계산해 `4GB`와 `MIN2`를 취한다. 기존(non-compact) 방식은 `2^(32+3) = 2^35 = 32GB`로 오브젝트 오프셋과 우연히 같은 상한을 갖지만, `UseCompactObjectHeaders`(객체 헤더 축소 프로젝트)가 켜지면 `2^(22+10) = 2^32 = 4GB`로 표현 범위가 오히려 줄어든다. **오브젝트 포인터 압축과 클래스 포인터 압축은 서로 다른 `base`/`shift`/한도를 갖는 독립된 인코더**이며, `UseCompressedOops`를 켠다고 `UseCompressedClassPointers`의 한도가 자동으로 같아지는 게 아니다.

## 검증

이 repo에는 실행 환경이 없으므로, 아래는 독자가 자기 JDK에서 직접 재현 가능한 커맨드다.

```bash
# 1. 기본 정렬값이 정말 8인지 확인
java -XX:+PrintFlagsFinal -version 2>/dev/null | grep -i ObjectAlignmentInBytes
#   product int ObjectAlignmentInBytes  = 8  {product} {default}

# 2. 힙 크기별로 실제 압축 모드가 바뀌는지 확인 (compressedOops.cpp의 print_mode 로그)
java -Xmx31g -Xlog:gc+heap+coops=debug -version 2>&1 | grep -i "compressed"
java -Xmx33g -Xlog:gc+heap+coops=debug -version 2>&1 | grep -i "compressed"
#   -Xmx31g: "Zero based" 계열, -Xmx33g: "Non-zero based/disjoint" 계열 로그가 찍히는지 비교
```

또한 `System.getProperty("java.vm.compressedOopsMode")`는 `compressedOops.cpp`가 부팅 시 `Arguments::PropertyList_add`로 등록하는 값과 동일한 문자열(`mode_to_string()` 반환값: "32-bit" / "Zero based" / "Non-zero disjoint base" / "Non-zero based")을 반환하므로, 힙 크기를 바꿔가며 실행하는 자바 프로그램에서 이 프로퍼티를 출력해보면 4가지 모드가 실제로 바뀌는지 코드 레벨에서 확인할 수 있다.

## 잘못 알고 있던 것

- **"힙이 32GB 미만이면 무조건 compressed oops가 켜지고 다 똑같이 동작한다"** → 실제로는 4GB 미만/4~32GB 구간이 서로 다른 모드(`Unscaled`는 시프트조차 없음, `ZeroBased`는 시프트만 있음)이고, 그 32GB 상한 자체도 null-가드 페이지만큼 깎인 근사치다. `-Xmx32g` 근처의 경계에서 실제 켜지는 힙 크기는 정확히 32×1024^3바이트가 아니다.
- **"compressed oops와 compressed class pointer는 같은 규칙(32GB 한도)을 공유한다"** → 둘은 `CompressedOops`와 `CompressedKlassPointers`라는 서로 다른 클래스가 각자의 `base`/`shift`/한도를 관리하는 독립된 인코더다. 특히 `UseCompactObjectHeaders`가 켜지면 narrow klass 비트 수가 32→22로 줄고 최대 시프트가 3→10으로 늘어, 클래스 포인터의 표현 범위 상한이 32GB에서 4GB로 오히려 좁아진다.

## 더 파고들 만한 것

- Compact Object Headers(Lilliput 프로젝트, `UseCompactObjectHeaders`)가 오브젝트 헤더 자체(mark word + narrow klass)를 어떻게 8바이트로 줄이는지, 그리고 그게 narrow klass 비트 예산에 왜 영향을 주는지.
- ZGC의 colored pointer(포인터 상위 비트에 GC 메타데이터를 싣는 방식)와 compressed oops가 같은 JVM에서 함께 쓰일 수 있는지, 있다면 시프트/베이스 계산이 어떻게 상호작용하는지.

## 참고

- OpenJDK HotSpot 소스: `oops/compressedOops.{hpp,cpp,inline.hpp}`, `oops/compressedKlass.{hpp,cpp}`, `runtime/arguments.cpp`, `runtime/globals.hpp`, `utilities/globalDefinitions.{hpp,cpp}`

---

<!-- velog 글로 발전 후 -->
**velog 글:** {link}
