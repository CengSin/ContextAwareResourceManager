#ifndef ProcBridge_h
#define ProcBridge_h

#include <stdint.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    int32_t pid;
    int32_t ppid;
    uint32_t uid;
    uint64_t phys_footprint_bytes;
    uint64_t resident_bytes;
    uint64_t cpu_time_ns;
    uint64_t start_unix;
    uint32_t start_usec;
    char name[64];
    char path[1024];
} RSProcSample;

typedef struct {
    uint64_t page_size;
    uint64_t physical_bytes;
    uint64_t free_bytes;
    uint64_t active_bytes;
    uint64_t inactive_bytes;
    uint64_t wired_bytes;
    uint64_t compressed_bytes;
    uint64_t speculative_bytes;
    uint64_t purgeable_bytes;
    uint64_t internal_bytes;
    uint64_t external_bytes;
    uint64_t swap_total_bytes;
    uint64_t swap_used_bytes;
    uint64_t swapins;
    uint64_t swapouts;
} RSHostMemory;

/// Samples currently visible processes. Returns count written, or -1 on failure.
int rs_sample_processes(RSProcSample *out, int max_count);

/// Fills host-level memory statistics. Returns 0 on success.
int rs_host_memory(RSHostMemory *out);

/// Returns kernel p_stat (SRUN=2, SSLEEP=3, SSTOP=4, …) or -1.
int rs_process_status(int32_t pid);

/// Returns task scheduling priority, or -1 when unavailable.
int rs_process_priority(int32_t pid);

/// Copies the process start time. Returns 0 on success, -1 if the pid is gone.
int rs_process_generation(int32_t pid, uint64_t *start_sec, uint32_t *start_usec);

typedef struct {
    uint64_t user;
    uint64_t system;
    uint64_t idle;
    uint64_t nice;
} RSHostCPUTicks;

typedef struct {
    double device_percent;
    uint64_t memory_used_bytes;
    uint64_t memory_total_bytes;
    char name[64];
} RSHostGPU;

/// Fills aggregated CPU tick counters since boot. Returns 0 on success.
int rs_host_cpu_ticks(RSHostCPUTicks *out);

/// Reads GPU occupancy from IOAccelerator. Returns 0 on success.
int rs_host_gpu(RSHostGPU *out);

#ifdef __cplusplus
}
#endif

#endif
