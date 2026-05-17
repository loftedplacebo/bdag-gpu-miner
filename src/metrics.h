#pragma once

#include <atomic>
#include <cstdint>
#include <string>

struct MinerMetrics {
    std::atomic<uint64_t> checked{0};
    std::atomic<uint64_t> submitted{0};
    std::atomic<uint64_t> accepted{0};
    std::atomic<uint64_t> errors{0};
    std::atomic<uint64_t> lowdiff{0};
    std::atomic<uint64_t> stale_errors{0};
    std::atomic<uint64_t> stale_skipped{0};
    std::atomic<uint64_t> nohit_batches{0};
    std::atomic<uint64_t> hit_batches{0};
};

std::string format_v20_result(
    const MinerMetrics &m,
    double elapsed,
    int batchsize,
    uint64_t batches
);
