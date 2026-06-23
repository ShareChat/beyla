// Custom Beyla image build (ShareChat) — adds [TPHDR] traceparent-extraction
// logging on top of upstream Beyla v3.22.2 (OBI v3.20.0).
//
// The code change lives as a patch in patches/ (the .obi-src submodule points at
// grafana upstream and is not pushable), applied to .obi-src at build time. The
// repo Dockerfile is self-contained (multi-stage: obi-generator -> go build), so
// a plain `docker build` regenerates eBPF and compiles the patched Go.
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
    imagetags  = "v3.22.2-tphdr-debug"
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
            # The traceparent patch is applied INSIDE the Dockerfile (after its own
            # `make generate` submodule checkout) — a host-side apply is wiped by it.
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
