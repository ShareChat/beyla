# obi-generator must match the .obi-src base: v3.24.0 requires 0.2.15 (3.20/3.22 used 0.2.13/0.2.14).
ARG GEN_IMG=ghcr.io/open-telemetry/obi-generator:0.2.15

# Build JNI native library using Go image (has gcc + apt; installs cross-compiler)
FROM golang:1.26.3@sha256:313faae491b410a35402c05d35e7518ae99103d957308e940e1ae2cfa0aac29b AS jni-builder
ARG BUILDARCH=amd64
COPY --from=gradle:9.5.0-jdk21-noble@sha256:41cd88d5934d5880ea7e3ebd53d711155e7e1c989390f0f9fa3dfd7d6b742a28 /opt/java/openjdk/include /opt/java/include
WORKDIR /build
COPY .obi-src/pkg/internal/java/agent/src/main/c/ src/main/c/
COPY .obi-src/pkg/internal/java/agent/Makefile.jni Makefile.jni

# Install the cross-compiler for the non-native architecture
RUN apt-get update && \
    case "$BUILDARCH" in \
      amd64) apt-get install -y gcc-aarch64-linux-gnu ;; \
      arm64) apt-get install -y gcc-x86-64-linux-gnu ;; \
    esac

# Build for own architecture
RUN case "$BUILDARCH" in \
      amd64) SLUG=linux-amd64 ;; \
      arm64) SLUG=linux-aarch64 ;; \
    esac && \
    make -f Makefile.jni CC=gcc JAVA_HOME=/opt/java JNI_HEADERS_DIR=src/main/c BUILD_DIR=build/jni/$SLUG TARGET_DIR=target/classes/native/$SLUG

# Cross-compile for the other architecture
RUN case "$BUILDARCH" in \
      amd64) CC=aarch64-linux-gnu-gcc; SLUG=linux-aarch64 ;; \
      arm64) CC=x86_64-linux-gnu-gcc;  SLUG=linux-amd64 ;; \
    esac && \
    make -f Makefile.jni CC=$CC JAVA_HOME=/opt/java JNI_HEADERS_DIR=src/main/c BUILD_DIR=build/jni/$SLUG TARGET_DIR=target/classes/native/$SLUG

# Build the Java OBI agent
FROM gradle:9.5.0-jdk21-noble@sha256:41cd88d5934d5880ea7e3ebd53d711155e7e1c989390f0f9fa3dfd7d6b742a28 AS javaagent-builder

WORKDIR /build

# Copy build files
COPY .obi-src/pkg/internal/java .
# Apply Beyla-specific Java patches on top of OBI source
COPY internal/java/ .

# Pre-built native library from jni-builder stage
COPY --from=jni-builder /build/target/classes/native/linux-amd64/libobijni.so  agent/target/classes/native/linux-amd64/libobijni.so
COPY --from=jni-builder /build/target/classes/native/linux-aarch64/libobijni.so agent/target/classes/native/linux-aarch64/libobijni.so

# Build the project (skip native lib compilation, already done above)
RUN gradle build -x buildNativeLib-amd64 -x buildNativeLib-aarch64 --no-daemon

# Build the autoinstrumenter binary
FROM $GEN_IMG AS builder

# TODO: embed software version in executable

ARG TARGETARCH

# set it to a non-empty value if you are building this image
# from a custom, local OBI repository
# In that case, you must run `make generate copy-obi-vendor`
# manually, before building this image.
# Or directly run`make dev-image-build`
ARG DEV_OBI

ENV GOARCH=$TARGETARCH

WORKDIR /src

RUN apk add make git bash

# Copy the go manifests and source
COPY .git/ .git/
COPY cmd/ cmd/
COPY pkg/ pkg/
COPY vendor/ vendor/
COPY go.mod go.mod
COPY go.sum go.sum
COPY Makefile Makefile
COPY LICENSE LICENSE
COPY NOTICE NOTICE
COPY third_party_licenses.csv third_party_licenses.csv
# ShareChat: large-header traceparent-scan backport patch, applied to .obi-src inside
# the build. The builder does not COPY .obi-src; `make generate` re-creates it from the
# copied .git/ submodule, so the patch must be applied AFTER that and BEFORE bindings are
# (re)generated from the patched eBPF C.
COPY patches/ patches/

# Point make to the pre-installed bpf2go binary in the generator image
ENV BPF2GO=/go/bin/bpf2go

