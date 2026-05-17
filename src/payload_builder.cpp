#include "payload_builder.h"
#include "job.h"

#include <openssl/sha.h>

#include <cstdlib>
#include <cstring>
#include <iomanip>
#include <sstream>

std::vector<uint8_t> hex_to_bytes(const std::string &hex) {
    std::vector<uint8_t> out;
    out.reserve(hex.size() / 2);

    for (size_t i = 0; i + 1 < hex.size(); i += 2) {
        out.push_back((uint8_t)strtoul(hex.substr(i, 2).c_str(), nullptr, 16));
    }

    return out;
}

std::string bytes_to_hex(const uint8_t *data, size_t len) {
    std::ostringstream oss;
    oss << std::hex << std::setfill('0');

    for (size_t i = 0; i < len; i++) {
        oss << std::setw(2) << (int)data[i];
    }

    return oss.str();
}

std::vector<uint8_t> sha256d(const std::vector<uint8_t> &data) {
    uint8_t h1[SHA256_DIGEST_LENGTH];
    uint8_t h2[SHA256_DIGEST_LENGTH];

    SHA256(data.data(), data.size(), h1);
    SHA256(h1, SHA256_DIGEST_LENGTH, h2);

    return std::vector<uint8_t>(h2, h2 + SHA256_DIGEST_LENGTH);
}

bool make_payload80_from_job(
    const Job &j,
    const std::string &extranonce2_hex,
    uint8_t payload[80]
) {
    memset(payload, 0, 80);

    auto version = hex_to_bytes(j.version);
    auto prevhash = hex_to_bytes(j.prevhash.substr(0, 64));
    auto ntime = hex_to_bytes(j.ntime);
    auto bits = hex_to_bytes(j.bits);

    auto en1 = hex_to_bytes(j.extranonce1);
    auto en2 = hex_to_bytes(extranonce2_hex);

    std::vector<uint8_t> en;
    en.reserve(en1.size() + en2.size());
    en.insert(en.end(), en1.begin(), en1.end());
    en.insert(en.end(), en2.begin(), en2.end());

    auto merkle_like = sha256d(en);

    if (version.size() != 4 || prevhash.size() != 32 || merkle_like.size() != 32 || ntime.size() != 4 || bits.size() != 4) {
        return false;
    }

    memcpy(payload + 0, version.data(), 4);
    memcpy(payload + 4, prevhash.data(), 32);
    memcpy(payload + 36, merkle_like.data(), 32);
    memcpy(payload + 68, ntime.data(), 4);
    memcpy(payload + 72, bits.data(), 4);

    return true;
}
