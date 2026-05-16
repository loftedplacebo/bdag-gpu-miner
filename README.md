# BDAG Kepler GPU Miner

Experimental NVIDIA CUDA GPU miner for connecting to a BlockDAG-compatible stratum pool.

This release is intended for testers. It is not financial advice, has no warranty, and may produce different results depending on GPU model, driver, CUDA version, pool difficulty, and network conditions.

## Requirements

- Linux x86_64
- NVIDIA GPU
- NVIDIA driver installed
- CUDA toolkit with `nvcc` available if building from source
- OpenSSL development libraries

On Ubuntu/Debian, the common build dependency is:

```bash
sudo apt update
sudo apt install -y build-essential libssl-dev
```

Install the NVIDIA driver and CUDA toolkit using the appropriate method for your host or rental provider.

## Quick start

```bash
git clone <YOUR_REPO_URL_HERE>
cd bdag-kepler-gpu-miner
cp .env.example .env
nano .env
./build.sh
./run.sh
```

The first time you run `./run.sh`, it will create `.env` automatically if it does not already exist. You must edit `.env` and replace the placeholder wallet before mining.

## Configuration

Edit `.env`:

```bash
POOL_HOST=62.171.161.32
POOL_PORT=3334
WALLET=0xYourWalletAddressHere
PASSWORD=x
RUNTIME_SECONDS=600
SUBMIT_MARGIN=1.02
MIN_SUBMIT_THRESHOLD=0.25
EXTRANONCE2_HEX=00000000
```

### Important fields

| Field | Purpose |
|---|---|
| `POOL_HOST` | Mining pool host or IP address |
| `POOL_PORT` | Mining pool stratum port |
| `WALLET` | Your payout wallet address |
| `RUNTIME_SECONDS` | How long the miner runs before exiting |
| `SUBMIT_MARGIN` | Share submission safety margin |
| `MIN_SUBMIT_THRESHOLD` | Minimum share threshold used by the miner |

The wallet must be a 42-character EVM-style address beginning with `0x`.

## Build

```bash
./build.sh
```

The current build script targets `sm_86`. If your GPU uses a different architecture, edit `build.sh` and change the `--gpu-architecture` value.

Common examples:

| GPU family | CUDA arch example |
|---|---|
| RTX 30 series | `sm_86` |
| RTX 40 series | `sm_89` |
| Older Tesla/Kepler | may require older CUDA/toolchain support |

## Run

```bash
./run.sh
```

The script prints the pool and a shortened wallet address before starting so you can confirm you are mining to the correct wallet.

## Security notes

- Do not commit your `.env` file.
- Do not put private keys, seed phrases, exchange API keys, or VPS passwords in this repository.
- This miner only needs a public payout wallet address.

## Project status

Experimental public testing release.
