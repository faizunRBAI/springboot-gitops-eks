# syntax=docker/dockerfile:1

# Base images are pinned to explicit version tags (not :latest).
# Hardening step: replace each tag with its immutable digest once pulled, e.g.
#   docker pull eclipse-temurin:21.0.5_11-jre-alpine
#   docker inspect --format='{{index .RepoDigests 0}}' eclipse-temurin:21.0.5_11-jre-alpine
# Digests are deliberately NOT guessed here: a wrong digest fails the pull with
# "manifest unknown".

# ---------- Stage 1: build ----------
FROM maven:3.9.9-eclipse-temurin-21 AS build
WORKDIR /build

# Dependencies resolve in their own layer: unchanged pom.xml means this whole
# step is cached, so a code-only commit skips the full dependency download.
COPY pom.xml .
RUN mvn -B -ntp dependency:go-offline

COPY src ./src
RUN mvn -B -ntp clean package -DskipTests

# Spring Boot layered JAR: split the fat jar into layers ordered by change
# frequency so image pushes/pulls only move the layer that actually changed.
RUN java -Djarmode=layertools -jar target/*.jar extract --destination /build/layers

# ---------- Stage 2: runtime ----------
FROM eclipse-temurin:21.0.5_11-jre-alpine AS runtime

RUN apk add --no-cache curl \
    && addgroup -S -g 10001 app \
    && adduser -S -u 10001 -G app app

WORKDIR /app

# Copy layers least-changing first to maximise layer reuse.
COPY --from=build --chown=app:app /build/layers/dependencies/ ./
COPY --from=build --chown=app:app /build/layers/spring-boot-loader/ ./
COPY --from=build --chown=app:app /build/layers/snapshot-dependencies/ ./
COPY --from=build --chown=app:app /build/layers/application/ ./

USER app:app
EXPOSE 8080

# Container-aware heap sizing; the JVM reads the cgroup limit set by Kubernetes.
ENV JAVA_OPTS="-XX:MaxRAMPercentage=75.0 -XX:InitialRAMPercentage=50.0 -XX:+UseG1GC"

HEALTHCHECK --interval=30s --timeout=5s --start-period=45s --retries=3 \
    CMD curl --fail --silent http://localhost:8080/actuator/health/liveness || exit 1

# Exec form: the JVM becomes PID 1 and receives SIGTERM directly, which is what
# makes server.shutdown=graceful work when Argo Rollouts drains an old pod.
# A shell-form ENTRYPOINT would swallow the signal and every rollout would end
# in a 30s SIGKILL with dropped in-flight requests.
ENTRYPOINT ["sh", "-c", "exec java $JAVA_OPTS org.springframework.boot.loader.launch.JarLauncher"]
