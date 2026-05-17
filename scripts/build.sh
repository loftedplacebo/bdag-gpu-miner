#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

mkdir -p build

nvcc --gpu-architecture sm_86 -O3 -std=c++17 \
  -c src/hasher.cu \
  -o build/hasher.o

g++ -O3 -std=c++17 -c src/config.cpp -o build/config.o
g++ -O3 -std=c++17 -c src/metrics.cpp -o build/metrics.o
g++ -O3 -std=c++17 -c src/payload_builder.cpp -o build/payload_builder.o

nvcc --gpu-architecture sm_86 -O3 -std=c++17 \
  build/hasher.o build/config.o build/metrics.o build/payload_builder.o src/main_v20.cu \
  -o build/bdag_v20_miner \
  -lcrypto \
  -Xcompiler -pthread

echo "Built ./build/bdag_v20_miner"
