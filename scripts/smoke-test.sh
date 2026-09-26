#!/usr/bin/env bash
set -euo pipefail
image=${1:-derp:test}
tmp=$(mktemp -d)
containers=()
cleanup() {
  for id in "${containers[@]}"; do
    docker logs "$id" || true
    docker rm -f "$id" >/dev/null || true
  done
  rm -rf "$tmp"
}
trap cleanup EXIT
chmod 755 "$tmp"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -subj /CN=localhost -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1' \
  -keyout "$tmp/localhost.key" -out "$tmp/localhost.crt" 2>/dev/null
chmod 644 "$tmp/localhost.key" "$tmp/localhost.crt"
test "$(docker image inspect "$image" --format '{{.Config.User}}')" = '65532:65532'
version=$(bash scripts/version.sh)
for binary in derper derpprobe; do
  actual=$(docker run --rm "$image" "$binary" -version)
  if [[ "$actual" != "$version-local" ]]; then
    echo "$binary version mismatch: expected $version-local, got $actual" >&2
    exit 1
  fi
done
for mode in relay verify; do
  extra=()
  if [[ "$mode" == verify ]]; then extra=(-verify-clients); fi
  id=$(docker run -d --read-only --cap-drop=ALL --security-opt=no-new-privileges \
    --sysctl net.ipv4.ip_unprivileged_port_start=0 \
    --tmpfs /data:uid=65532,gid=65532,mode=0700 \
    -v "$tmp:/certs:ro" -p 127.0.0.1::443 -p 127.0.0.1::3478/udp \
    "$image" derper -c=/data/derper.key -hostname=localhost \
    -certmode=manual -certdir=/certs -http-port=-1 "${extra[@]}")
  containers+=("$id")
  address=$(docker port "$id" 443/tcp)
  url="https://localhost:${address##*:}"
  for attempt in {1..30}; do
    if curl --silent --fail --cacert "$tmp/localhost.crt" "$url/" >/dev/null; then break; fi
    sleep 1
  done
  curl --silent --fail --cacert "$tmp/localhost.crt" "$url/" >/dev/null
  if [[ "$mode" == relay ]]; then
    export DERP_URL="$url"
    export STUN_ADDR
    STUN_ADDR=$(docker port "$id" 3478/udp)
  else
    export DERP_VERIFY_URL="$url"
    export DERP_VERIFY_ADDR="$address"
  fi
done
export DERP_CA="$tmp/localhost.crt"
go test -count=1 -timeout=60s -v ./tests
cat > "$tmp/derpmap.json" <<'JSON'
{"Regions":{"900":{"RegionID":900,"RegionCode":"test","RegionName":"Smoke test","Nodes":[{"Name":"900a","RegionID":900,"HostName":"localhost","IPv4":"127.0.0.1","IPv6":"","DERPPort":443,"STUNPort":3478}]}}}
JSON
timeout 90s docker run --rm --network "container:${containers[0]}" \
  --read-only --cap-drop=ALL --security-opt=no-new-privileges \
  -e SSL_CERT_FILE=/probe/localhost.crt -v "$tmp:/probe:ro" \
  "$image" derpprobe -derp-map=file:///probe/derpmap.json -once -spread=false
