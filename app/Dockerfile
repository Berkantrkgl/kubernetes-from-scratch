# syntax=docker/dockerfile:1

FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /build

# pom on its own first: this layer survives every source-only change, and the
# cache mount keeps the downloads out of the image
COPY pom.xml .
RUN --mount=type=cache,target=/root/.m2 mvn -B dependency:go-offline

COPY src ./src
RUN --mount=type=cache,target=/root/.m2 mvn -B clean package

RUN java -Djarmode=tools -jar target/query-echo-*.jar \
      extract --layers --launcher --destination extracted

# distroless cannot mkdir, it has no shell, so the log directory is built here
RUN mkdir -p /logdir


FROM gcr.io/distroless/java21-debian12:nonroot
WORKDIR /app

# ordered by how often each changes: 24 MB of dependencies first, 84 KB of
# application classes last
COPY --from=build /build/extracted/dependencies/ ./
COPY --from=build /build/extracted/spring-boot-loader/ ./
COPY --from=build /build/extracted/snapshot-dependencies/ ./
COPY --from=build /build/extracted/application/ ./

COPY --from=build --chown=65532:65532 /logdir /var/log/query-echo

# numeric, so kubelet can enforce runAsNonRoot without resolving a name
USER 65532:65532

EXPOSE 9001

ENTRYPOINT ["java", "-XX:MaxRAMPercentage=75.0", "org.springframework.boot.loader.launch.JarLauncher"]
