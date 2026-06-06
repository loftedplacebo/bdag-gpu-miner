#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

./build/bdag_v20_miner \
  --host 62.171.161.32 \
  --port 3334 \
  --wallet 0xc12ee9dC15c3Fc7FCe8Ae2Ef8eD84e92c0B72310 \
  --runtime "${RUNTIME_SECONDS:-300}" \
  --margin "${MARGIN:-1.02}" \
  --min-threshold "${MIN_THRESHOLD:-0.0}" \
  --batchsize "${BATCHSIZE:-32768}" \
  --kernel-mode "${KERNEL_MODE:-split}"
