#include "ProcBridge.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <libproc.h>
#include <mach/mach.h>
#include <mach/mach_host.h>
#include <mach/processor_info.h>
#include <mach/vm_statistics.h>
#include <string.h>
#include <stdlib.h>
#include <sys/sysctl.h>
#include <sys/resource.h>
#include <unistd.h>

int rs_sample_processes(RSProcSample *out, int max_count) {
    if (out == NULL || max_count <= 0) {
        return -1;
    }

    int bufsize = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    if (bufsize <= 0) {
        return -1;
    }

    pid_t *pids = (pid_t *)malloc((size_t)bufsize);
    if (pids == NULL) {
        return -1;
    }

    int nbytes = proc_listpids(PROC_ALL_PIDS, 0, pids, bufsize);
    if (nbytes <= 0) {
        free(pids);
        return -1;
    }

    int n = nbytes / (int)sizeof(pid_t);
    int count = 0;

    for (int i = 0; i < n && count < max_count; i++) {
        pid_t pid = pids[i];
        if (pid <= 0) {
            continue;
        }

        struct proc_bsdinfo bsd;
        memset(&bsd, 0, sizeof(bsd));
        int got = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, (int)sizeof(bsd));
        if (got <= 0) {
            continue;
        }

        RSProcSample sample;
        memset(&sample, 0, sizeof(sample));
        sample.pid = (int32_t)pid;
        sample.uid = (uint32_t)bsd.pbi_uid;
        sample.start_unix = bsd.pbi_start_tvsec;

        if (proc_name(pid, sample.name, (uint32_t)sizeof(sample.name)) <= 0) {
            strncpy(sample.name, bsd.pbi_name, sizeof(sample.name) - 1);
        }

        proc_pidpath(pid, sample.path, (uint32_t)sizeof(sample.path));

        rusage_info_current rusage;
        memset(&rusage, 0, sizeof(rusage));
        if (proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, (rusage_info_t *)&rusage) == 0) {
            sample.phys_footprint_bytes = rusage.ri_phys_footprint;
            sample.resident_bytes = rusage.ri_resident_size;
            sample.cpu_time_ns = rusage.ri_user_time + rusage.ri_system_time;
        } else {
            struct proc_taskinfo task;
            memset(&task, 0, sizeof(task));
            if (proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, (int)sizeof(task)) > 0) {
                sample.resident_bytes = task.pti_resident_size;
                sample.phys_footprint_bytes = task.pti_resident_size;
                sample.cpu_time_ns = task.pti_total_user + task.pti_total_system;
            }
        }

        out[count++] = sample;
    }

    free(pids);
    return count;
}

int rs_host_memory(RSHostMemory *out) {
    if (out == NULL) {
        return -1;
    }
    memset(out, 0, sizeof(*out));

    mach_port_t host = mach_host_self();
    vm_size_t page_size = 0;
    if (host_page_size(host, &page_size) != KERN_SUCCESS || page_size == 0) {
        page_size = 4096;
    }
    out->page_size = (uint64_t)page_size;

    vm_statistics64_data_t vm;
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    memset(&vm, 0, sizeof(vm));
    if (host_statistics64(host, HOST_VM_INFO64, (host_info64_t)&vm, &count) != KERN_SUCCESS) {
        return -1;
    }

    out->free_bytes = (uint64_t)vm.free_count * page_size;
    out->active_bytes = (uint64_t)vm.active_count * page_size;
    out->inactive_bytes = (uint64_t)vm.inactive_count * page_size;
    out->wired_bytes = (uint64_t)vm.wire_count * page_size;
    out->compressed_bytes = (uint64_t)vm.compressor_page_count * page_size;
    out->speculative_bytes = (uint64_t)vm.speculative_count * page_size;
    out->purgeable_bytes = (uint64_t)vm.purgeable_count * page_size;
    out->internal_bytes = (uint64_t)vm.internal_page_count * page_size;
    out->external_bytes = (uint64_t)vm.external_page_count * page_size;
    out->swapins = vm.swapins;
    out->swapouts = vm.swapouts;

    uint64_t memsize = 0;
    size_t len = sizeof(memsize);
    if (sysctlbyname("hw.memsize", &memsize, &len, NULL, 0) == 0) {
        out->physical_bytes = memsize;
    }

    struct xsw_usage swap;
    memset(&swap, 0, sizeof(swap));
    size_t swapLen = sizeof(swap);
    if (sysctlbyname("vm.swapusage", &swap, &swapLen, NULL, 0) == 0) {
        out->swap_total_bytes = swap.xsu_total;
        out->swap_used_bytes = swap.xsu_used;
    }

    return 0;
}

