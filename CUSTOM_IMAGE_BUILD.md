# Beyla Custom Image Build — Ring Buffer Fix

## Problem

Beyla v3 (v3.14.0 through v3.20.0) drops ~84% of eBPF events silently due to a bug
in the BPF ring buffer wakeup logic. This causes metrics and spans to show only
~200-300 RPS vs the actual ~1,300+ RPS on the node.

**Root cause**: `.obi-src/bpf/common/ringbuf.h` line 33-34

```c
if (!wakeup_data_bytes) {
    return 0;  // BUG: should be BPF_RB_FORCE_WAKEUP
}
```

When `wakeup_data_bytes == 0` (the default, or when `wakeup_len: 0`), the BPF code
returns `0` instead of `BPF_RB_FORCE_WAKEUP`. This means the kernel uses default
wakeup behavior, which doesn't drain the ring buffer fast enough. Events are silently
dropped at `bpf_ringbuf_reserve()` when the 1MB buffer is full.

**Upstream issue**: https://github.com/grafana/beyla/issues/2707 (OPEN, no fix PR)
**Identical fix already merged for stats buffer**: https://github.com/open-telemetry/opentelemetry-ebpf-instrumentation/pull/2198

## Evidence (from production sc-p-generic-services-03)

Measured over 5 minutes on node gke-sc-p-generic-services-03-cast-pool-769995f6:

| Stage | Rate/sec | Loss |
|-------|----------|------|
| BPF ServeHTTP probes | 1,328 RPS | - |
| Ring buffer to Go | 213 RPS | 84% lost |
| Trace exports | 267 RPS | ~0% additional loss |

Config workarounds tested and FAILED:
- `wakeup_len: 0` — returns `0` flag, 77% loss
- `wakeup_len: 1` — race condition, 85% loss
- `wakeup_len: 100` — `BPF_RB_NO_WAKEUP` until 70KB, 76% loss
- `global_scale_factor: 3` alone — buffer bigger but still not drained

## The Fix (2 changes in 1 file)

File: `.obi-src/bpf/common/ringbuf.h`

### Change 1: Line 21 — Increase ring buffer from 1MB to 8MB
```
BEFORE: __uint(max_entries, 1 << 20);
AFTER:  __uint(max_entries, 1 << 23);
```

### Change 2: Line 34 — Force immediate wakeup when no threshold configured
```
BEFORE: return 0;
AFTER:  return BPF_RB_FORCE_WAKEUP;
```

Both changes are already applied in the local `.obi-src/bpf/common/ringbuf.h`.

## Architecture: How OBI relates to Beyla

```
beyla (github.com/grafana/beyla)
├── go.mod: replace go.opentelemetry.io/obi => ./.obi-src
├── .obi-src/  ← git submodule of grafana/opentelemetry-ebpf-instrumentation
│   ├── bpf/common/ringbuf.h   ← THE FILE WE PATCHED
│   ├── pkg/                    ← Go packages (ebpf, config, export, etc.)
│   └── Makefile                ← BPF code generation
├── vendor/go.opentelemetry.io/obi/  ← vendored copy of .obi-src Go code
├── Makefile                    ← Beyla build (calls OBI generate)
└── Dockerfile                  ← Multi-stage build
```

**OBI (.obi-src)** is a git submodule that contains:
- BPF C code (compiled to .o files via bpf2go during `make generate`)
- Go packages for eBPF loading, ring buffer reading, config, exporters

**Beyla** wraps OBI with:
- Kubernetes discovery, Beyla-specific config, Grafana Cloud integration
- `go.mod` uses `replace` directive to point at local `.obi-src` submodule
- `vendor/` contains vendored Go code from `.obi-src`

The BPF C code in `.obi-src/bpf/` is compiled into Go-embedded `.o` files during
`make generate`. These compiled objects end up in
`vendor/go.opentelemetry.io/obi/pkg/internal/ebpf/*/` as `*_bpfel.o` files.

## Custom Metrics: Ring Buffer Drop Counter

Added a `ringbuf_drops` per-CPU array map in BPF that counts every
`bpf_ringbuf_reserve()` failure. This is incremented via `record_ringbuf_drop()`
at all `events` ring buffer reserve failure sites (16 total).

### Files modified for drop counter:

