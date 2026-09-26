#!/usr/bin/env bash
set -euo pipefail
version=$(awk '
  $1 == "require" && $2 == "tailscale.com" {v=$3}
  $1 == "tailscale.com" {v=$2}
  END {sub(/^v/, "", v); print v}
' go.mod)
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Expected a stable Tailscale release in go.mod, got: $version" >&2
  exit 1
fi
printf '%s\n' "$version"
