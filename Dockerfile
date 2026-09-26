FROM --platform=$BUILDPLATFORM golang:1.27.1-alpine3.24@sha256:8a5910f31396cd4d89662f56c68b3ae31d374308270a1c3bd96672ee5ed43414 AS build

WORKDIR /src
ENV CGO_ENABLED=0 GOTOOLCHAIN=local
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download && go mod verify

ARG TARGETOS
ARG TARGETARCH
ARG IMAGE_VERSION
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    set -eu; \
    version="$(go list -m -f '{{.Version}}' tailscale.com)"; \
    version="${version#v}"; \
    GOOS="$TARGETOS" GOARCH="$TARGETARCH" go build -mod=readonly -trimpath \
      -ldflags="-s -w -X tailscale.com/version.shortStamp=$version -X tailscale.com/version.longStamp=${IMAGE_VERSION:-$version-local}" \
      -o /out/ tailscale.com/cmd/derper tailscale.com/cmd/derpprobe; \
    cp "$(go list -m -f '{{.Dir}}' tailscale.com)/LICENSE" /out/LICENSE.tailscale; \
    mkdir -p /out/data/certs; \
    chmod 0700 /out/data /out/data/certs; \
    printf 'derper:x:65532:65532:DERP:/data:/sbin/nologin\n' > /out/passwd; \
    printf 'derper:x:65532:\n' > /out/group

FROM scratch
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=build /out/passwd /etc/passwd
COPY --from=build /out/group /etc/group
COPY --from=build /out/LICENSE.tailscale /usr/share/licenses/tailscale/LICENSE
COPY --from=build /out/derper /out/derpprobe /usr/local/bin/
COPY --from=build --chown=65532:65532 /out/data /data
ENV PATH=/usr/local/bin HOME=/data
USER 65532:65532
WORKDIR /data
EXPOSE 80/tcp 443/tcp 3478/udp
CMD ["derper", "-c=/data/derper.key", "-certdir=/data/certs"]
