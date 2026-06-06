# BDAG GPU Miner

Experimental CUDA GPU miner for the BlockDAG network.

This miner is designed for Linux machines with NVIDIA GPUs. It has been tested on a fresh Vast.ai GPU instance using an RTX 3060.

## What This Does

The miner connects to a BlockDAG mining pool, receives mining jobs, scans nonces using a CUDA GPU, and submits valid shares back to the pool.

Configuration is handled through a local `.env` file, so users do not need to edit source code to change wallet, pool, tuning, or worker settings.

## Requirements

- Linux / Ubuntu GPU server
- NVIDIA GPU
- NVIDIA drivers
- CUDA toolkit with `nvcc`
- `git`
- `make`
- Internet access
- BlockDAG-compatible wallet address starting with `0x`

This is intended for GPU VPS platforms such as Vast.ai, RunPod, or your own CUDA Linux machine.

## Quick Start

```bash
git clone https://github.com/loftedplacebo/bdag-gpu-miner.git
cd bdag-gpu-miner
cp .env.example .env
nano .env
```

Edit your wallet address:

```bash
WALLET=0xYourWalletAddressHere
```

Build and run:

```bash
chmod +x scripts/build.sh run.sh keepalive.sh
CUDA_ARCH=sm_86 ./scripts/build.sh
./run.sh
```

Use `CUDA_ARCH=sm_86` for RTX 30-series cards such as the RTX 3060. Use `sm_89` for RTX 40-series and `sm_80` for A100.

## Configuration

All user settings are controlled through `.env`.

```bash
POOL_HOST=62.171.161.32
POOL_PORT=3334
WALLET=0xYourWalletAddressHere
WORKER_NAME=gpu01
PASSWORD=x
RUNTIME_SECONDS=9999999999999

SUBMIT_MARGIN=1.02
MIN_SUBMIT_THRESHOLD=0.0
EXTRANONCE2_HEX=00000000
BATCHSIZE=32768

AUTOTUNE=1
AUTOTUNE_SECONDS=1800
AUTOTUNE_BATCHES=16384,32768,49152,65536
AUTOTUNE_FORCE=0
AUTOTUNE_CACHE=.miner-autotune.json
KERNEL_MODE=auto
TARGET_BATCH_MS=1500
AUTO_THRESHOLD=1
```

| Setting | Description |
| --- | --- |
| `POOL_HOST` | Mining pool hostname or IP address |
| `POOL_PORT` | Mining pool stratum port |
| `WALLET` | BlockDAG-compatible wallet address |
| `WORKER_NAME` | Optional worker label |
| `PASSWORD` | Stratum password, usually `x` |
| `RUNTIME_SECONDS` | Runtime before exit; large value runs effectively continuously |
| `SUBMIT_MARGIN` | Share threshold margin above pool difficulty |
| `MIN_SUBMIT_THRESHOLD` | Minimum share threshold; `0.0` follows pool difficulty |
| `EXTRANONCE2_HEX` | Extranonce2 override, usually `00000000` |
| `BATCHSIZE` | GPU nonces scanned per batch when autotune is disabled or uncached |
| `AUTOTUNE` | Enable launch optimisation and local cache |
| `AUTOTUNE_SECONDS` | Total first-run autotune budget |
| `AUTOTUNE_BATCHES` | Comma-separated batch sizes to test |
| `AUTOTUNE_FORCE` | Ignore cached autotune result and retune |
| `AUTOTUNE_CACHE` | Local autotune cache path |
| `KERNEL_MODE` | `split`, `combo`, or `auto` |
| `TARGET_BATCH_MS` | Preferred maximum batch latency for stale-share control |
| `AUTO_THRESHOLD` | Increase submit margin after low-difficulty rejects |

## RTX 3060 Starting Point

For an RTX 3060, start with:

```bash
CUDA_ARCH=sm_86 ./scripts/build.sh
AUTOTUNE_FORCE=1 ./run.sh
```

Recommended `.env` tuning:

```bash
AUTOTUNE=1
AUTOTUNE_SECONDS=1800
AUTOTUNE_BATCHES=16384,32768,49152,65536
KERNEL_MODE=auto
TARGET_BATCH_MS=1500
SUBMIT_MARGIN=1.02
MIN_SUBMIT_THRESHOLD=0.0
AUTO_THRESHOLD=1
```

After the first successful tune, set `AUTOTUNE_FORCE=0` so the miner reuses `.miner-autotune.json`.

## Autotune

With `AUTOTUNE=1`, the miner tests configured batch sizes and split/combo kernel modes on launch. It scores candidates by hashrate, accepted share rate, rejects, stale work, and batch latency.

The winning result is written to `.miner-autotune.json`. That file is ignored by git and reused on later starts unless `AUTOTUNE_FORCE=1` is set.

The goal is not just maximum displayed MH/s. The goal is the best accepted-share rate with batch latency low enough to avoid unnecessary stale work.

## Running Continuously

For long-running GPU rentals, use `keepalive.sh` instead of running `run.sh` directly. It restarts the miner automatically if the pool connection drops or the miner exits.

Start on the GPU VPS:

```bash
cd /workspace/bdag-gpu-miner
mkdir -p logs
nohup ./keepalive.sh > logs/keepalive_$(date +%Y%m%d_%H%M%S).log 2>&1 &
echo $! > keepalive.pid
```

Check it is running:

```bash
ps -p $(cat keepalive.pid) -o pid,etime,cmd
ps aux | grep -E "keepalive|bdag_v20_miner" | grep -v grep
nvidia-smi
```

Watch logs:

```bash
LATEST=$(ls -t logs/miner_*.log | head -1)
echo "$LATEST"
tail -f "$LATEST"
```

Stop it:

```bash
kill $(cat keepalive.pid)
pkill -f bdag_v20_miner
```

## Expected Behaviour

When running correctly, the miner should:

- connect to the pool
- subscribe and authorise
- receive jobs
- scan nonces on the GPU
- submit valid shares
- show accepted shares in the console or pool logs

A small number of stale shares can happen if jobs change quickly.

## Common Issues

`nvcc: command not found`

The CUDA compiler is missing. Use a CUDA development image, not only a runtime image.

`Invalid WALLET in .env`

Check that your wallet starts with `0x` and is 42 characters long.

`Cannot connect to pool`

Check the pool host, pool port, firewall rules, and VPS network access.

`Permission denied`

```bash
chmod +x scripts/build.sh run.sh keepalive.sh
```

## Warning

This is experimental mining software.

Use at your own risk. No guarantee is made around profitability, compatibility, uptime, rewards, or correctness on every machine.

You are responsible for checking that your wallet, pool settings, and mining environment are correct.

## Licence

No licence has currently been selected. All rights reserved unless a licence is added later.
