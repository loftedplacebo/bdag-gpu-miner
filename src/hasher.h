/* Copyright (C) 2013 David G. Andersen.  All rights reserved.
 *
 * Use of this code is covered under the Apache 2.0 license, which
 * can be found in the file "LICENSE"
 */

#ifndef _CUDAHASHER_H_
#define _CUDAHASHER_H_

#include <stdio.h>
#include <stdlib.h>
#include <inttypes.h>
#include <string>
#include <vector>

enum class KernelMode {
  Split,
  Combo
};

struct ScanTimings {
  double total_ms = 0.0;
  double output_clear_ms = 0.0;
  double start_kernel_ms = 0.0;
  double gen_kernel_ms = 0.0;
  double hash_kernel_ms = 0.0;
  double combo_kernel_ms = 0.0;
  double finish_kernel_ms = 0.0;
  double output_copy_ms = 0.0;
};

struct scrypt_hash {
  uint32_t b[16];
  uint32_t bx[16];
} __attribute__((packed));

typedef struct {
  uint32_t data[20];
  uint32_t target[8];
  uint32_t initial_midstate[8];
} scan_job;

class CudaHasher {
public:
  CudaHasher(int requested_batchsize = 0, int mem_per_job_override = 800000, KernelMode kernel_mode = KernelMode::Split);
  int Initialize();
  int ComputeHashes(const scrypt_hash *in, scrypt_hash *out, int n_hashes);
  ~CudaHasher();

  int ScanNCoins(uint32_t *pdata, const uint32_t *ptarget, int n, volatile int *stop, unsigned long *hashes_done, std::vector<uint32_t> *candidate_offsets = nullptr, ScanTimings *timings = nullptr);

  int HashOneForDebug(uint32_t *pdata, uint32_t nonce, uint32_t *out_hash8);

  int TestLoadStore();

  int GetBatchSize() const { return batchsize; }
  int GetMemPerJob() const { return mem_per_job_override; }
  int GetRequestedBatchSize() const { return requested_batchsize; }
  KernelMode GetKernelMode() const { return kernel_mode; }

private:
  uint32_t *dev_keys; // internal code is still viewing these as uint32_t blobs.
  uint32_t *dev_scratch;
  uint32_t *dev_output;
  uint32_t *dev_tstate;
  uint32_t *dev_ostate;
  scan_job *dev_job;

  uint32_t *scan_output;
  int batchsize;
  int n_blocks;
  int requested_batchsize;
  int mem_per_job_override;
  KernelMode kernel_mode;
};

static const int THREADS_PER_SCRYPT_BLOCK = 4;
static const int MAX_CANDIDATES_PER_BATCH = 256;
static const int THREADS_PER_CUDA_BLOCK = 192; // Must be a multiple of TPScB
static const int SCRYPT_SCRATCH_PER_BLOCK = (32*1024);
static const int SCRYPT_WIDTH = 16;


#endif /* _CUDAHASHER_H_ */
