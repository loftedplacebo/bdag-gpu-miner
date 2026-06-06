#include <arpa/inet.h>
#include <cuda_runtime.h>
#include <netdb.h>
#include <netinet/in.h>
#include <openssl/sha.h>
#include <sys/socket.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <csignal>
#include <cctype>
#include <ctime>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <mutex>
#include <random>
#include <regex>
#include <cstdlib>
#include <sstream>
#include <string>
#include <thread>
#include <unordered_set>
#include <vector>

#include "hasher.h"
#include "config.h"
#include "metrics.h"
#include "payload_builder.h"
#include "job.h"

// ========================
// Stage 18A config defaults
// ========================

static std::string POOL_HOST = "62.171.161.32";
static int POOL_PORT = 3334;
static std::string WALLET = "0xc12ee9dC15c3Fc7FCe8Ae2Ef8eD84e92c0B72310";
static std::string PASSWORD = "x";
static std::string WORKER_NAME = "";

static int RUNTIME_SECONDS = 60;
static long double SUBMIT_MARGIN = 1.02L;
static long double ACTIVE_SUBMIT_MARGIN = 1.02L;
static long double MIN_SUBMIT_THRESHOLD = 0.0L;
static std::string EXTRANONCE2_HEX = "00000000";

static int GPU_BATCHSIZE = 0;          // 0 = auto, v18 behaviour
static int GPU_MEM_PER_JOB = 800000;   // used only when batchsize is auto
static std::string KERNEL_MODE_NAME = "split";
static bool AUTO_THRESHOLD = true;

static int sockfd = -1;
static std::atomic<bool> running(false);
static std::atomic<bool> shutdown_requested(false);
static std::atomic<bool> connection_lost(false);

static void handle_shutdown_signal(int sig) {
    shutdown_requested = true;
    running = false;
    std::cerr << "\n[V20] shutdown signal received: " << sig << "\n";
    if (sockfd >= 0) {
        shutdown(sockfd, SHUT_RDWR);
    }
}


static std::atomic<uint64_t> total_checked(0);
static std::atomic<uint64_t> total_submitted(0);
static std::atomic<uint64_t> total_accepted(0);
static std::atomic<uint64_t> total_errors(0);
static std::atomic<uint64_t> total_lowdiff(0);
static std::atomic<uint64_t> total_stale_errors(0);
static std::atomic<uint64_t> total_stale_skipped(0);
static std::atomic<uint64_t> total_nohit_batches(0);
static std::atomic<uint64_t> total_hit_batches(0);
static std::atomic<uint64_t> total_gpu_candidates(0);
static std::atomic<uint64_t> total_multi_candidate_batches(0);
static std::atomic<uint64_t> max_candidates_in_batch(0);
static std::atomic<uint64_t> total_batch_us(0);
static std::atomic<uint64_t> timed_batches(0);
static std::atomic<uint64_t> max_batch_us(0);

static std::atomic<int> rpc_id_counter(1000);

static std::mutex job_mtx;
static Job current_job;
static std::string extranonce1_global;
static long double current_difficulty = 0.01L;

static std::mutex submit_mtx;
static std::unordered_set<int> pending_submit_ids;

static std::string lowercase(std::string s) {
    std::transform(s.begin(), s.end(), s.begin(), [](unsigned char c) {
        return (char)std::tolower(c);
    });
    return s;
}

static const char *kernel_mode_name(KernelMode mode) {
    return mode == KernelMode::Combo ? "combo" : "split";
}

static KernelMode kernel_mode_from_name(const std::string &mode) {
    return lowercase(mode) == "combo" ? KernelMode::Combo : KernelMode::Split;
}

static bool kernel_mode_is_auto(const std::string &mode) {
    return lowercase(mode) == "auto";
}

static std::vector<int> parse_batch_list(const std::string &text) {
    std::vector<int> batches;
    std::stringstream ss(text);
    std::string item;

    while (std::getline(ss, item, ',')) {
        int value = std::atoi(item.c_str());
        if (value >= 0) {
            batches.push_back(value);
        }
    }

    if (batches.empty()) {
        batches.push_back(0);
    }

    return batches;
}

static void update_max_atomic(std::atomic<uint64_t> &target, uint64_t value) {
    uint64_t prev = target.load();
    while (value > prev && !target.compare_exchange_weak(prev, value)) {
        // retry until max is updated
    }
}

static std::string json_escape(const std::string &s) {
    std::string out;
    out.reserve(s.size());
    for (char c : s) {
        if (c == '"' || c == '\\') out.push_back('\\');
        out.push_back(c);
    }
    return out;
}

static bool extract_json_string(const std::string &json, const std::string &key, std::string &out) {
    std::string needle = "\"" + key + "\"";
    size_t p = json.find(needle);
    if (p == std::string::npos) return false;
    p = json.find(':', p);
    if (p == std::string::npos) return false;
    p = json.find('"', p);
    if (p == std::string::npos) return false;
    size_t end = json.find('"', p + 1);
    if (end == std::string::npos) return false;
    out = json.substr(p + 1, end - p - 1);
    return true;
}

static bool extract_json_int(const std::string &json, const std::string &key, int &out) {
    std::string needle = "\"" + key + "\"";
    size_t p = json.find(needle);
    if (p == std::string::npos) return false;
    p = json.find(':', p);
    if (p == std::string::npos) return false;
    out = std::atoi(json.c_str() + p + 1);
    return true;
}

static bool extract_json_double(const std::string &json, const std::string &key, double &out) {
    std::string needle = "\"" + key + "\"";
    size_t p = json.find(needle);
    if (p == std::string::npos) return false;
    p = json.find(':', p);
    if (p == std::string::npos) return false;
    out = std::atof(json.c_str() + p + 1);
    return true;
}

static bool extract_json_bool(const std::string &json, const std::string &key, bool &out) {
    std::string needle = "\"" + key + "\"";
    size_t p = json.find(needle);
    if (p == std::string::npos) return false;
    p = json.find(':', p);
    if (p == std::string::npos) return false;

    const char *value = json.c_str() + p + 1;
    while (*value == ' ' || *value == '\t' || *value == '\r' || *value == '\n') value++;

    if (strncmp(value, "true", 4) == 0) {
        out = true;
        return true;
    }
    if (strncmp(value, "false", 5) == 0) {
        out = false;
        return true;
    }

    return false;
}

static std::string current_timestamp_utc() {
    std::time_t now = std::time(nullptr);
    std::tm tm_utc;
    gmtime_r(&now, &tm_utc);

    char buf[32];
    std::strftime(buf, sizeof(buf), "%Y-%m-%dT%H:%M:%SZ", &tm_utc);
    return std::string(buf);
}

static bool contains_batch_request(const std::vector<int> &batches, int requested_batchsize) {
    return std::find(batches.begin(), batches.end(), requested_batchsize) != batches.end();
}

