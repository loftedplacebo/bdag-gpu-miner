#!/usr/bin/env bash
set -euo pipefail

ENV_FILE=".env"
EXAMPLE_FILE=".env.example"

if [[ ! -f "$ENV_FILE" ]]; then
  if [[ -f "$EXAMPLE_FILE" ]]; then
    cp "$EXAMPLE_FILE" "$ENV_FILE"
    echo "Created .env from .env.example"
    echo "Edit .env and set your WALLET before running again."
    exit 1
  else
    echo "Missing .env and .env.example" >&2
    exit 1
  fi
fi

# Load simple KEY=VALUE lines from .env
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

: "${POOL_HOST:=excalibur.dagtech.network}"
: "${POOL_PORT:=3335}"
: "${WALLET:=}"
: "${PASSWORD:=x}"
: "${WORKER_NAME:=$WALLET}"
: "${RUNTIME_SECONDS:=9999999999999}"
: "${SUBMIT_MARGIN:=1.02}"
: "${MIN_SUBMIT_THRESHOLD:=0.25}"
: "${EXTRANONCE2_HEX:=00000000}"
: "${BATCHSIZE:=32768}"

if [[ ! "$WALLET" =~ ^0x[a-fA-F0-9]{40}$ ]]; then
  echo "Invalid WALLET in .env" >&2
  echo "Expected a 42-character EVM-style address, e.g. 0xabc...123" >&2
  exit 1
fi

if [[ "$WALLET" == "0x0000000000000000000000000000000000000000" ]]; then
  echo "Please replace the placeholder WALLET in .env before mining." >&2
  exit 1
fi

if [[ ! -x ./build/bdag_v20_miner ]]; then
  echo "Missing executable ./build/bdag_v20_miner" >&2
  echo "Run ./scripts/build.sh first, or download a release package that includes the binary." >&2
  exit 1
fi

echo "BDAG GPU Miner v20"
echo "Pool:        ${POOL_HOST}:${POOL_PORT}"
echo "Wallet:      ${WALLET:0:8}...${WALLET: -6}"
echo "Worker name: ${WORKER_NAME}"
echo "Runtime:     ${RUNTIME_SECONDS}s"
echo

exec ./build/bdag_v20_miner \
  --host "$POOL_HOST" \
  --port "$POOL_PORT" \
  --wallet "$WALLET" \
  --password "$PASSWORD" \
  --worker-name "$WORKER_NAME" \
  --runtime "$RUNTIME_SECONDS" \
  --margin "$SUBMIT_MARGIN" \
  --min-threshold "$MIN_SUBMIT_THRESHOLD" \
  --extranonce2 "$EXTRANONCE2_HEX" \
  --batchsize "$BATCHSIZE"

