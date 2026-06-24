// Custom Beyla image build (ShareChat) — backports upstream OBI PR #1988
// (configurable large-header traceparent scan, OTEL_EBPF_BPF_MAX_REQUEST_TP_PARSE_SIZE_KB)
// on top of Beyla release-3.20 (.obi-src pinned to dd2d305a / v3.20.0).
// Ref: https://github.com/open-telemetry/opentelemetry-ebpf-instrumentation/pull/1988
//      https://github.com/open-telemetry/opentelemetry-ebpf-instrumentation/issues/1381
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
    imagetags  = "v3.20.0-tp1988-largehdr"
    buildarg_DEPLOYMENT_ID = "beyla-custom-$GIT_COMMIT"
    buildarg_BUILDARCH     = "amd64"
  }

  stages {
    stage('build') {
      when {
        anyOf {
          branch 'tphdr-debug-logging'
          branch 'master'
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
          branch 'tphdr-debug-logging'
          branch 'master'
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