static std::string gpu_cache_key(const MinerConfig &cfg) {
    int device = 0;
    cudaGetDevice(&device);

    cudaDeviceProp prop;
    memset(&prop, 0, sizeof(prop));
    cudaGetDeviceProperties(&prop, device);

    int driver_version = 0;
    int runtime_version = 0;
    cudaDriverGetVersion(&driver_version);
    cudaRuntimeGetVersion(&runtime_version);

    std::ostringstream oss;
    oss << "v20-autotune-v1"
        << "|gpu=" << prop.name
        << "|cc=" << prop.major << "." << prop.minor
        << "|mem=" << prop.totalGlobalMem
        << "|driver=" << driver_version
        << "|runtime=" << runtime_version
        << "|pool=" << cfg.pool_host << ":" << cfg.pool_port
        << "|margin=" << (double)cfg.submit_margin
        << "|min_threshold=" << (double)cfg.min_submit_threshold
        << "|mem_per_job=" << cfg.gpu_mem_per_job
        << "|batches=" << cfg.autotune_batches
        << "|mode=" << cfg.kernel_mode
        << "|autotune_seconds=" << cfg.autotune_seconds
        << "|min_trial_seconds=" << cfg.autotune_min_trial_seconds
        << "|min_trial_ratio=" << cfg.autotune_min_trial_ratio
        << "|target_ms=" << cfg.target_batch_ms
        << "|auto_threshold=" << (cfg.auto_threshold ? "1" : "0");
    return oss.str();
}

struct AutotuneSelection {
    int batchsize = 32768;
    int requested_batchsize = 32768;
    KernelMode mode = KernelMode::Split;
    bool from_cache = false;
    bool valid = false;
    double score = 0.0;
    double trial_elapsed_s = 0.0;
    int intended_trial_seconds = 0;
    int completed_candidates = 0;
};

struct AutotuneCandidateResult {
    int requested_batchsize = 0;
    int actual_batchsize = 0;
    KernelMode mode = KernelMode::Split;
    bool valid = false;
    bool disconnected = false;
    bool cuda_init_failed = false;
    double elapsed_s = 0.0;
    double required_s = 0.0;
    int intended_trial_seconds = 0;
    double mhs = 0.0;
    double avg_batch_ms = 0.0;
    uint64_t submitted = 0;
    uint64_t accepted = 0;
    uint64_t errors = 0;
    uint64_t lowdiff = 0;
    uint64_t stale = 0;
    double score = 0.0;
    std::string reason;
};

static AutotuneSelection safe_autotune_fallback() {
    AutotuneSelection selection;
    selection.batchsize = 32768;
    selection.requested_batchsize = 32768;
    selection.mode = KernelMode::Split;
    selection.valid = false;
    selection.score = 0.0;
    return selection;
}

static void print_autotune_fallback_warning() {
    std::cerr << "[AUTOTUNE_INVALID] no valid completed autotune result; falling back to safe defaults\n";
}

static bool load_autotune_cache(const MinerConfig &cfg, const std::string &key, AutotuneSelection &selection, std::string &reason) {
    std::ifstream in(cfg.autotune_cache);
    if (!in) {
        reason = "cache_missing";
        return false;
    }

    std::stringstream buffer;
    buffer << in.rdbuf();
    std::string json = buffer.str();

    bool valid = false;
    std::string cached_key;
    std::string cached_mode;
    int cached_batchsize = 0;
    int cached_requested_batchsize = 0;
    int cached_autotune_seconds = 0;
    int cached_completed_candidates = 0;
    int cached_intended_trial_seconds = 0;
    double cached_score = 0.0;
    double cached_trial_elapsed_s = 0.0;

    size_t valid_pos = json.find("\"valid\"");
    size_t tested_candidates_pos = json.find("\"tested_candidates\"");
    if (valid_pos == std::string::npos || (tested_candidates_pos != std::string::npos && valid_pos > tested_candidates_pos)) {
        reason = "cache_valid_missing";
        return false;
    }

    if (!extract_json_bool(json, "valid", valid) || !valid) {
        reason = "cache_valid_false_or_missing";
        return false;
    }
    if (!extract_json_string(json, "key", cached_key) || cached_key != key) {
        reason = "cache_key_mismatch";
        return false;
    }
    if (!extract_json_string(json, "selected_kernel_mode", cached_mode)) {
        reason = "cache_missing_selected_kernel_mode";
        return false;
    }
    if (!extract_json_int(json, "selected_batchsize", cached_batchsize)) {
        reason = "cache_missing_selected_batchsize";
        return false;
    }
    if (!extract_json_int(json, "selected_requested_batchsize", cached_requested_batchsize)) {
        reason = "cache_missing_selected_requested_batchsize";
        return false;
    }
    if (!extract_json_int(json, "autotune_seconds", cached_autotune_seconds) || cached_autotune_seconds < cfg.autotune_seconds) {
        reason = "cache_autotune_seconds_too_short";
        return false;
    }
    if (!extract_json_int(json, "completed_candidates", cached_completed_candidates) || cached_completed_candidates <= 0) {
        reason = "cache_no_completed_candidates";
        return false;
    }
    if (!extract_json_int(json, "selected_intended_trial_seconds", cached_intended_trial_seconds) || cached_intended_trial_seconds <= 0) {
        reason = "cache_missing_intended_trial_seconds";
        return false;
    }
    if (!extract_json_double(json, "selected_trial_elapsed_s", cached_trial_elapsed_s)) {
        reason = "cache_missing_trial_elapsed";
        return false;
    }

    std::vector<int> configured_batches = parse_batch_list(cfg.autotune_batches);
    if (!contains_batch_request(configured_batches, cached_requested_batchsize)) {
        reason = "cache_selected_batch_not_configured";
        return false;
    }

    double min_trial_ratio = std::max(0.0, std::min(1.0, cfg.autotune_min_trial_ratio));
    double required_s = std::min(
        (double)cached_intended_trial_seconds,
        std::max((double)std::max(0, cfg.autotune_min_trial_seconds), (double)cached_intended_trial_seconds * min_trial_ratio)
    );
    if (cached_trial_elapsed_s < required_s) {
        reason = "cache_selected_trial_too_short";
        return false;
    }
    if (cached_completed_candidates < 2 && cached_trial_elapsed_s < (double)cached_intended_trial_seconds * 0.98) {
        reason = "cache_not_enough_completed_candidates";
        return false;
    }

    extract_json_double(json, "score", cached_score);

    selection.batchsize = cached_batchsize;
    selection.requested_batchsize = cached_requested_batchsize;
    selection.mode = kernel_mode_from_name(cached_mode);
    selection.from_cache = true;
    selection.valid = true;
    selection.score = cached_score;
    selection.trial_elapsed_s = cached_trial_elapsed_s;
    selection.intended_trial_seconds = cached_intended_trial_seconds;
    selection.completed_candidates = cached_completed_candidates;
    return true;
}

