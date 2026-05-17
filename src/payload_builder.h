#pragma once

#include <cstdint>
#include <string>
#include <vector>

struct Job;

std::vector<uint8_t> hex_to_bytes(const std::string &hex);
std::string bytes_to_hex(const uint8_t *data, size_t len);
std::vector<uint8_t> sha256d(const std::vector<uint8_t> &data);

bool make_payload80_from_job(
    const Job &j,
    const std::string &extranonce2_hex,
    uint8_t payload[80]
);
