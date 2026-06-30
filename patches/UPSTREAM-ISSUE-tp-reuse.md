# Upstream issue draft — file in: open-telemetry/opentelemetry-ebpf-instrumentation (OBI)
# (NOT grafana/beyla — the trace-correlation code is in OBI; Beyla 3.x vendors it)
# Posting: create via the OBI GitHub web UI (gh not available). Anonymized — no internal names.

---

**Title:** Adopted `traceparent` is reused without bound → giant merged traces (no request-count/age limit on header adoption)

## Summary
When a server request carries an incoming W3C `traceparent`, OBI adopts it as the
span parent unconditionally. If the **same parent span id** is presented across many
independent requests — long-lived/pooled keep-alive connections, batch-job poll loops,
or an upstream that reuses one trace context — OBI keeps stitching them into a **single
trace with no upper bound**. The result is enormous merged traces that are not real
distributed traces.

## Observed
- A single trace with **~45,000 spans across 33 services spanning ~2.5 hours**.
- One (uncaptured) parent span id was adopted as the server parent by **~5,500 independent
  requests across 10 services**.
- Individual span durations are sub-second (median ~2 ms); the multi-hour trace "duration"
  is purely the merge envelope (`max(ts) − min(ts)` over unrelated requests), not real latency.
- Legit fan-out for comparison: a normal request fans out to ~1–30 downstream spans under
  one parent; the reuse anchors reach thousands.

## Persists with the existing mitigations
- `OTEL_EBPF_BPF_CONTEXT_PROPAGATION=headers`
- `OTEL_EBPF_BPF_DISABLE_BLACK_BOX_CP=true`

Neither helps, because those govern the TCP/black-box correlation path. The merge here
arrives via the adopted **header** `traceparent`, which is a different code path.

## Root cause (code)
The only reuse bound in the codebase is the 15-second epoch check in
`correlated_requests()` (`bpf/common/tracing.h`), and it gates **black-box** correlation
only. The header-adoption sites have **no count or age guard**:
- `bpf/generictracer/protocol_http.h` (server adopts decoded parent id)
- `bpf/generictracer/protocol_http2.h` (gRPC/HTTP2 server finalize)
- `bpf/gotracer/go_nethttp.c` (Go server adoption)

So a parent span id that is reused/sticky/looped is adopted indefinitely → unbounded merge.

## Environment
- OBI as vendored in a custom build on the 3.22 base (behavior present on 3.x `main` lineage).
- Kernel 6.6.x, x86_64. Mix of Go and Node.js services behind an internal HTTP ingress.
- Reproduces with a batch job that polls one endpoint in a loop under a single context
  (hundreds–thousands of calls share one parent span id).

## Proposal
Add an **opt-in, request-count-based** guard at the header-adoption sites:
- New volatile-const threshold (e.g. `OTEL_EBPF_BPF_TP_REUSE_THRESHOLD`, default `0` = off).
- Track, per incoming parent span id, how many server requests have adopted it (LRU map).
- When the count exceeds the threshold, mint a fresh trace id and clear the parent
  (treat the request as a new root) instead of adopting.

This is **request-count based, not time based**, so it cleanly separates legitimate
fan-out (tens) from reuse (thousands) and does not penalize genuinely long requests.
Cost is one LRU map lookup/update per adopted server request (no per-callback syscall).

Happy to contribute the patch (prototype already drafted).

## Related (narrower) issues
#2046 (stale Kafka traceparent), #2232 (clear stale parent ids), #2017/#2233
(readMimeHeader stale bytes), #1095 (gRPC propagation), #2284 (Java virtual-thread
enrichment). Each addresses a specific reuse path; this issue is the general
"adopted traceparent has no reuse bound" gap.