static void write_candidate_json(std::ostream &out, const AutotuneCandidateResult &c, const std::string &indent) {
    out << indent << "{\n"
        << indent << "  \"requested_batchsize\": " << c.requested_batchsize << ",\n"
        << indent << "  \"actual_batchsize\": " << c.actual_batchsize << ",\n"
        << indent << "  \"kernel_mode\": \"" << kernel_mode_name(c.mode) << "\",\n"
        << indent << "  \"valid\": " << (c.valid ? "true" : "false") << ",\n"
        << indent << "  \"disconnected\": " << (c.disconnected ? "true" : "false") << ",\n"
        << indent << "  \"cuda_init_failed\": " << (c.cuda_init_failed ? "true" : "false") << ",\n"
        << indent << "  \"elapsed_s\": " << std::fixed << std::setprecision(3) << c.elapsed_s << ",\n"
        << indent << "  \"required_s\": " << std::fixed << std::setprecision(3) << c.required_s << ",\n"
        << indent << "  \"intended_trial_seconds\": " << c.intended_trial_seconds << ",\n"
        << indent << "  \"mhs\": " << std::fixed << std::setprecision(6) << c.mhs << ",\n"
        << indent << "  \"avg_batch_ms\": " << std::fixed << std::setprecision(3) << c.avg_batch_ms << ",\n"
        << indent << "  \"submitted\": " << c.submitted << ",\n"
        << indent << "  \"accepted\": " << c.accepted << ",\n"
        << indent << "  \"errors\": " << c.errors << ",\n"
        << indent << "  \"lowdiff\": " << c.lowdiff << ",\n"
        << indent << "  \"stale\": " << c.stale << ",\n"
        << indent << "  \"score\": " << std::fixed << std::setprecision(4) << c.score << ",\n"
        << indent << "  \"reason\": \"" << json_escape(c.reason) << "\"\n"
        << indent << "}";
}

static void save_autotune_cache(
    const MinerConfig &cfg,
    const std::string &key,
    const AutotuneSelection &selection,
    const std::vector<AutotuneCandidateResult> &tested_candidates
) {
    std::ofstream out(cfg.autotune_cache, std::ios::trunc);
    if (!out) {
        std::cerr << "[AUTOTUNE] warning: could not write cache " << cfg.autotune_cache << "\n";
        return;
    }

    out << "{\n"
        << "  \"version\": 1,\n"
        << "  \"valid\": true,\n"
        << "  \"completed_at\": \"" << current_timestamp_utc() << "\",\n"
        << "  \"key\": \"" << json_escape(key) << "\",\n"
        << "  \"autotune_seconds\": " << cfg.autotune_seconds << ",\n"
        << "  \"completed_candidates\": " << selection.completed_candidates << ",\n"
        << "  \"selected_batchsize\": " << selection.batchsize << ",\n"
        << "  \"selected_requested_batchsize\": " << selection.requested_batchsize << ",\n"
        << "  \"selected_kernel_mode\": \"" << kernel_mode_name(selection.mode) << "\",\n"
        << "  \"selected_trial_elapsed_s\": " << std::fixed << std::setprecision(3) << selection.trial_elapsed_s << ",\n"
        << "  \"selected_intended_trial_seconds\": " << selection.intended_trial_seconds << ",\n"
        << "  \"score\": " << std::fixed << std::setprecision(4) << selection.score << ",\n"
        << "  \"selected\": {\n"
        << "    \"batchsize\": " << selection.batchsize << ",\n"
        << "    \"requested_batchsize\": " << selection.requested_batchsize << ",\n"
        << "    \"kernel_mode\": \"" << kernel_mode_name(selection.mode) << "\",\n"
        << "    \"score\": " << std::fixed << std::setprecision(4) << selection.score << "\n"
        << "  },\n"
        << "  \"tested_candidates\": [\n";

    for (size_t i = 0; i < tested_candidates.size(); ++i) {
        write_candidate_json(out, tested_candidates[i], "    ");
        out << (i + 1 == tested_candidates.size() ? "\n" : ",\n");
    }

    out << "  ]\n"
        << "}\n";
}

static void save_failed_autotune_cache(
    const MinerConfig &cfg,
    const std::string &key,
    const std::vector<AutotuneCandidateResult> &tested_candidates,
    const std::string &reason
) {
    std::ofstream out(cfg.autotune_failed_cache, std::ios::trunc);
    if (!out) {
        std::cerr << "[AUTOTUNE] warning: could not write failed cache " << cfg.autotune_failed_cache << "\n";
        return;
    }

    out << "{\n"
        << "  \"version\": 1,\n"
        << "  \"valid\": false,\n"
        << "  \"completed_at\": \"" << current_timestamp_utc() << "\",\n"
        << "  \"key\": \"" << json_escape(key) << "\",\n"
        << "  \"autotune_seconds\": " << cfg.autotune_seconds << ",\n"
        << "  \"reason\": \"" << json_escape(reason) << "\",\n"
        << "  \"tested_candidates\": [\n";

    for (size_t i = 0; i < tested_candidates.size(); ++i) {
        write_candidate_json(out, tested_candidates[i], "    ");
        out << (i + 1 == tested_candidates.size() ? "\n" : ",\n");
    }

    out << "  ]\n"
        << "}\n";
}

static bool connect_tcp(const std::string &host, int port) {
    sockfd = socket(AF_INET, SOCK_STREAM, 0);

    if (sockfd < 0) {
        perror("socket");
        return false;
    }

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));

    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);

    if (inet_pton(AF_INET, host.c_str(), &addr.sin_addr) <= 0) {
        struct hostent *he = gethostbyname(host.c_str());
        if (!he) {
            std::cerr << "[STAGE18A] DNS failed for " << host << "\n";
            return false;
        }
        memcpy(&addr.sin_addr, he->h_addr_list[0], he->h_length);
    }

    if (connect(sockfd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("connect");
        return false;
    }

    return true;
}

static void send_line(const std::string &s) {
    std::string line = s + "\n";
    send(sockfd, line.c_str(), line.size(), 0);
}

static void subscribe_authorize() {
    send_line("{\"id\":1,\"method\":\"mining.subscribe\",\"params\":[]}");
    send_line("{\"id\":2,\"method\":\"mining.authorize\",\"params\":[\"" + WALLET + "\",\"" + PASSWORD + "\"]}");
}

static std::vector<std::string> quoted_strings_after_params(const std::string &line) {
    std::vector<std::string> out;

    size_t p = line.find("\"params\"");
    if (p == std::string::npos) return out;

    std::string tail = line.substr(p);

    std::regex r("\"([^\"]*)\"");
    auto begin = std::sregex_iterator(tail.begin(), tail.end(), r);
    auto end = std::sregex_iterator();

    for (auto it = begin; it != end; ++it) {
        std::string v = (*it)[1].str();

        if (v == "params") continue;
        out.push_back(v);
    }

    return out;
}

static int extract_response_id(const std::string &line) {
    std::regex id_re("\"id\"\\s*:\\s*([0-9]+)");
    std::smatch m;
    if (!std::regex_search(line, m, id_re)) {
        return -1;
    }
    return std::atoi(m[1].str().c_str());
}