int rs_process_status(int32_t pid) {
    struct proc_bsdinfo bsd;
    memset(&bsd, 0, sizeof(bsd));
    int got = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, (int)sizeof(bsd));
    if (got <= 0) {
        return -1;
    }
    return (int)bsd.pbi_status;
}

int rs_host_cpu_ticks(RSHostCPUTicks *out) {
    if (out == NULL) {
        return -1;
    }
    memset(out, 0, sizeof(*out));

    host_cpu_load_info_data_t info;
    mach_msg_type_number_t count = HOST_CPU_LOAD_INFO_COUNT;
    if (host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, (host_info_t)&info, &count) != KERN_SUCCESS) {
        return -1;
    }
    out->user = info.cpu_ticks[CPU_STATE_USER];
    out->system = info.cpu_ticks[CPU_STATE_SYSTEM];
    out->idle = info.cpu_ticks[CPU_STATE_IDLE];
    out->nice = info.cpu_ticks[CPU_STATE_NICE];
    return 0;
}

static int rs_copy_double(CFDictionaryRef dict, CFStringRef key, double *out) {
    if (dict == NULL || key == NULL || out == NULL) {
        return 0;
    }
    CFTypeRef value = CFDictionaryGetValue(dict, key);
    if (value == NULL || CFGetTypeID(value) != CFNumberGetTypeID()) {
        return 0;
    }
    return CFNumberGetValue((CFNumberRef)value, kCFNumberDoubleType, out) ? 1 : 0;
}

static int rs_copy_u64(CFDictionaryRef dict, CFStringRef key, uint64_t *out) {
    double value = 0;
    if (!rs_copy_double(dict, key, &value)) {
        return 0;
    }
    if (value < 0) {
        value = -value;
    }
    *out = (uint64_t)value;
    return 1;
}

int rs_host_gpu(RSHostGPU *out) {
    if (out == NULL) {
        return -1;
    }
    memset(out, 0, sizeof(*out));

    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) != KERN_SUCCESS) {
        return -1;
    }

    io_registry_entry_t entry = IO_OBJECT_NULL;
    double best = -1;
    while ((entry = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        CFMutableDictionaryRef props = NULL;
        if (IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS && props != NULL) {
            CFDictionaryRef perf = CFDictionaryGetValue(props, CFSTR("PerformanceStatistics"));
            if (perf != NULL && CFGetTypeID(perf) == CFDictionaryGetTypeID()) {
                double util = -1;
                if (!rs_copy_double(perf, CFSTR("Device Utilization %"), &util)) {
                    if (!rs_copy_double(perf, CFSTR("GPU Activity(%)"), &util)) {
                        if (!rs_copy_double(perf, CFSTR("Renderer Utilization %"), &util)) {
                            rs_copy_double(perf, CFSTR("Device Utilization % at cur p-state"), &util);
                        }
                    }
                }
                if (util > best) {
                    best = util;
                    out->device_percent = util;
                    if (!rs_copy_u64(perf, CFSTR("gartUsedBytes"), &out->memory_used_bytes)) {
                        rs_copy_u64(perf, CFSTR("In use system memory"), &out->memory_used_bytes);
                    }
                    if (!rs_copy_u64(perf, CFSTR("gartSizeBytes"), &out->memory_total_bytes)) {
                        rs_copy_u64(perf, CFSTR("Alloc system memory"), &out->memory_total_bytes);
                    }
                    io_name_t name;
                    if (IORegistryEntryGetName(entry, name) == KERN_SUCCESS) {
                        strncpy(out->name, name, sizeof(out->name) - 1);
                    }
                }
            }
            CFRelease(props);
        }
        IOObjectRelease(entry);
    }
    IOObjectRelease(iterator);
    return best >= 0 ? 0 : -1;
}
