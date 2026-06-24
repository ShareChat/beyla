// Custom Beyla image build (ShareChat) — adds a configurable large-header
// traceparent scan window (OTEL_EBPF_BPF_MAX_REQUEST_TP_PARSE_SIZE_KB) on top of
// the Beyla 3.24 base (.obi-src pinned to v3.24.0 / 54f2f639), which carries BOTH
// mega-trace fixes the 3.22 line lacked: the connection/Kafka stale-parent fix AND
// the readMimeHeader stale-bytes fix.
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
    imagetags  = "custom-beyla-v3.24.0"
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
