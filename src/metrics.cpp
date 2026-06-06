#include "metrics.h"

#include <iomanip>
#include <sstream>

std::string format_v20_result(
    const MinerMetrics &m,
    double elapsed,
    int batchsize,
    uint64_t batches
) {
    double hps = elapsed > 0.0 ? (double)m.checked.load() / elapsed : 0.0;
    double accepted_per_sec = elapsed > 0.0 ? ((double)m.accepted.load() / elapsed) : 0.0;
    double submitted_per_sec = elapsed > 0.0 ? ((double)m.submitted.load() / elapsed) : 0.0;
    double stale_err_rate = m.errors.load() > 0 ? ((double)m.stale_errors.load() / (double)m.errors.load()) : 0.0;
    double accepted_rate = m.submitted.load() > 0 ? ((double)m.accepted.load() / (double)m.submitted.load()) : 0.0;
    double avg_batch_ms = m.timed_batches.load() > 0
        ? ((double)m.batch_us.load() / (double)m.timed_batches.load()) / 1000.0
        : 0.0;
    double max_batch_ms = (double)m.max_batch_us.load() / 1000.0;

    std::ostringstream oss;
    oss << "[V20_RESULT]"
        << " runtime_s=" << std::fixed << std::setprecision(1) << elapsed
        << " batchsize=" << batchsize
        << " checked=" << m.checked.load()
        << " hashrate_hs=" << std::fixed << std::setprecision(1) << hps
        << " hashrate_mhs=" << std::fixed << std::setprecision(4) << (hps / 1000000.0)
        << " batches=" << batches
        << " avg_batch_ms=" << std::fixed << std::setprecision(2) << avg_batch_ms
        << " max_batch_ms=" << std::fixed << std::setprecision(2) << max_batch_ms
        << " hit_batches=" << m.hit_batches.load()
        << " nohit_batches=" << m.nohit_batches.load()
        << " submitted=" << m.submitted.load()
        << " accepted=" << m.accepted.load()
        << " errors=" << m.errors.load()
        << " low=" << m.lowdiff.load()
        << " stale_err=" << m.stale_errors.load()
        << " stale_skipped=" << m.stale_skipped.load()
        << " accepted_per_sec=" << std::fixed << std::setprecision(4) << accepted_per_sec
        << " submitted_per_sec=" << std::fixed << std::setprecision(4) << submitted_per_sec
        << " accepted_rate=" << std::fixed << std::setprecision(4) << accepted_rate
        << " stale_err_rate=" << std::fixed << std::setprecision(4) << stale_err_rate;

    return oss.str();
}
