# 0006 — HTTP/2 stream-scoped trace context (PROTOTYPE)

## Problem (confirmed in code + real trace 0831f3c2)
`trace_map` — beyla's per-connection trace-context store — is keyed by
`trace_map_key_t { connection_info_t conn; u32 type; }`. `trace_key_from_conn()`
even **zeroes `d_port`/`d_addr`**, so the effective key is `{src_ip, src_port, type}`.

On a **persistent HTTP/2 (gRPC) connection**, every multiplexed stream shares the
same `{src_ip, src_port}` → the same key → the same stored trace context. So all
streams over one channel inherit one `trace_id`:
- Real example: trace `0831f3c2` = 316 `ExecuteStreamingSql` streams to Cloud Spanner
  (199.36.153.10, one gRPC channel) merged into one trace over 6.75 min; one trace_id,
  316 unique (uncaptured) parent span-ids.

`egress_key_t` already carries `stream_id` (used by the injection/HPACK path), but the
identity store (`trace_map`) ignores it — that mismatch is the bug.

## Fix idea
Add `stream_id` to `trace_map_key_t` and thread it through the store **and** read paths.
HTTP/1.1 and non-H2 always use `stream_id = 0` → byte-identical behavior. HTTP/2 uses the
real stream id → each stream keys its own context → no cross-stream merge.

## Exact source changes

### 1. `bpf/common/trace_map_key.h`
```c
typedef struct trace_map_key {
    connection_info_t conn;
    u32 type;
    u32 stream_id;   // NEW: 0 for HTTP/1.1 & non-H2; H2 stream id otherwise
} trace_map_key_t;
```

### 2. `bpf/common/tracing.h` — thread stream_id through the chokepoint + accessors
```c
static __always_inline void
trace_key_from_conn(trace_map_key_t *key, const connection_info_t *conn, u32 type) {
    // unchanged; leaves key->stream_id = 0 (zero-init by callers)
}

// NEW stream-aware accessors (existing ones remain, stream_id defaults 0)
static __always_inline tp_info_pid_t *
trace_info_for_connection_stream(const connection_info_t *conn, u32 type, u32 stream_id) {
    trace_map_key_t key = {};
    trace_key_from_conn(&key, conn, type);
    key.stream_id = stream_id;
    return (tp_info_pid_t *)bpf_map_lookup_elem(&trace_map, &key);
}
static __always_inline void
set_trace_info_for_connection_stream(const connection_info_t *conn, u32 type,
                                     u32 stream_id, const tp_info_pid_t *info) {
    trace_map_key_t key = {};
    trace_key_from_conn(&key, conn, type);
    key.stream_id = stream_id;
    bpf_map_update_elem(&trace_map, &key, info, BPF_ANY);
}
static __always_inline void
delete_trace_info_for_connection_stream(connection_info_t *conn, u32 type, u32 stream_id) {
    trace_map_key_t key = {};
    trace_key_from_conn(&key, conn, type);
    key.stream_id = stream_id;
    bpf_map_delete_elem(&trace_map, &key);
}
```

### 3. `bpf/generictracer/protocol_http2.h` — use stream-scoped store + read
- Server finalize (line ~152):
  `set_trace_info_for_connection(&h2g_info->conn_info, TRACE_TYPE_SERVER, tp_p);`
  → `set_trace_info_for_connection_stream(&h2g_info->conn_info, TRACE_TYPE_SERVER, s_key->stream_id, tp_p);`
- Client finalize (line ~267):
  `set_trace_info_for_connection(&h2g_info->conn_info, TRACE_TYPE_CLIENT, tp_p);`
  → `set_trace_info_for_connection_stream(&h2g_info->conn_info, TRACE_TYPE_CLIENT, s_key->stream_id, tp_p);`

### 4. Read-path threading (REQUIRED for the fix to bite — the open question)
The store above is stream-scoped, but the **reads** happen in shared helpers that don't
know the stream id:
- `find_trace_for_server_request(conn, tp, type)`  (trace_lifecycle.h) — reads
  `trace_info_for_connection(conn, TRACE_TYPE_CLIENT)`
- `find_trace_for_client_request(pid_conn, ...)` → `find_parent_trace(...)` (trace_parent.h)

These are called from HTTP/1.1 (stream_id=0), HTTP/2, and the Go tracer. To thread cleanly:
add a `u32 stream_id` param (default 0) to `find_trace_for_server_request` and to the
`trace_info_for_connection` read inside it; pass `s_key->stream_id` from the H2 call site
(protocol_http2.h:442) and `0` everywhere else (protocol_http.h, gotracer, tcp).

⚠️ **Open question the repro must answer:** for the CLIENT case (trace 0831f3c2), the
shared trace_id may arrive via `find_parent_trace()` (thread/task-bound `server_traces`,
keyed by `trace_key_t`, NOT conn) or via `adopt_injected_trace()` (the Go-uprobe HPACK
injection, `outgoing_trace_map`, already stream-keyed). If so, re-keying `trace_map` alone
won't fix the client side. **Confirm the exact path with beyla debug logs on the repro
before finalizing which read to thread.**

## Build note
`trace_map_key_t` is an eBPF map key struct → changing it requires regenerating the
`bpf2go` CO-RE skeletons (`pkg/internal/ebpf/**/bpf_*_bpfel.go`) in the custom Docker build
(the Dockerfile must run `go generate ./pkg/...` / the bpf2go step after applying this patch).
No Go struct on the userspace side reads `stream_id`, so only the generated bindings change.

## Status
Spec only. Do NOT build until the repro (below) confirms whether the reuse is the
`trace_map` (connection-keyed) path this patch fixes, or the injection/thread path.
