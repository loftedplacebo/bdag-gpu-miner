#pragma once

#include <cstdint>
#include <string>

struct Job {
    bool valid = false;
    uint64_t seq = 0;

    std::string job_id;
    std::string prevhash;
    std::string version;
    std::string bits;
    std::string ntime;
    std::string extranonce1;

    long double difficulty = 0.01L;
};
