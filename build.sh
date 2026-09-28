#!/usr/bin/env bash
# Rebuild com.utmstack.misp.plugin from source (optional - prebuilt binaries are in bin/).
# Uses a local Go >= 1.25.5 if present, otherwise the official golang Docker image.
# Output: plugin/com.utmstack.misp.plugin (install.sh picks it up if bin/ is missing it)
set -euo pipefail
cd "$(dirname "$0")/plugin"
ARCH=${GOARCH:-$(uname -m | sed 's/x86_64/amd64/; s/aarch64/arm64/')}
CMD="go mod tidy && go test ./... && CGO_ENABLED=0 GOOS=linux GOARCH=${ARCH} go build -trimpath -ldflags '-s -w' -o com.utmstack.misp.plugin ."

if command -v go >/dev/null && go version | grep -qE 'go1\.(2[5-9]|[3-9][0-9])'; then
  bash -c "$CMD"
else
  docker run --rm -v "$PWD":/src -w /src golang:1.25 bash -c "$CMD"
fi
sha256sum com.utmstack.misp.plugin