# Build — ShareChat large-header traceparent-scan backport (adds the configurable
# OTEL_EBPF_BPF_MAX_REQUEST_TP_PARSE_SIZE_KB chunked scanner) on top of the 3.24 base
# (which also carries the readMimeHeader stale-bytes mega-trace fix).
# The patch changes eBPF C (new split tail-call programs + a new volatile-const global),
# so the bpf2go bindings MUST be regenerated from the patched C. Sequence:
#   1. `make generate` — re-creates .obi-src from .git (obi-submodule) and runs the
#      initial generation, so .obi-src + toolchain are present.
#   2. apply the backport patch to the now-present .obi-src.
#   3. `cd .obi-src && make generate` — regenerate bindings from the PATCHED C
#      directly (OBI's own target; does NOT re-init/reset the submodule, so the
#      patch is preserved). This is the step the prior build lacked.
#   4. `make copy-obi-vendor` — `go mod vendor` copies the patched + regenerated
#      tree into vendor/ (go.mod: `replace go.opentelemetry.io/obi => ./.obi-src`).
# Assertions fail the build if the loader wiring or the regenerated program is absent.
RUN if [ -z "${DEV_OBI}" ]; then \
    export PATH="/usr/lib/llvm22/bin:$PATH" && \
    export BPF_CLANG=clang-22 && \
    export BPF_CFLAGS="-O2 -g -Wall -Werror" && \
    make generate && \
    ( cd .obi-src && git apply --3way --whitespace=nowarn --verbose ../patches/0001-large-header-chunked-scan-pr1988.patch ) && \
    ( cd .obi-src && git apply --3way --whitespace=nowarn --verbose ../patches/0002-go-strict-parent-liveness.patch ) && \
    ( cd .obi-src && git apply --3way --whitespace=nowarn --verbose ../patches/0003-disable-h2-tp-adopt.patch ) && \
    ( cd .obi-src && git apply --3way --whitespace=nowarn --verbose ../patches/0004-client-reuse-breaker.patch ) && \
    ( cd .obi-src && git apply --3way --whitespace=nowarn --verbose ../patches/0005-generic-client-reuse-breaker.patch ) && \
    ( cd .obi-src && git apply --3way --whitespace=nowarn --verbose ../patches/0006-injector-reuse-breaker.patch ) && \
    ( cd .obi-src && git apply --3way --whitespace=nowarn --verbose ../patches/0007-tp-reuse-breaker-port.patch ) && \
    ( cd .obi-src && git apply --3way --whitespace=nowarn --verbose ../patches/0008-trace-reuse-breaker-port.patch ) && \
    echo "### Asserting beya-1-patch content applied to eBPF C before generate" && \
    grep -q "k_tail_parse_traceparent_http_append" .obi-src/bpf/generictracer/k_tracer_tailcall.h || (echo "FATAL: 0001 chunked scanner enum missing" && exit 1) && \
    grep -q "bpf_max_request_tp_parse_size_kb" .obi-src/bpf/generictracer/protocol_http.h || (echo "FATAL: 0001 scan window missing from protocol_http.h" && exit 1) && \
    grep -q "go_strict_parent" .obi-src/bpf/common/tracing.h || (echo "FATAL: 0002 strict-parent flag missing from tracing.h" && exit 1) && \
    grep -q "0002: skipping non-live goroutine ctx" .obi-src/bpf/gotracer/go_common.h || (echo "FATAL: 0002 liveness gate missing from go_common.h" && exit 1) && \
    grep -q "case g_dead:" .obi-src/bpf/gotracer/go_runtime.c || (echo "FATAL: 0002 g_dead cleanup missing from go_runtime.c" && exit 1) && \
    grep -q "GoStrictParent" .obi-src/pkg/config/ebpf_tracer.go || (echo "FATAL: 0002 config field missing" && exit 1) && \
    grep -q "disable_h2_tp_adopt" .obi-src/bpf/tpinjector/tpinjector.c || (echo "FATAL: 0003 h2 no-adopt guard missing from tpinjector.c" && exit 1) && \
    grep -q "DisableH2TpAdopt" .obi-src/pkg/config/ebpf_tracer.go || (echo "FATAL: 0003 config field missing" && exit 1) && \
    grep -q "disable_h2_tp_adopt" .obi-src/pkg/internal/ebpf/tpinjector/tpinjector.go || (echo "FATAL: 0003 loader wiring missing" && exit 1) && \
    grep -q "client_reuse_threshold" .obi-src/bpf/common/tracing.h || (echo "FATAL: 0004 breaker helper missing from tracing.h" && exit 1) && \
    grep -q "0004: parent ctx past client reuse threshold" .obi-src/bpf/gotracer/go_common.h || (echo "FATAL: 0004 breaker gate missing from go_common.h" && exit 1) && \
    grep -q "ClientReuseThreshold" .obi-src/pkg/config/ebpf_tracer.go || (echo "FATAL: 0004 config field missing" && exit 1) && \
    grep -q "client_reuse_threshold" .obi-src/pkg/internal/ebpf/gotracer/gotracer.go || (echo "FATAL: 0004 loader wiring missing" && exit 1) && \
    grep -q "client_reuse_should_break_key" .obi-src/bpf/common/tracing.h || (echo "FATAL: 0005 key-based breaker helper missing from tracing.h" && exit 1) && \
    grep -q "0005: parent ctx past client reuse threshold" .obi-src/bpf/generictracer/protocol_http2.h || (echo "FATAL: 0005 breaker gate missing from protocol_http2.h" && exit 1) && \
    grep -q "client_reuse_threshold" .obi-src/pkg/internal/ebpf/generictracer/generictracer.go || (echo "FATAL: 0005 generic loader wiring missing" && exit 1) && \
    grep -q "0006: injector parent ctx past reuse threshold" .obi-src/bpf/tpinjector/tpinjector.c || (echo "FATAL: 0006 injector gate missing from tpinjector.c" && exit 1) && \
    grep -q "client_reuse_threshold" .obi-src/pkg/internal/ebpf/tpinjector/tpinjector.go || (echo "FATAL: 0006 injector wiring missing" && exit 1) && \
    grep -q "tp_reuse_should_break" .obi-src/bpf/common/tracing.h || (echo "FATAL: 0007 server breaker helper missing" && exit 1) && \
    test -f .obi-src/bpf/maps/tp_reuse_count.h || (echo "FATAL: 0007 map header missing" && exit 1) && \
    grep -q "TPReuseThreshold" .obi-src/pkg/config/ebpf_tracer.go || (echo "FATAL: 0007 config field missing" && exit 1) && \
    grep -c "tp_reuse_should_break" .obi-src/bpf/generictracer/protocol_http.h | grep -q "^2$" || (echo "FATAL: 0007 protocol_http.h guards != 2" && exit 1) && \
    grep -q "trace_reuse_should_break" .obi-src/bpf/common/tracing.h || (echo "FATAL: 0008 trace breaker helper missing" && exit 1) && \
    test -f .obi-src/bpf/maps/trace_reuse_count.h || (echo "FATAL: 0008 map header missing" && exit 1) && \
    grep -q "TraceReuseThreshold" .obi-src/pkg/config/ebpf_tracer.go || (echo "FATAL: 0008 config field missing" && exit 1) && \
    grep -q "trace_reuse_should_break(t.tp.trace_id)" .obi-src/bpf/gotracer/go_grpc.c || (echo "FATAL: 0008 grpc guard missing" && exit 1) && \
    ( cd .obi-src && make generate ) && \
    make copy-obi-vendor && \
    echo "### Asserting beya-1-patch wiring landed in vendored OBI" && \
    grep -rq "ObiParseTraceparentHttpAppend" vendor/go.opentelemetry.io/obi/pkg/internal/ebpf/generictracer/ || (echo "FATAL: 0001 regenerated bindings missing from generictracer" && exit 1) && \
    grep -q "GoStrictParent" vendor/go.opentelemetry.io/obi/pkg/config/ebpf_tracer.go || (echo "FATAL: 0002 config field missing from vendored OBI" && exit 1) && \
    grep -q "go_strict_parent" vendor/go.opentelemetry.io/obi/pkg/internal/ebpf/gotracer/gotracer.go || (echo "FATAL: 0002 loader wiring missing from vendored OBI" && exit 1) && \
    grep -q "ClientReuseThreshold" vendor/go.opentelemetry.io/obi/pkg/config/ebpf_tracer.go || (echo "FATAL: 0004 config field missing from vendored OBI" && exit 1) && \
    grep -q "client_reuse_threshold" vendor/go.opentelemetry.io/obi/pkg/internal/ebpf/gotracer/gotracer.go || (echo "FATAL: 0004 loader wiring missing from vendored OBI" && exit 1) && \
    grep -q "client_reuse_threshold" vendor/go.opentelemetry.io/obi/pkg/internal/ebpf/generictracer/generictracer.go || (echo "FATAL: 0005 generic loader wiring missing from vendored OBI" && exit 1) && \
    grep -q "client_reuse_threshold" vendor/go.opentelemetry.io/obi/pkg/internal/ebpf/tpinjector/tpinjector.go || (echo "FATAL: 0006 injector wiring missing from vendored OBI" && exit 1) && \
    grep -q "TPReuseThreshold" vendor/go.opentelemetry.io/obi/pkg/config/ebpf_tracer.go || (echo "FATAL: 0007 config missing from vendored OBI" && exit 1) && \
    grep -q "TraceReuseThreshold" vendor/go.opentelemetry.io/obi/pkg/config/ebpf_tracer.go || (echo "FATAL: 0008 config missing from vendored OBI" && exit 1) \
    ; fi

# The Java agent is embedded at Go compile time, so the platform-specific jar
# must be copied into vendor before building the Beyla binary.
COPY --from=javaagent-builder /build/build/obi-java-agent.jar /src/vendor/go.opentelemetry.io/obi/pkg/internal/java/embedded/obi-java-agent.jar
RUN make compile

# Create final image from minimal + built binary
FROM scratch

LABEL maintainer="Grafana Labs <hello@grafana.com>"

WORKDIR /

COPY --from=builder /src/bin/beyla .
COPY --from=builder /src/LICENSE .
COPY --from=builder /src/NOTICE .
COPY --from=builder /src/third_party_licenses.csv .

COPY --from=builder /etc/ssl/certs /etc/ssl/certs

ENTRYPOINT [ "/beyla" ]
