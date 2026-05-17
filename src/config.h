#pragma once

#include <string>

struct MinerConfig {
    std::string pool_host = "62.171.161.32";
    int pool_port = 3334;

    std::string wallet = "0xc12ee9dC15c3Fc7FCe8Ae2Ef8eD84e92c0B72310";
    std::string password = "x";
    std::string worker_name = "";          // optional label, defaults to wallet in run.sh

    int runtime_seconds = 60;          // 0 = run forever
    long double submit_margin = 1.02L;
    long double min_submit_threshold = 0.25L;
    std::string extranonce2_hex = "00000000";

    int gpu_batchsize = 0;             // 0 = auto
    int gpu_mem_per_job = 800000;      // used only when batchsize is auto
};

void print_usage(const char *argv0);
bool parse_args(int argc, char **argv, MinerConfig &cfg);
bool is_valid_wallet(const std::string &wallet);

