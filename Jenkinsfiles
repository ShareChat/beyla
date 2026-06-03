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
    livenessProbe:
      tcpSocket:
        port: 2375
      initialDelaySeconds: 30
      periodSeconds: 20
  - name: builder
    image: sc-mum-armory.platform.internal/devops/builder-image-armory
    command:
    - sleep
    - infinity
    env:
    - name: DOCKER_HOST
      value: tcp://localhost:2375
    - name: DOCKER_BUILDKIT
      value: "0"
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

  options {
    timeout(time: 30, unit: 'MINUTES')
    copyArtifactPermission('*')
  }


  environment {
    app="beyla-custom"
    sc_regions="mumbai"
    dockerfile="Dockerfile.custom"
    buildarg_DEPLOYMENT_ID="beyla-custom-$GIT_COMMIT"
    buildarg_GITHUB_TOKEN=credentials('github-access')
  }
   stages{
    stage('build') {
      steps {
        container('builder') {
           sh 'armory build -f Dockerfile.custom'
        }
      }
    }
    stage('push') {
      when {
        anyOf {
          branch 'feature/ringbuf-fix-v3.20.0'
        }
      }
      steps {
        container('builder') {
          sh "armory push"
        }
      }
    }
  }
}