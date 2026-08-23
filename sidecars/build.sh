#!/usr/bin/env bash
# Build the EterDB sidecars + orchestrator as small, dependency-free static
# binaries (see docs/adr/0001-sidecars-in-go.md). Output: sidecars/bin/
# eter-capture, eter-storage, eter-orchestrator.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="${1:-$here/bin}"
mkdir -p "$out"
CGO_ENABLED=0 go build -C "$here" -o "$out/eter-capture" ./capture
CGO_ENABLED=0 go build -C "$here" -o "$out/eter-storage" ./storage
CGO_ENABLED=0 go build -C "$here" -o "$out/eter-orchestrator" ./orchestrator
echo "built: $out/eter-capture $out/eter-storage $out/eter-orchestrator"
