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
        << "  --min-threshold <value>     Minimum submit threshold, default 0.25\n"
        << "  --extranonce2 <hex>         Extranonce2 override, default 00000000\n"
        << "  --batchsize <n>             GPU batch size, 0 = auto\n"
        << "  --mem-per-job <bytes>       Auto batch memory estimate\n"
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
        } else {
            std::cerr << "[V20] Unknown or incomplete argument: " << a << "\n";
            print_usage(argv[0]);
            return false;
        }
    }

    return true;
}

