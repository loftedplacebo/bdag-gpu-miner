#include "config.h"

#include <cstdlib>
#include <iostream>

void print_usage(const char *argv0) {
    std::cout
        << "Usage: " << argv0 << " [options]\n"
        << "Options:\n"
        << "  --host <host>               Pool host\n"
        << "  --port <port>               Pool port\n"
        << "  --wallet <0x...>            Wallet address\n"
        << "  --password <password>       Stratum password, default x\n"
        << "  --worker-name <name>        Optional worker label for logs\n"
        << "  --runtime <seconds>         Runtime before exit, 0 = run forever\n"
        << "  --margin <value>            Submit margin, default 1.02\n"
        << "  --min-threshold <value>     Minimum submit threshold, default 0.0\n"
        << "  --extranonce2 <hex>         Extranonce2 override, default 00000000\n"
        << "  --batchsize <n>             GPU batch size, 0 = auto\n"
        << "  --mem-per-job <bytes>       Auto batch memory estimate\n"
        << "  --kernel-mode <mode>        split, combo, or auto\n"
        << "  --autotune                  Tune batch size/kernel mode before steady mining\n"
        << "  --no-autotune               Disable launch autotune\n"
        << "  --autotune-force            Ignore cached autotune result\n"
        << "  --autotune-seconds <n>      Total autotune budget, default 1800\n"
        << "  --autotune-min-trial-seconds <n> Minimum valid trial duration\n"
        << "  --autotune-min-trial-ratio <n> Minimum valid trial ratio\n"
        << "  --autotune-batches <list>   Comma-separated batch sizes\n"
        << "  --autotune-cache <path>     Autotune cache path\n"
        << "  --autotune-failed-cache <path> Partial/failed autotune output path\n"
        << "  --target-batch-ms <ms>      Preferred max batch latency\n"
        << "  --auto-threshold            Increase submit margin after lowdiff rejects\n"
        << "  --no-auto-threshold         Disable adaptive submit threshold\n"
        << "  --help                      Show this help\n";
}

bool is_valid_wallet(const std::string &wallet) {
    if (wallet.size() != 42) return false;
    if (wallet.rfind("0x", 0) != 0 && wallet.rfind("0X", 0) != 0) return false;

    for (size_t i = 2; i < wallet.size(); ++i) {
        char c = wallet[i];
        bool is_hex =
            (c >= '0' && c <= '9') ||
            (c >= 'a' && c <= 'f') ||
            (c >= 'A' && c <= 'F');
        if (!is_hex) return false;
    }

    return true;
}

bool parse_args(int argc, char **argv, MinerConfig &cfg) {
    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];

        if (a == "--help" || a == "-h") {
            print_usage(argv[0]);
            return false;
        } else if (a == "--host" && i + 1 < argc) {
            cfg.pool_host = argv[++i];
        } else if (a == "--port" && i + 1 < argc) {
            cfg.pool_port = std::atoi(argv[++i]);
        } else if (a == "--wallet" && i + 1 < argc) {
            cfg.wallet = argv[++i];
        } else if (a == "--password" && i + 1 < argc) {
            cfg.password = argv[++i];
        } else if (a == "--worker-name" && i + 1 < argc) {
            cfg.worker_name = argv[++i];
        } else if (a == "--runtime" && i + 1 < argc) {
            cfg.runtime_seconds = std::atoi(argv[++i]);
        } else if (a == "--margin" && i + 1 < argc) {
            cfg.submit_margin = std::strtold(argv[++i], nullptr);
        } else if (a == "--min-threshold" && i + 1 < argc) {
            cfg.min_submit_threshold = std::strtold(argv[++i], nullptr);
        } else if (a == "--extranonce2" && i + 1 < argc) {
            cfg.extranonce2_hex = argv[++i];
        } else if (a == "--batchsize" && i + 1 < argc) {
            cfg.gpu_batchsize = std::atoi(argv[++i]);
        } else if (a == "--mem-per-job" && i + 1 < argc) {
            cfg.gpu_mem_per_job = std::atoi(argv[++i]);
        } else if (a == "--kernel-mode" && i + 1 < argc) {
            cfg.kernel_mode = argv[++i];
        } else if (a == "--autotune") {
            cfg.autotune = true;
        } else if (a == "--no-autotune") {
            cfg.autotune = false;
        } else if (a == "--autotune-force") {
            cfg.autotune_force = true;
        } else if (a == "--autotune-seconds" && i + 1 < argc) {
            cfg.autotune_seconds = std::atoi(argv[++i]);
        } else if (a == "--autotune-min-trial-seconds" && i + 1 < argc) {
            cfg.autotune_min_trial_seconds = std::atoi(argv[++i]);
        } else if (a == "--autotune-min-trial-ratio" && i + 1 < argc) {
            cfg.autotune_min_trial_ratio = std::atof(argv[++i]);
        } else if (a == "--autotune-batches" && i + 1 < argc) {
            cfg.autotune_batches = argv[++i];
        } else if (a == "--autotune-cache" && i + 1 < argc) {
            cfg.autotune_cache = argv[++i];
        } else if (a == "--autotune-failed-cache" && i + 1 < argc) {
            cfg.autotune_failed_cache = argv[++i];
        } else if (a == "--target-batch-ms" && i + 1 < argc) {
            cfg.target_batch_ms = std::atof(argv[++i]);
        } else if (a == "--auto-threshold") {
            cfg.auto_threshold = true;
        } else if (a == "--no-auto-threshold") {
            cfg.auto_threshold = false;
        } else {
            std::cerr << "[V20] Unknown or incomplete argument: " << a << "\n";
            print_usage(argv[0]);
            return false;
        }
    }

    return true;
}

