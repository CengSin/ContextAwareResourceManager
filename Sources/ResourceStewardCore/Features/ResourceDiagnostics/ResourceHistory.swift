import Foundation

public final class ResourceHistory {
    private var lastRecord = Date.distantPast
    private var lastPressure = ""
    private var previous: (HostMemory, Date)?

    private let log: DiagnosticLog

    public init(log: DiagnosticLog = .shared) { self.log = log }

    public func sample(host: HostMemory, cpu: HostCPU, gpu: HostGPU, source: MemoryPressureLevel,
                       load: JevLoadState, snapshots: [ProcessSnapshot], groups: [ProcessGroupViewModel],
                       favorites: Set<String>, authorization: Int, jevActive: Bool, at now: Date) {
        let interval = previous.map { now.timeIntervalSince($0.1) }
        let stamp = source.rawValue + ":" + load.memory_pressure
        let due = now.timeIntervalSince(lastRecord) >= 30 || lastPressure != stamp || now < lastRecord
        defer { previous = (host, now) }
        guard due else { return }
        lastRecord = now
        lastPressure = stamp
        var fields = Self.hostFields(host: host, cpu: cpu, gpu: gpu)
        fields["os_pressure_event"] = source.rawValue
        fields["os_pressure_note"] = "last_dispatch_event_initially_normal"
        fields["effective_pressure"] = load.memory_pressure
        fields["pressure_reasons"] = Self.pressureReasons(host: host, source: source)
        fields["memory_pressure_seconds"] = load.memory_pressure_seconds
        fields["cpu_pressure_seconds"] = load.cpu_pressure_seconds
        fields["sample_gap_seconds"] = interval as Any? ?? NSNull()
        fields["authorization_level"] = authorization
        fields["jev_active"] = jevActive
        fields["foreground_bundle_id"] = load.foreground_bundle_id
        fields["sampled_process_count"] = snapshots.count
        fields["process_limit_reached"] = snapshots.count >= 512
        fields["evaluated_group_count"] = groups.count
        fields["group_limit_reached"] = groups.count >= 80
        fields["swap_in_bytes_per_second"] = NSNull()
        fields["swap_out_bytes_per_second"] = NSNull()
        fields["swap_used_delta_bytes"] = NSNull()
        if let (old, _) = previous, let dt = interval, dt > 0, dt <= 60,
           host.physicalBytes > 0, old.physicalBytes > 0,
           host.swapins >= old.swapins, host.swapouts >= old.swapouts {
            fields["swap_in_bytes_per_second"] = Double(host.swapins - old.swapins) * Double(host.pageSize) / dt
            fields["swap_out_bytes_per_second"] = Double(host.swapouts - old.swapouts) * Double(host.pageSize) / dt
            fields["swap_used_delta_bytes"] = Double(host.swapUsedBytes) - Double(old.swapUsedBytes)
        }
        fields["hard_gate_exclusions"] = groups.compactMap { group -> [String: Any]? in
            let candidate = JevHardGate.Candidate(group: group, favorites: favorites)
            guard let reason = JevHardGate.skipReason(for: candidate)?.1 else { return nil }
            return ["bundle_id": candidate.bundleID, "pid": candidate.pid, "reason": reason]
        }
        fields["top_apps"] = groups.sorted { $0.totalMemoryMB > $1.totalMemoryMB }.prefix(12).map { group -> [String: Any] in
            let candidate = JevHardGate.Candidate(group: group, favorites: favorites)
            return ["bundle_id": candidate.bundleID, "pid": candidate.pid, "memory_mb": group.totalMemoryMB,
                    "cpu_percent": group.cpuPercent, "idle_seconds": group.idleSeconds,
                    "foreground": group.isForeground, "exclusion": JevHardGate.skipReason(for: candidate)?.1 ?? "eligible_for_load_filter"]
        }
        log.record("resource_sample", fields, at: now)
    }

    public static func pressureReasons(host: HostMemory, source: MemoryPressureLevel) -> [String] {
        var reasons: [String] = []
        if source != .normal { reasons.append("os_" + source.rawValue) }
        if host.swapUsedBytes > 1_073_741_824 { reasons.append("swap_stock_over_1gib") }
        if host.compressedRatio > 0.25 { reasons.append("compressed_over_25_percent") }
        if host.usedRatio > 0.75 { reasons.append("used_over_75_percent") }
        if host.physicalBytes == 0 { reasons.append("host_sample_unavailable") }
        return reasons.isEmpty ? ["below_thresholds"] : reasons
    }

    public static func hostFields(host: HostMemory, cpu: HostCPU, gpu: HostGPU) -> [String: Any] {
        ["host_memory_available": host.physicalBytes > 0,
         "physical_bytes": host.physicalBytes, "used_bytes": host.usedBytes,
         "free_bytes": host.freeBytes, "wired_bytes": host.wiredBytes,
         "compressed_bytes": host.compressedBytes, "purgeable_bytes": host.purgeableBytes,
         "swap_used_bytes": host.swapUsedBytes, "swap_total_bytes": host.swapTotalBytes,
         "swapins_pages": host.swapins, "swapouts_pages": host.swapouts,
         "cpu_percent": cpu.usagePercent, "gpu_available": gpu.available,
         "gpu_percent": gpu.available ? gpu.usagePercent as Any : NSNull(),
         "gpu_memory_used_bytes": gpu.available && gpu.memoryUsedAvailable ? gpu.memoryUsedBytes as Any : NSNull(),
         "gpu_memory_total_bytes": gpu.available && gpu.memoryTotalAvailable ? gpu.memoryTotalBytes as Any : NSNull(),
         "gpu_sampled_at": gpu.sampledAt?.timeIntervalSince1970 as Any? ?? NSNull(),
         "gpu_memory_kind": gpu.memoryKindName, "gpu_memory_note": "driver_counter_not_dedicated_vram_capacity",
         "gpu_sampling_interval_seconds": SystemMonitor.gpuSampleIntervalSeconds]
    }
}