static void parse_set_difficulty(const std::string &line) {
    std::regex r("\"mining\\.set_difficulty\".*?\\[([0-9\\.eE+-]+)\\]");
    std::smatch m;

    if (std::regex_search(line, m, r)) {
        long double d = strtold(m[1].str().c_str(), nullptr);

        {
            std::lock_guard<std::mutex> lk(job_mtx);
            current_difficulty = d;
            if (current_job.valid) {
                current_job.difficulty = d;
            }
        }

        std::cout << "[DIFF18A] " << std::fixed << std::setprecision(8) << (double)d << "\n";
    }
}

static void parse_subscribe_response(const std::string &line) {
    if (line.find("\"id\":1") == std::string::npos && line.find("\"id\": 1") == std::string::npos) {
        return;
    }

    std::regex r("\"([0-9a-fA-F]{8})\"\\s*,\\s*4");
    std::smatch m;

    if (std::regex_search(line, m, r)) {
        extranonce1_global = m[1].str();
        std::cout << "[SUBSCRIBE18A] extranonce1=" << extranonce1_global << "\n";
    }
}

static void parse_notify(const std::string &line) {
    if (line.find("mining.notify") == std::string::npos) return;

    std::vector<std::string> q = quoted_strings_after_params(line);

    // Expected strings:
    // q[0]=mining.notify may appear depending regex tail shape; remove it if present.
    std::vector<std::string> v;
    for (auto &s : q) {
        if (s == "mining.notify") continue;
        v.push_back(s);
    }

    if (v.size() < 5) {
        std::cerr << "[NOTIFY18A] could not parse notify line: " << line << "\n";
        return;
    }

    Job j;
    j.valid = true;

    {
        std::lock_guard<std::mutex> lk(job_mtx);
        j.seq = current_job.seq + 1;
        j.difficulty = current_difficulty;
    }

    j.job_id = v[0];
    j.prevhash = v[1];
    j.version = v[2];
    j.bits = v[3];
    j.ntime = v[4];
    j.extranonce1 = extranonce1_global;

    {
        std::lock_guard<std::mutex> lk(job_mtx);
        current_job = j;
    }

    std::cout << "\n[NEW JOB18A] id=" << j.job_id
              << " valid=true"
              << " diff=" << std::fixed << std::setprecision(8) << (double)j.difficulty
              << " prevhash=" << j.prevhash.substr(0, 16) << "..."
              << " version=" << j.version
              << " bits=" << j.bits
              << " ntime=" << j.ntime
              << " en1=" << j.extranonce1
              << "\n";
}

static void parse_pool_response(const std::string &line) {
    int response_id = extract_response_id(line);
    bool is_submit_response = false;

    if (response_id >= 0) {
        std::lock_guard<std::mutex> lk(submit_mtx);
        auto it = pending_submit_ids.find(response_id);
        if (it != pending_submit_ids.end()) {
            pending_submit_ids.erase(it);
            is_submit_response = true;
        }
    }

    bool has_result = line.find("\"result\"") != std::string::npos;
    bool result_true = has_result && line.find("true") != std::string::npos;
    bool result_false = has_result && line.find("false") != std::string::npos;
    bool has_error = line.find("\"error\"") != std::string::npos && line.find("null") == std::string::npos;

    if (is_submit_response && result_true) {
        total_accepted++;
        std::cout << "[ACCEPTED18A] id=" << response_id << " total=" << total_accepted.load() << "\n";
        return;
    }

    if (is_submit_response && (result_false || has_error)) {
        total_errors++;

        if (line.find("low difficulty") != std::string::npos) total_lowdiff++;
        if (line.find("stale") != std::string::npos) total_stale_errors++;

        std::cout << "[SHARE ERROR18A] id=" << response_id << " " << line << "\n";
        return;
    }

    if (response_id == 2 && result_true) {
        std::cout << "[AUTHORIZED18A] login accepted\n";
        return;
    }

    if (has_error) {
        std::cout << "[POOL ERROR18A] " << line << "\n";
    }
}

static bool wait_for_valid_job(int timeout_seconds);

static void recv_loop() {
    char buf[8192];
    std::string buffer;

    while (running.load()) {
        ssize_t n = recv(sockfd, buf, sizeof(buf) - 1, 0);

        if (n <= 0) {
            if (running.load() && !shutdown_requested.load()) {
                std::cerr << "[RECV18A] disconnected or recv error\n";
                connection_lost = true;
                running = false;
            }
            break;
        }

        buf[n] = 0;
        buffer += buf;

        size_t pos;

        while ((pos = buffer.find('\n')) != std::string::npos) {
            std::string line = buffer.substr(0, pos);
            buffer.erase(0, pos + 1);

            if (line.empty()) continue;

            parse_subscribe_response(line);
            parse_set_difficulty(line);
            parse_notify(line);
            parse_pool_response(line);
        }
    }
}

static void reset_pool_state() {
    {
        std::lock_guard<std::mutex> lk(job_mtx);
        current_job = Job();
        extranonce1_global.clear();
        current_difficulty = 0.01L;
    }

    {
        std::lock_guard<std::mutex> lk(submit_mtx);
        pending_submit_ids.clear();
    }
}

static bool reconnect_stratum(std::thread &rx, int job_timeout_seconds) {
    if (sockfd >= 0) {
        shutdown(sockfd, SHUT_RDWR);
        close(sockfd);
        sockfd = -1;
    }

    running = false;

    if (rx.joinable()) {
        rx.join();
    }

    reset_pool_state();
    connection_lost = false;

    if (!connect_tcp(POOL_HOST, POOL_PORT)) {
        std::cerr << "[AUTOTUNE] reconnect failed\n";
        running = false;
        return false;
    }

    running = true;
    subscribe_authorize();
    rx = std::thread(recv_loop);

    if (!wait_for_valid_job(job_timeout_seconds)) {
        std::cerr << "[AUTOTUNE] reconnect did not receive a valid job\n";
        running = false;
        return false;
    }

    return true;
}

static void make_kepler_target_from_threshold(long double threshold, uint32_t target[8]) {
    for (int i = 0; i < 8; i++) target[i] = 0;

    if (threshold < 0.000001L) threshold = 0.000001L;

    // Matches the working Stage 14/15 threshold family:
    // threshold 1.0  -> top chunk approx 0000ffff
    // threshold 0.25 -> top chunk approx 0003fffc
    long double coeff_ld = 65535.0L / threshold;

    if (coeff_ld < 1.0L) coeff_ld = 1.0L;
    if (coeff_ld > 4294967295.0L) coeff_ld = 4294967295.0L;

    uint32_t coeff = (uint32_t)coeff_ld;

    // Keplerminer compares j=7 down to 0, so the leading target chunk goes into target[7].
    target[7] = coeff;
}

static std::string nonce_word_to_submit_hex(uint32_t nonce_word) {
    uint8_t b[4];
    memcpy(b, &nonce_word, 4);
    return bytes_to_hex(b, 4);
}

