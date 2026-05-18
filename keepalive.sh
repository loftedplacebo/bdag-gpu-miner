#!/usr/bin/env bash
set -u

cd "$(dirname "$0")"
mkdir -p logs

while true; do
  TS=$(date +%Y%m%d_%H%M%S)
  LOG="logs/miner_${TS}.log"

  echo "[$(date)] Starting BDAG GPU miner..." | tee -a "$LOG"
  bash run.sh >> "$LOG" 2>&1
  EXIT_CODE=$?

  echo "[$(date)] Miner exited with code ${EXIT_CODE}. Restarting in 10 seconds..." | tee -a "$LOG"
  sleep 10
done