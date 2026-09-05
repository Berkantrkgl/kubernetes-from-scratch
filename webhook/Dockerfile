# syntax=docker/dockerfile:1

FROM golang:1.26-alpine AS build
WORKDIR /build

# go.mod on its own first, same reasoning as the pom in app/Dockerfile
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download

COPY *.go ./
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    go test ./...

# static: the distroless base carries no libc to link against
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 go build -ldflags="-s -w" -o /out/webhook .


FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/webhook /webhook

# numeric, so kubelet can enforce runAsNonRoot without resolving a name
USER 65532:65532

EXPOSE 8443

ENTRYPOINT ["/webhook"]