static void submit_nonce(const Job &j, uint32_t nonce_word) {
    std::string nonce_hex = nonce_word_to_submit_hex(nonce_word);
    int id = rpc_id_counter++;

    {
        std::lock_guard<std::mutex> lk(submit_mtx);
        pending_submit_ids.insert(id);
    }

    std::ostringstream oss;
    oss << "{\"id\":" << id
        << ",\"method\":\"mining.submit\",\"params\":[\""
        << WALLET << "\",\""
        << j.job_id << "\",\""
        << EXTRANONCE2_HEX << "\",\""
        << j.ntime << "\",\""
        << nonce_hex << "\"]}";

    send_line(oss.str());
    total_submitted++;
}

static bool wait_for_valid_job(int timeout_seconds) {
    for (int i = 0; i < timeout_seconds * 20 && running.load(); ++i) {
        {
            std::lock_guard<std::mutex> lk(job_mtx);
            if (current_job.valid) {
                return true;
            }
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }

    return false;
}

static void update_adaptive_submit_margin() {
    if (!AUTO_THRESHOLD) return;

    static uint64_t last_lowdiff_seen = 0;
    uint64_t lowdiff = total_lowdiff.load();
    bool changed = false;

    while (lowdiff > last_lowdiff_seen) {
        ACTIVE_SUBMIT_MARGIN *= 1.05L;
        if (ACTIVE_SUBMIT_MARGIN > 8.0L) {
            ACTIVE_SUBMIT_MARGIN = 8.0L;
        }
        last_lowdiff_seen++;
        changed = true;
    }

    if (changed) {
        std::cout << "[AUTO_THRESHOLD] lowdiff=" << lowdiff
                  << " active_margin=" << std::fixed << std::setprecision(4)
                  << (double)ACTIVE_SUBMIT_MARGIN << "\n";
    }
}

struct BatchRunStats {
    bool attempted = false;
    bool had_candidates = false;
    uint64_t candidates = 0;
    double batch_ms = 0.0;
    ScanTimings timings;
};

static BatchRunStats run_one_mining_batch(
    CudaHasher &hasher,
    uint32_t &start_nonce_word,
    bool collect_stage_timing
) {
    BatchRunStats stats;
    int batchsize = hasher.GetBatchSize();

    Job j;
    {
        std::lock_guard<std::mutex> lk(job_mtx);
        j = current_job;
    }

    if (!j.valid) {
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
        return stats;
    }

    uint8_t payload[80];
    if (!make_payload80_from_job(j, EXTRANONCE2_HEX, payload)) {
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
        return stats;
    }

    uint32_t pdata[20];
    memcpy(pdata, payload, 80);
    pdata[19] = start_nonce_word;

    update_adaptive_submit_margin();

    long double threshold = j.difficulty * ACTIVE_SUBMIT_MARGIN;
    if (threshold < MIN_SUBMIT_THRESHOLD) threshold = MIN_SUBMIT_THRESHOLD;

    uint32_t target[8];
    make_kepler_target_from_threshold(threshold, target);

    int stop = 0;
    unsigned long hashes_done = 0;
    std::vector<uint32_t> candidate_offsets;
    ScanTimings timings;
    ScanTimings *timing_ptr = collect_stage_timing ? &timings : nullptr;

    auto batch_start = std::chrono::steady_clock::now();
    int rc = hasher.ScanNCoins(pdata, target, batchsize, &stop, &hashes_done, &candidate_offsets, timing_ptr);
    (void)rc;
    auto batch_end = std::chrono::steady_clock::now();

    stats.attempted = true;
    stats.batch_ms = std::chrono::duration<double, std::milli>(batch_end - batch_start).count();
    if (collect_stage_timing) {
        stats.timings = timings;
    }

    uint64_t batch_us = (uint64_t)(stats.batch_ms * 1000.0);
    total_batch_us += batch_us;
    timed_batches++;
    update_max_atomic(max_batch_us, batch_us);

    total_checked += batchsize;

    Job latest;
    {
        std::lock_guard<std::mutex> lk(job_mtx);
        latest = current_job;
    }

    if (!candidate_offsets.empty()) {
        stats.had_candidates = true;
        stats.candidates = candidate_offsets.size();
        total_hit_batches++;

        uint64_t cand_count = candidate_offsets.size();
        total_gpu_candidates += cand_count;
        if (cand_count > 1) {
            total_multi_candidate_batches++;
        }

        update_max_atomic(max_candidates_in_batch, cand_count);

        bool stale_batch = (!latest.valid || latest.seq != j.seq || latest.job_id != j.job_id);

        if (stale_batch) {
            total_stale_skipped += cand_count;
        } else {
            for (uint32_t off : candidate_offsets) {
                uint32_t found_nonce_word = start_nonce_word + off;
                submit_nonce(j, found_nonce_word);
            }
        }
    } else {
        total_nohit_batches++;
    }

    start_nonce_word += (uint32_t)batchsize;
    return stats;
}

struct MetricSnapshot {
    uint64_t checked = 0;
    uint64_t submitted = 0;
    uint64_t accepted = 0;
    uint64_t errors = 0;
    uint64_t lowdiff = 0;
    uint64_t stale_errors = 0;
    uint64_t stale_skipped = 0;
    uint64_t batch_us = 0;
    uint64_t timed_batches = 0;
};

static MetricSnapshot snapshot_metrics() {
    MetricSnapshot s;
    s.checked = total_checked.load();
    s.submitted = total_submitted.load();
    s.accepted = total_accepted.load();
    s.errors = total_errors.load();
    s.lowdiff = total_lowdiff.load();
    s.stale_errors = total_stale_errors.load();
    s.stale_skipped = total_stale_skipped.load();
    s.batch_us = total_batch_us.load();
    s.timed_batches = timed_batches.load();
    return s;
}

static AutotuneSelection run_launch_autotune(
    const MinerConfig &cfg,
    uint32_t &start_nonce_word,
    std::thread &rx
) {
    AutotuneSelection selection = safe_autotune_fallback();
    std::vector<AutotuneCandidateResult> tested_candidates;
    std::string cache_key = gpu_cache_key(cfg);

    if (cfg.autotune && !cfg.autotune_force) {
        std::string cache_reason;
        if (load_autotune_cache(cfg, cache_key, selection, cache_reason)) {
            std::cout << "[AUTOTUNE] using cached batchsize=" << selection.batchsize
                      << " requested_batchsize=" << selection.requested_batchsize
                      << " kernel_mode=" << kernel_mode_name(selection.mode)
                      << " score=" << std::fixed << std::setprecision(2) << selection.score
                      << "\n";
            return selection;
        }
        if (cache_reason != "cache_missing") {
            std::cout << "[AUTOTUNE_INVALID] ignoring cache: " << cache_reason << "\n";
        }
    }

    if (!cfg.autotune || cfg.autotune_seconds <= 0) {
        selection.batchsize = cfg.gpu_batchsize;
        selection.requested_batchsize = cfg.gpu_batchsize;
        selection.mode = kernel_mode_from_name(cfg.kernel_mode);
        selection.valid = true;
        std::cout << "[AUTOTUNE] disabled; batchsize=" << selection.batchsize
                  << " kernel_mode=" << kernel_mode_name(selection.mode) << "\n";
        return selection;
    }

    if (!wait_for_valid_job(30)) {
        if (shutdown_requested.load() || !reconnect_stratum(rx, 30)) {
            print_autotune_fallback_warning();
            save_failed_autotune_cache(cfg, cache_key, tested_candidates, "no_valid_job");
            return safe_autotune_fallback();
        }
    }

    std::vector<int> batch_candidates = parse_batch_list(cfg.autotune_batches);
    std::vector<KernelMode> mode_candidates;

    if (kernel_mode_is_auto(cfg.kernel_mode)) {
        mode_candidates.push_back(KernelMode::Split);
        mode_candidates.push_back(KernelMode::Combo);
    } else {
        mode_candidates.push_back(kernel_mode_from_name(cfg.kernel_mode));
    }

    int combo_count = (int)(batch_candidates.size() * mode_candidates.size());
    if (combo_count <= 0) {
        print_autotune_fallback_warning();
        save_failed_autotune_cache(cfg, cache_key, tested_candidates, "no_configured_candidates");
        return safe_autotune_fallback();
    }

    int tune_seconds = cfg.autotune_seconds;
    if (RUNTIME_SECONDS > 0) {
        int runtime_budget = std::max(0, RUNTIME_SECONDS / 3);
        tune_seconds = std::min(tune_seconds, runtime_budget);
    }

    if (tune_seconds <= 0) {
        print_autotune_fallback_warning();
        save_failed_autotune_cache(cfg, cache_key, tested_candidates, "runtime_too_short");
        return safe_autotune_fallback();
    }

    int per_trial_seconds = std::max(5, tune_seconds / combo_count);
    double min_trial_ratio = std::max(0.0, std::min(1.0, cfg.autotune_min_trial_ratio));
    double required_trial_seconds = std::min(
        (double)per_trial_seconds,
        std::max((double)std::max(0, cfg.autotune_min_trial_seconds), (double)per_trial_seconds * min_trial_ratio)
    );

    std::cout << "[AUTOTUNE] starting combos=" << combo_count
              << " total_budget_s=" << tune_seconds
              << " per_trial_s=" << per_trial_seconds
              << " required_trial_s=" << std::fixed << std::setprecision(1) << required_trial_seconds
              << " target_batch_ms=" << std::fixed << std::setprecision(1) << cfg.target_batch_ms
              << "\n";

    int completed_candidates = 0;
    bool single_candidate_full = false;
    const int max_attempts_per_candidate = 2;

    for (int requested_batch : batch_candidates) {
        for (KernelMode mode : mode_candidates) {
            if (shutdown_requested.load()) break;

            bool candidate_completed = false;

            for (int attempt = 1; attempt <= max_attempts_per_candidate && !candidate_completed; ++attempt) {
                if (shutdown_requested.load()) break;

                AutotuneCandidateResult result;
                result.requested_batchsize = requested_batch;
                result.mode = mode;
                result.required_s = required_trial_seconds;
                result.intended_trial_seconds = per_trial_seconds;

                if (!running.load() || connection_lost.load()) {
                    if (!reconnect_stratum(rx, 30)) {
                        result.disconnected = true;
                        result.reason = "reconnect_failed_before_trial";
                        tested_candidates.push_back(result);
                        continue;
                    }
                }

                connection_lost = false;

                CudaHasher trial_hasher(requested_batch, cfg.gpu_mem_per_job, mode);
                if (trial_hasher.Initialize() != 0) {
                    result.cuda_init_failed = true;
                    result.reason = "cuda_init_failed";
                    tested_candidates.push_back(result);
                    std::cerr << "[AUTOTUNE] skip batchsize=" << requested_batch
                              << " kernel_mode=" << kernel_mode_name(mode)
                              << " because CUDA init failed\n";
                    break;
                }

                int actual_batchsize = trial_hasher.GetBatchSize();
                result.actual_batchsize = actual_batchsize;
                std::cout << "[AUTOTUNE] trial batchsize=" << actual_batchsize
                          << " requested=" << requested_batch
                          << " kernel_mode=" << kernel_mode_name(mode)
                          << " attempt=" << attempt
                          << "\n";

                MetricSnapshot before = snapshot_metrics();
                auto trial_start = std::chrono::steady_clock::now();

                while (running.load() && !connection_lost.load() && !shutdown_requested.load()) {
                    auto now = std::chrono::steady_clock::now();
                    double elapsed = std::chrono::duration<double>(now - trial_start).count();
                    if (elapsed >= per_trial_seconds) break;

                    BatchRunStats batch_stats = run_one_mining_batch(trial_hasher, start_nonce_word, true);
                    if (!batch_stats.attempted) {
                        std::this_thread::sleep_for(std::chrono::milliseconds(50));
                    }
                }

                std::this_thread::sleep_for(std::chrono::milliseconds(750));

                auto trial_end = std::chrono::steady_clock::now();
                double elapsed = std::chrono::duration<double>(trial_end - trial_start).count();
                MetricSnapshot after = snapshot_metrics();

                uint64_t checked_delta = after.checked - before.checked;
                uint64_t submitted_delta = after.submitted - before.submitted;
                uint64_t accepted_delta = after.accepted - before.accepted;
                uint64_t errors_delta = after.errors - before.errors;
                uint64_t lowdiff_delta = after.lowdiff - before.lowdiff;
                uint64_t stale_delta = (after.stale_errors - before.stale_errors) + (after.stale_skipped - before.stale_skipped);
                uint64_t timed_delta = after.timed_batches - before.timed_batches;
                uint64_t batch_us_delta = after.batch_us - before.batch_us;

                bool disconnected = connection_lost.load() || (!running.load() && !shutdown_requested.load());
                double hps = elapsed > 0.0 ? (double)checked_delta / elapsed : 0.0;
                double accepted_rate = submitted_delta > 0 ? (double)accepted_delta / (double)submitted_delta : 1.0;
                double error_rate = submitted_delta > 0 ? (double)errors_delta / (double)submitted_delta : 0.0;
                double lowdiff_rate = submitted_delta > 0 ? (double)lowdiff_delta / (double)submitted_delta : 0.0;
                double stale_rate = submitted_delta > 0 ? (double)stale_delta / (double)submitted_delta : 0.0;
                double avg_batch_ms = timed_delta > 0 ? ((double)batch_us_delta / (double)timed_delta) / 1000.0 : 0.0;

                double accepted_factor = submitted_delta > 0 ? std::max(0.15, accepted_rate) : 0.85;
                double error_factor = 1.0 - std::min(0.75, error_rate);
                double lowdiff_factor = 1.0 - std::min(0.75, lowdiff_rate);
                double stale_factor = 1.0 - std::min(0.75, stale_rate);
                double latency_factor = (avg_batch_ms <= 0.0 || avg_batch_ms <= cfg.target_batch_ms)
                    ? 1.0
                    : std::max(0.25, cfg.target_batch_ms / avg_batch_ms);

                double score = hps * accepted_factor * error_factor * lowdiff_factor * stale_factor * latency_factor;

                result.disconnected = disconnected;
                result.elapsed_s = elapsed;
                result.mhs = hps / 1000000.0;
                result.avg_batch_ms = avg_batch_ms;
                result.submitted = submitted_delta;
                result.accepted = accepted_delta;
                result.errors = errors_delta;
                result.lowdiff = lowdiff_delta;
                result.stale = stale_delta;
                result.score = score;

                if (disconnected) {
                    result.valid = false;
                    result.reason = "disconnected";
                } else if (elapsed < required_trial_seconds) {
                    result.valid = false;
                    result.reason = "trial_too_short";
                } else if (checked_delta == 0 || timed_delta == 0) {
                    result.valid = false;
                    result.reason = "no_work_completed";
                } else {
                    result.valid = true;
                    result.reason = "completed";
                    candidate_completed = true;
                    completed_candidates++;
                    if (combo_count == 1 && elapsed >= (double)per_trial_seconds * 0.98) {
                        single_candidate_full = true;
                    }

                    if (!selection.valid || score > selection.score) {
                        selection.batchsize = actual_batchsize;
                        selection.requested_batchsize = requested_batch;
                        selection.mode = mode;
                        selection.from_cache = false;
                        selection.valid = true;
                        selection.score = score;
                        selection.trial_elapsed_s = elapsed;
                        selection.intended_trial_seconds = per_trial_seconds;
                    }
                }

                tested_candidates.push_back(result);

                std::cout << "[AUTOTUNE_RESULT]"
                          << " batchsize=" << actual_batchsize
                          << " requested=" << requested_batch
                          << " kernel_mode=" << kernel_mode_name(mode)
                          << " attempt=" << attempt
                          << " valid=" << (result.valid ? "true" : "false")
                          << " reason=" << result.reason
                          << " elapsed_s=" << std::fixed << std::setprecision(1) << elapsed
                          << " required_s=" << std::setprecision(1) << required_trial_seconds
                          << " mhs=" << std::setprecision(4) << result.mhs
                          << " avg_batch_ms=" << std::setprecision(2) << avg_batch_ms
                          << " submitted=" << submitted_delta
                          << " accepted=" << accepted_delta
                          << " errors=" << errors_delta
                          << " lowdiff=" << lowdiff_delta
                          << " stale=" << stale_delta
                          << " score=" << std::setprecision(2) << score
                          << "\n";

                if (disconnected && attempt < max_attempts_per_candidate) {
                    std::cout << "[AUTOTUNE] reconnecting after disconnect; retrying candidate\n";
                    if (!reconnect_stratum(rx, 30)) {
                        break;
                    }
                }
            }
        }
    }

    bool enough_completed = completed_candidates >= 2 || single_candidate_full;
    if (selection.valid && enough_completed) {
        selection.completed_candidates = completed_candidates;
        std::cout << "[AUTOTUNE] selected batchsize=" << selection.batchsize
                  << " requested_batchsize=" << selection.requested_batchsize
                  << " kernel_mode=" << kernel_mode_name(selection.mode)
                  << " completed_candidates=" << completed_candidates
                  << " score=" << std::fixed << std::setprecision(2) << selection.score
                  << "\n";
        save_autotune_cache(cfg, cache_key, selection, tested_candidates);
        return selection;
    }

    std::string reason = selection.valid ? "not_enough_completed_candidates" : "no_valid_completed_candidate";
    print_autotune_fallback_warning();
    save_failed_autotune_cache(cfg, cache_key, tested_candidates, reason);

    if (!running.load() && !shutdown_requested.load()) {
        reconnect_stratum(rx, 30);
    }

    return safe_autotune_fallback();
}

int main(int argc, char **argv) {
    std::signal(SIGINT, handle_shutdown_signal);
    std::signal(SIGTERM, handle_shutdown_signal);

    MinerConfig cfg;
    if (!parse_args(argc, argv, cfg)) {
        return 1;
    }

    POOL_HOST = cfg.pool_host;
    POOL_PORT = cfg.pool_port;
    WALLET = cfg.wallet;
    PASSWORD = cfg.password;
    WORKER_NAME = cfg.worker_name.empty() ? cfg.wallet : cfg.worker_name;
    RUNTIME_SECONDS = cfg.runtime_seconds;
    SUBMIT_MARGIN = cfg.submit_margin;
    ACTIVE_SUBMIT_MARGIN = cfg.submit_margin;
    MIN_SUBMIT_THRESHOLD = cfg.min_submit_threshold;
    EXTRANONCE2_HEX = cfg.extranonce2_hex;
    GPU_BATCHSIZE = cfg.gpu_batchsize;
    GPU_MEM_PER_JOB = cfg.gpu_mem_per_job;
    KERNEL_MODE_NAME = cfg.kernel_mode;
    AUTO_THRESHOLD = cfg.auto_threshold;

    if (!is_valid_wallet(WALLET) || WALLET == "0x0000000000000000000000000000000000000000") {
        std::cerr << "[FINAL18A] FAIL invalid wallet. Use a non-placeholder 42-character EVM address beginning with 0x.\n";
        return 1;
    }

    std::cout << "[STAGE18A] Keplerminer BDAG live miner\n";
    std::cout << "[STAGE18A] pool=" << POOL_HOST << ":" << POOL_PORT << "\n";
    std::cout << "[STAGE18A] wallet=" << WALLET << "\n";
    std::cout << "[STAGE18A] worker_name=" << WORKER_NAME << "\n";
    std::cout << "[STAGE18A] runtime=" << RUNTIME_SECONDS << "s\n";
    std::cout << "[STAGE18A] margin=" << std::fixed << std::setprecision(4) << (double)SUBMIT_MARGIN << "\n";
    std::cout << "[STAGE18A] min_threshold=" << std::fixed << std::setprecision(4) << (double)MIN_SUBMIT_THRESHOLD << "\n";
    std::cout << "[V19] gpu_batchsize_request=" << GPU_BATCHSIZE << "\n";
    std::cout << "[V19] gpu_mem_per_job=" << GPU_MEM_PER_JOB << "\n";
    std::cout << "[V20] kernel_mode=" << KERNEL_MODE_NAME << "\n";
    std::cout << "[V20] autotune=" << (cfg.autotune ? "on" : "off")
              << " autotune_seconds=" << cfg.autotune_seconds
              << " autotune_batches=" << cfg.autotune_batches
              << " target_batch_ms=" << std::fixed << std::setprecision(1) << cfg.target_batch_ms
              << "\n";
    std::cout << "[V20] auto_threshold=" << (AUTO_THRESHOLD ? "on" : "off") << "\n";

    if (!connect_tcp(POOL_HOST, POOL_PORT)) {
        std::cerr << "[FINAL18A] FAIL pool connect failed\n";
        return 1;
    }

    running = true;

    subscribe_authorize();

    std::thread rx(recv_loop);

    std::mt19937 rng((uint32_t)time(nullptr));
    uint32_t start_nonce_word = rng();

    auto start_time = std::chrono::steady_clock::now();
    auto last_print = start_time;

    AutotuneSelection tuning = run_launch_autotune(cfg, start_nonce_word, rx);

    CudaHasher *hasher = new CudaHasher(tuning.batchsize, GPU_MEM_PER_JOB, tuning.mode);

    if (hasher->Initialize() != 0) {
        std::cerr << "[FINAL18A] FAIL Keplerminer CudaHasher initialisation failed\n";
        delete hasher;
        running = false;
        if (sockfd >= 0) {
            shutdown(sockfd, SHUT_RDWR);
            close(sockfd);
            sockfd = -1;
        }
        if (rx.joinable()) rx.join();
        return 1;
    }

    int batchsize = hasher->GetBatchSize();
    KernelMode active_kernel_mode = hasher->GetKernelMode();
    std::cout << "[STAGE18A] kepler_batchsize=" << batchsize
              << " kernel_mode=" << kernel_mode_name(active_kernel_mode)
              << (tuning.from_cache ? " source=cache" : " source=runtime")
              << "\n";

    while (running.load()) {
        auto now = std::chrono::steady_clock::now();
        double elapsed_total = std::chrono::duration<double>(now - start_time).count();

        if (RUNTIME_SECONDS > 0 && elapsed_total >= RUNTIME_SECONDS) {
            running = false;
            break;
        }

        BatchRunStats batch_stats = run_one_mining_batch(*hasher, start_nonce_word, false);
        if (!batch_stats.attempted) continue;

        auto now2 = std::chrono::steady_clock::now();
        double since_print = std::chrono::duration<double>(now2 - last_print).count();

        if (since_print >= 10.0) {
            double elapsed = std::chrono::duration<double>(now2 - start_time).count();
            double hps = (double)total_checked.load() / elapsed;
            uint64_t batches = timed_batches.load();
            double avg_batch_ms = batches > 0 ? ((double)total_batch_us.load() / (double)batches) / 1000.0 : 0.0;
            double max_batch_ms = (double)max_batch_us.load() / 1000.0;

            Job log_job;
            {
                std::lock_guard<std::mutex> lk(job_mtx);
                log_job = current_job;
            }

            long double threshold = log_job.difficulty * ACTIVE_SUBMIT_MARGIN;
            if (threshold < MIN_SUBMIT_THRESHOLD) threshold = MIN_SUBMIT_THRESHOLD;

            std::cout << "[LIVE18A] checked=" << total_checked.load()
                      << " avg=" << std::fixed << std::setprecision(1) << hps << " H/s"
                      << " batches=" << batches
                      << " batch_ms_avg=" << std::setprecision(2) << avg_batch_ms
                      << " batch_ms_max=" << std::setprecision(2) << max_batch_ms
                      << " kernel_mode=" << kernel_mode_name(active_kernel_mode)
                      << " hit_batches=" << total_hit_batches.load()
                      << " nohit_batches=" << total_nohit_batches.load()
                      << " gpu_candidates=" << total_gpu_candidates.load()
                      << " multi_candidate_batches=" << total_multi_candidate_batches.load()
                      << " max_candidates_in_batch=" << max_candidates_in_batch.load()
                      << " submitted=" << total_submitted.load()
                      << " accepted=" << total_accepted.load()
                      << " errors=" << total_errors.load()
                      << " low=" << total_lowdiff.load()
                      << " stale_err=" << total_stale_errors.load()
                      << " stale_skipped=" << total_stale_skipped.load()
                      << " current_diff=" << std::setprecision(8) << (double)log_job.difficulty
                      << " threshold=" << std::setprecision(8) << (double)threshold
                      << " active_margin=" << std::setprecision(4) << (double)ACTIVE_SUBMIT_MARGIN
                      << "\n";

            last_print = now2;
        }
    }

    running = false;

    if (sockfd >= 0) {
        shutdown(sockfd, SHUT_RDWR);
        close(sockfd);
        sockfd = -1;
    }

    if (rx.joinable()) rx.join();

    auto end_time = std::chrono::steady_clock::now();
    double elapsed = std::chrono::duration<double>(end_time - start_time).count();
    double hps = elapsed > 0 ? (double)total_checked.load() / elapsed : 0.0;
    uint64_t batches = timed_batches.load();
    double avg_batch_ms = batches > 0 ? ((double)total_batch_us.load() / (double)batches) / 1000.0 : 0.0;
    double max_batch_ms = (double)max_batch_us.load() / 1000.0;

    std::cout << "[FINAL18A] checked=" << total_checked.load()
              << " elapsed=" << std::fixed << std::setprecision(1) << elapsed << "s"
              << " avg=" << std::setprecision(1) << hps << " H/s"
              << " batches=" << batches
              << " batch_ms_avg=" << std::setprecision(2) << avg_batch_ms
              << " batch_ms_max=" << std::setprecision(2) << max_batch_ms
              << " kernel_mode=" << kernel_mode_name(active_kernel_mode)
              << " hit_batches=" << total_hit_batches.load()
              << " nohit_batches=" << total_nohit_batches.load()
              << " gpu_candidates=" << total_gpu_candidates.load()
              << " multi_candidate_batches=" << total_multi_candidate_batches.load()
              << " max_candidates_in_batch=" << max_candidates_in_batch.load()
              << " submitted=" << total_submitted.load()
              << " accepted=" << total_accepted.load()
              << " errors=" << total_errors.load()
              << " low=" << total_lowdiff.load()
              << " stale_err=" << total_stale_errors.load()
              << " stale_skipped=" << total_stale_skipped.load()
              << "\n";

    delete hasher;


    MinerMetrics final_metrics;
    final_metrics.checked.store(total_checked.load());
    final_metrics.submitted.store(total_submitted.load());
    final_metrics.accepted.store(total_accepted.load());
    final_metrics.errors.store(total_errors.load());
    final_metrics.lowdiff.store(total_lowdiff.load());
    final_metrics.stale_errors.store(total_stale_errors.load());
    final_metrics.stale_skipped.store(total_stale_skipped.load());
    final_metrics.nohit_batches.store(total_nohit_batches.load());
    final_metrics.hit_batches.store(total_hit_batches.load());
    final_metrics.batch_us.store(total_batch_us.load());
    final_metrics.timed_batches.store(timed_batches.load());
    final_metrics.max_batch_us.store(max_batch_us.load());

    std::cout << format_v20_result(final_metrics, elapsed, batchsize, batches) << "\n";

    std::cout << "[FINAL18A] Done\n";
    return 0;
}

