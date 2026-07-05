// Custom Beyla image build (ShareChat) — on top of the Beyla 3.24 base
// (.obi-src pinned to v3.24.0 / 54f2f639, which carries BOTH mega-trace fixes the
// 3.22 line lacked: the connection/Kafka stale-parent fix AND the readMimeHeader
// stale-bytes fix), applies two ShareChat patches in sequence:
//   0004 — configurable large-header traceparent scan window
//          (OTEL_EBPF_BPF_MAX_REQUEST_TP_PARSE_SIZE_KB)
//   0007 — disable_client_thread_bind (OTEL_EBPF_BPF_DISABLE_CLIENT_THREAD_BIND):
//          skips the thread/process-bound client-parenting fallback so
//          single-threaded runtimes (Node.js, instrumentation off) stop merging
//          multiplexed client streams into one unbounded mega-trace.
//   0008 — nodejs signal-dedup (fdextractor.js): dedups the per-async-hop
//          obi-ctx accessSync syscall (only re-signals when the active request
//          fd changes; resets after each outgoing write). Goal: keep
//          BEYLA_NODEJS_ENABLED=true (per-request context → no mega-spans) while
//          cutting the runtime instrumentation's CPU/latency overhead.
//   0010 — tpinjector H2 no-self-adopt (OTEL_EBPF_BPF_DISABLE_H2_TP_ADOPT):
//          stop find_existing_h2_tp adopting a traceparent replayed via grpc-go's
//          HPACK dynamic table (Beyla's own injected value), which merged every
//          multiplexed gRPC stream into one trace_id (network-relevance/ads-dnb).
//   0009 — tpinjector keep-alive clear (tpinjector.c): clear outgoing_trace_map
//          after injecting the HTTP header, so an HTTP/1.1 keep-alive connection
//          (stable egress key {s_port,d_port,stream_id=0}) does not re-inject one
//          request's context as the parent of every later request on the pooled
//          connection — the CONNECT-span-becomes-sticky-parent mega-trace.
//   0011 — gotracer stale goroutine-parent guard (go_common.h /
//          OTEL_EBPF_BPF_DISABLE_GO_STALE_PARENT): client_trace_parent only
//          inherits an ancestor goroutine's trace when that trace started within
//          max_transaction_time. A long-lived ancestor goroutine (connection
//          handler, worker pool, background loop) keeps a stale go_trace_map
//          entry that otherwise merges unrelated Go requests into one unbounded
//          trace (e13n/user-entity/social-graph residual after 0009/black-box).
//
// The code change lives as a patch in patches/ (the .obi-src submodule points at
// grafana upstream and is not pushable), applied to .obi-src at build time BEFORE
// `make generate` so the bpf2go bindings regenerate from the patched eBPF C. The
// repo Dockerfile is self-contained (multi-stage: obi-generator -> go build).
pipeline {
  agent {
    kubernetes {
      label 'beyla-custom'
      yaml """
apiVersion: v1
kind: Pod
spec:
  containers:
  - name: dind
    image: sc-mum-armory.platform.internal/devops/dind:v2
    securityContext:
      privileged: true
    env:
    - name: DOCKER_HOST
      value: tcp://localhost:2375
    - name: DOCKER_TLS_CERTDIR
      value: ""
    volumeMounts:
      - name: dind-storage
        mountPath: /var/lib/docker
    readinessProbe:
      tcpSocket:
        port: 2375
      initialDelaySeconds: 30
      periodSeconds: 10
  - name: builder
    image: sc-mum-armory.platform.internal/devops/builder-image-armory
    command:
    - sleep
    - infinity
    env:
    - name: DOCKER_HOST
      value: tcp://localhost:2375
    - name: DOCKER_BUILDKIT
      value: "1"
    volumeMounts:
      - name: jenkins-sa
        mountPath: /root/.gcp/
  volumes:
    - name: dind-storage
      emptyDir: {}
    - name: jenkins-sa
      secret:
        secretName: jenkins-sa
"""
    }
  }

  environment {
    sc_regions = "mumbai"
    app        = "beyla-custom"
    imagetags  = "beya-2-patch"
    buildarg_DEPLOYMENT_ID = "beyla-custom-$GIT_COMMIT"
    buildarg_BUILDARCH     = "amd64"
  }

  stages {
    stage('build') {
      when {
        anyOf {
          branch 'sharechat-custom'
        }
      }
      steps {
        container('builder') {
          sh '''
            set -eu
            git config --global --add safe.directory '*'
            # .obi-src must be populated in the build context for the Dockerfile's
            # jni/javaagent COPY stages. The traceparent patch itself is applied
            # INSIDE the Dockerfile (after its own make-generate submodule checkout),
            # so we do NOT git apply on the host here.
            git submodule update --init --recursive
            armory build
          '''
        }
      }
    }

    stage('push') {
      when {
        anyOf {
          branch 'sharechat-custom'
        }
      }
      steps {
        container('builder') {
          sh '''
            set -eu
            armory push
          '''
        }
      }
    }
  }
}
