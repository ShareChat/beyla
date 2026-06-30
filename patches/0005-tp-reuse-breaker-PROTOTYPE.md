# PROTOTYPE: trace-context reuse-breaker (request-count based)

Goal: stop mega-traces like prod `4f969c35f2137f7b92eb0744e59218ec`
(45,297 spans / 33 svc / 2.48h; anchor `ababb53a09be00e4` adopted by **5,549**
server requests across 10 services). Cause: an incoming `traceparent` whose
parent span id is reused as the server parent for thousands of unrelated
requests. Fix: when a single incoming `(parent span id)` has anchored more than
N server requests, stop adopting it and mint a fresh root — **request-count
based, not time based**.

Threshold separates legit fan-out from reuse cleanly:
- legit fan-out: one client span → ~1–30 downstream server spans
- reuse anchor (4f969c35): one span → 5,549 server spans
- default `TP_REUSE_THRESHOLD = 0` (disabled); recommended **128**.

Applied as a new patch `patches/0005-tp-reuse-breaker.patch` to `.obi-src`,
after `make generate`, alongside 0004 (see Dockerfile). eBPF C changes require
`cd .obi-src && make generate` to regenerate bpf2go bindings.

---

## 1. New map — `bpf/maps/tp_reuse_count.h`
LRU hash; key = parent span id (8 bytes as u64); value = adoption count.
LRU bounds memory and auto-evicts cold anchors.

```c
#pragma once
#include <bpfcore/vmlinux.h>
#include <bpfcore/bpf_helpers.h>

struct {
    __uint(type, BPF_MAP_TYPE_LRU_HASH);
    __type(key, u64);     // incoming parent span_id, first 8 bytes
    __type(value, u32);   // # of server requests that adopted this parent
    __uint(max_entries, 65536);
} tp_reuse_count SEC(".maps");
```

## 2. Volatile const + helper — add to `bpf/common/tracing.h`
```c
// Set from Go (generictracer.go / gotracer.go). 0 = disabled.
volatile const u32 tp_reuse_threshold;

#include <maps/tp_reuse_count.h>

// Returns 1 if this incoming parent span has already anchored more than
// tp_reuse_threshold server requests -> caller should mint a fresh root.
static __always_inline u8 tp_reuse_should_break(const unsigned char *parent_id) {
    if (tp_reuse_threshold == 0) {
        return 0; // feature disabled
    }
    // parent_id is all-zero for genuine roots — nothing to break.
    if (!valid_span(parent_id)) {
        return 0;
    }
    u64 key = 0;
    __builtin_memcpy(&key, parent_id, sizeof(key)); // span_id is 8 bytes
    u32 *cnt = bpf_map_lookup_elem(&tp_reuse_count, &key);
    u32 newcnt = cnt ? (*cnt + 1) : 1;
    bpf_map_update_elem(&tp_reuse_count, &key, &newcnt, BPF_ANY);
    return newcnt > tp_reuse_threshold;
}
```
(`valid_span` = non-zero span id helper; if absent, inline a zero-check over the 8 bytes.)

## 3. Apply at the server-adoption sites

### 3a. Generic HTTP — `bpf/generictracer/protocol_http.h` (~line 519)
Right after the server adopts the incoming parent:
```c
        if (meta && meta->type != EVENT_HTTP_CLIENT) {
            decode_hex(tp_p->tp.parent_id, s_id, SPAN_ID_CHAR_LEN);
            // ── REUSE-BREAKER ──
            if (tp_reuse_should_break(tp_p->tp.parent_id)) {
                new_trace_id(&tp_p->tp);
                __builtin_memset(tp_p->tp.parent_id, 0, sizeof(tp_p->tp.parent_id));
            }
        } else if (previous_trace_id && ...) { ... }
```

### 3b. HTTP/2 + gRPC — `bpf/generictracer/protocol_http2.h` server finalize (~line 449)
After `parse_hpack_traceparent` adopted the incoming TP and before commit:
```c
    if (found_tp && tp_reuse_should_break(tp_p->tp.parent_id)) {
        new_trace_id(&tp_p->tp);
        bpf_memset(tp_p->tp.parent_id, 0, sizeof(tp_p->tp.parent_id));
        found_tp = 0;
    }
    if (!found_tp) { new_trace_id(&tp_p->tp); ... }   // existing
```

### 3c. Go HTTP servers — `bpf/gotracer/go_nethttp.c`  ← REQUIRED (4f969c35's services are Go)
The dominant mega-trace services (e13n-lookup, network-relevance, notification,
post-action) are Go, instrumented via the Go uprobe path. Apply the same guard
where the Go server span adopts the incoming `traceparent` parent id
(after readMimeHeader extraction). Same two lines: `if (tp_reuse_should_break(parent_id)) { new_trace_id(); clear parent; }`.
> Without 3c the breaker won't touch Go-originated merges — this is the most
> important site for `4f969c35`.

## 4. Go wiring

### `pkg/config/ebpf_tracer.go`
```go
// 0 disables. When an incoming traceparent's parent span has anchored more than
// this many server requests, mint a fresh root instead (breaks reuse mega-traces).
TPReuseThreshold uint32 `yaml:"tp_reuse_threshold" env:"OTEL_EBPF_BPF_TP_REUSE_THRESHOLD"`
```

### `pkg/internal/ebpf/generictracer/generictracer.go` (with the other m[...] sets, ~line 213)
```go
m["tp_reuse_threshold"] = p.cfg.EBPF.TPReuseThreshold
```
### `pkg/internal/ebpf/gotracer/gotracer.go` (same — for the Go path)
```go
m["tp_reuse_threshold"] = p.cfg.TPReuseThreshold
```

## 5. Build (ShareChat fork)
1. `make generate` (recreates `.obi-src`)
2. apply `patches/0004-...` then `patches/0005-tp-reuse-breaker.patch`
3. `cd .obi-src && make generate` (regenerate bpf2go from patched C — picks up the new map + const)
4. `make copy-obi-vendor`; assert `tp_reuse_count` + `tp_reuse_threshold` are in vendored bindings.
5. `make compile`; tag e.g. `custom-beyla-v3.22.2-reusebreaker`.

## 6. Validation plan

**Config:** `OTEL_EBPF_BPF_TP_REUSE_THRESHOLD=128` (keep CONTEXT_PROPAGATION=headers, DISABLE_BLACK_BOX_CP=true).

**Staging first (reproducible target):** the `job-notification-gatekeeper`
reuse reproduces in staging (`e024b685…` = 1247 getStickyNotificationTags under
1 parent). After deploy, that anchor should cap at ≤128 children, so one
1,566-span trace becomes ~12 traces of ≤128. Confirm:
- no anchor with > ~128 children (ClickHouse: `count() GROUP BY ParentSpanId`)
- stitching within a real request still intact (≤128-fanout requests unchanged)

**Prod canary (one cluster):** confirm `4f969c35`-class traces no longer exceed
~128 spans per anchor; max spans/trace drops from tens-of-thousands to low
hundreds; legit fan-out traces (splashScreenConfig ~20 svc) unaffected.

**Risk / tunables:**
- Threshold too low → splits genuine high-fan-out requests. 128 is well above
  observed legit fan-out (~30) and far below reuse (thousands). Tune up if any
  legit trace is split.
- LRU map (65,536) bounds memory; cold anchors evict. Negligible CPU (one map
  lookup+update per adopted server request).
- Pure eBPF map op — **no per-async-callback syscall**, so none of the Node
  `fs.accessSync` overhead that killed `BEYLA_NODEJS_ENABLED`.
```