| File | Change |
|------|--------|
| `.obi-src/bpf/common/ringbuf.h` | Added `ringbuf_drops` PERCPU_ARRAY map + `record_ringbuf_drop()` helper |
| `.obi-src/bpf/gotracer/go_nethttp.c` | Added `record_ringbuf_drop()` at 2 reserve failure points |
| `.obi-src/bpf/gotracer/go_grpc.c` | Added `record_ringbuf_drop()` at 2 reserve failure points |
| `.obi-src/bpf/gotracer/go_sarama.c` | Added `record_ringbuf_drop()` at 1 reserve failure point (Kafka Sarama) |
| `.obi-src/bpf/gotracer/go_redis.c` | Added `record_ringbuf_drop()` at 1 reserve failure point (Redis) |
| `.obi-src/bpf/gotracer/go_mongo.c` | Added `record_ringbuf_drop()` at 1 reserve failure point (MongoDB) |
| `.obi-src/bpf/gotracer/go_kafka_go.c` | Added `record_ringbuf_drop()` at 2 reserve failure points (kafka-go) |
| `.obi-src/bpf/gotracer/go_sql.c` | Added `record_ringbuf_drop()` at 1 reserve failure point (SQL) |
| `.obi-src/bpf/generictracer/protocol_http.h` | Added `record_ringbuf_drop()` at 1 reserve failure point |
| `.obi-src/bpf/generictracer/protocol_http2.h` | Added `record_ringbuf_drop()` at 1 reserve failure point (HTTP/2 + gRPC) |
| `.obi-src/bpf/generictracer/protocol_tcp.h` | Added `record_ringbuf_drop()` at 2 reserve failure points |
| `.obi-src/bpf/generictracer/dns.h` | Added `record_ringbuf_drop()` at 2 reserve failure points (DNS) |

### How to read the drop counter

The `ringbuf_drops` map will appear in the BPF map list. To read it from userspace
(Go side), you need to add a scraper in the BPF metrics collector. The map is a
PERCPU_ARRAY with key=0, value=u64 per CPU. Sum across all CPUs for total drops.

To expose via Prometheus internal metrics, the Go-side `prom_bpf.go` needs to be
modified to also scrape PERCPU_ARRAY maps (currently only scrapes LRUHash at line 357).

Alternatively, read it manually from a running pod:
```bash
# The map will be visible via bpftool on the node:
bpftool map dump name ringbuf_drops
```

### How to verify the fix is working

After deploying the custom image, the `ringbuf_drops` map should show 0 or very low
counts. If it still shows high counts, the ring buffer is still overflowing and needs
to be made larger.

## Build Steps

### Prerequisites
- Docker with buildx
- The `.obi-src/bpf/common/ringbuf.h` patch (already applied)
- The drop counter patches in go_nethttp.c, go_grpc.c, protocol_http.h, protocol_tcp.h (already applied)

### Option A: Full build (recommended, uses Docker multi-stage)

```bash
cd /Users/nishantgarg/Desktop/Sharechat/services/beyla

# Step 1: Generate BPF objects and vendor them
make generate
make copy-obi-vendor

# Step 2: Build Docker image (DEV_OBI=1 skips regeneration inside Docker)
docker build \
  --build-arg DEV_OBI=1 \
  --build-arg GEN_IMG="ghcr.io/open-telemetry/obi-generator:0.2.13" \
  --platform linux/amd64 \
  -t <YOUR_REGISTRY>/beyla:3.20.0-ringbuf-fix \
  .

# Step 3: Push
docker push <YOUR_REGISTRY>/beyla:3.20.0-ringbuf-fix
```

### Option B: Use `make dev-image-build` (handles vendoring)

```bash
cd /Users/nishantgarg/Desktop/Sharechat/services/beyla

make generate
make copy-obi-vendor

IMG_ORG=<your-org> VERSION=3.20.0-ringbuf-fix make dev-image-build
```

### Key Makefile targets

| Target | What it does |
|--------|-------------|
| `make generate` | Compiles BPF C code in `.obi-src/bpf/` to Go-embedded `.o` files |
| `make copy-obi-vendor` | Vendors the OBI Go code (including compiled BPF) into `vendor/` |
| `make dev-image-build` | Builds Docker image with `DEV_OBI=1` (uses local vendor, no regen) |
| `make compile` | Compiles Go binary only (no Docker) |

## Deploy

Update the Beyla DaemonSet image on sc-p-generic-services-03:
```
image: <YOUR_REGISTRY>/beyla:3.20.0-ringbuf-fix
```

No ConfigMap changes needed. The fix is in the BPF code — `wakeup_len` and
`global_scale_factor` are no longer required (but won't hurt if present).

## Verification

After deploying, check internal metrics:
```bash
curl -s http://<POD_IP>:6060/internal/metrics | grep -E '(uprobe_ServeHTTP"|tracer_flushes_sum|otel_trace_exports_total)' | grep -v latency
```

Expected: `tracer_flushes_sum` should be close to `uprobe_ServeHTTP` count (< 5% loss).

## Upstream PR Plan

File a 1-line PR to https://github.com/open-telemetry/opentelemetry-ebpf-instrumentation:
- File: `bpf/common/ringbuf.h`, line 34
- Change: `return 0;` to `return BPF_RB_FORCE_WAKEUP;`
- Reference: PR #2198 (identical fix for stats ring buffer, already merged)
- Reference: Issue grafana/beyla#2707

Once merged upstream and released, switch back to stock Beyla image.
