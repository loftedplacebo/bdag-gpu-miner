#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

mkdir -p build

CUDA_ARCH="${CUDA_ARCH:-sm_86}"
NVCC_FLAGS=(--gpu-architecture "$CUDA_ARCH" -O3 -std=c++17)

if [[ "${PTXAS_VERBOSE:-0}" == "1" ]]; then
  NVCC_FLAGS+=(--ptxas-options=-v)
fi

if [[ "${CUDA_LINEINFO:-0}" == "1" ]]; then
  NVCC_FLAGS+=(-lineinfo)
fi

echo "Building for CUDA_ARCH=${CUDA_ARCH}"

nvcc "${NVCC_FLAGS[@]}" \
  -c src/hasher.cu \
  -o build/hasher.o

g++ -O3 -std=c++17 -c src/config.cpp -o build/config.o
g++ -O3 -std=c++17 -c src/metrics.cpp -o build/metrics.o
g++ -O3 -std=c++17 -c src/payload_builder.cpp -o build/payload_builder.o

nvcc "${NVCC_FLAGS[@]}" \
  build/hasher.o build/config.o build/metrics.o build/payload_builder.o src/main_v20.cu \
  -o build/bdag_v20_miner \
  -lcrypto \
  -Xcompiler -pthread

echo "Built ./build/bdag_v20_miner"
