import Darwin
import Foundation
import ProcBridge

public final class SystemMonitor: @unchecked Sendable {
    
    public static let gpuSampleIntervalSeconds: TimeInterval = 20

    private let lock = NSLock()
    private var previousCPU: RSHostCPUTicks?
    private var gpuWindow: [Double] = []
    private let gpuWindowSize = 5
    private var lastGPU: HostGPU = .unavailable
    private var lastGPUSampleAt: Date = .distantPast
    
    public private(set) var gpuHardwareSampleCount = 0
    private var previousProcessCPU: [Int32: (timeNs: UInt64, sampledAt: Date)] = [:]
    private var previousProcessGPU: [Int32: (timeNs: UInt64, sampledAt: Date)] = [:]

    public init() {}

    public func sampleHost() -> HostMemory {
        var raw = RSHostMemory()
        guard rs_host_memory(&raw) == 0 else { return .empty }
        return HostMemory(
            pageSize: raw.page_size,
            physicalBytes: raw.physical_bytes,
            freeBytes: raw.free_bytes,
            activeBytes: raw.active_bytes,
            inactiveBytes: raw.inactive_bytes,
            wiredBytes: raw.wired_bytes,
            compressedBytes: raw.compressed_bytes,
            speculativeBytes: raw.speculative_bytes,
            purgeableBytes: raw.purgeable_bytes,
            internalBytes: raw.internal_bytes,
            externalBytes: raw.external_bytes,
            swapTotalBytes: raw.swap_total_bytes,
            swapUsedBytes: raw.swap_used_bytes,
            swapins: raw.swapins,
            swapouts: raw.swapouts
        )
    }

    public func sampleProcesses(maxCount: Int = 512) -> [RawProcessSample] {
        var buffer = Array(repeating: RSProcSample(), count: maxCount)
        let count = buffer.withUnsafeMutableBufferPointer { ptr in
            rs_sample_processes(ptr.baseAddress, Int32(maxCount))
        }
        guard count > 0 else { return [] }
        return buffer.prefix(Int(count)).map { sample in
            RawProcessSample(
                pid: sample.pid,
                parentPID: sample.ppid,
                uid: sample.uid,
                physFootprintBytes: sample.phys_footprint_bytes,
                residentBytes: sample.resident_bytes,
                cpuTimeNs: sample.cpu_time_ns,
                startUnix: sample.start_unix,
                startUsec: sample.start_usec,
                name: stringFromCChar(sample.name),
                path: stringFromCChar(sample.path)
            )
        }
        .filter { !$0.name.isEmpty }
    }

    public func processStatus(pid: Int32) -> Int {
        Int(rs_process_status(pid))
    }

    public static func processGeneration(pid: Int32) -> ProcessGeneration? {
        var sec: UInt64 = 0
        var usec: UInt32 = 0
        guard rs_process_generation(pid, &sec, &usec) == 0 else { return nil }
        return ProcessGeneration(pid: pid, startUnix: TimeInterval(sec) + TimeInterval(usec) / 1_000_000)
    }

    public func sampleCPU() -> HostCPU {
        var current = RSHostCPUTicks()
        guard rs_host_cpu_ticks(&current) == 0 else { return .empty }

        lock.lock()
        let previous = previousCPU
        previousCPU = current
        lock.unlock()
        guard let previous else {
            
            
            return .empty
        }
        return HostCPU.fromTicks(
            previousUser: previous.user, previousSystem: previous.system,
            previousIdle: previous.idle, previousNice: previous.nice,
            currentUser: current.user, currentSystem: current.system,
            currentIdle: current.idle, currentNice: current.nice
        )
    }

    public func sampleGPU(now: Date = Date(), force: Bool = false) -> HostGPU {
        lock.lock()
        if !force,
           lastGPUSampleAt != .distantPast,
           now.timeIntervalSince(lastGPUSampleAt) < Self.gpuSampleIntervalSeconds
        {
            let cached = lastGPU
            lock.unlock()
            return cached
        }
        lock.unlock()

        var raw = RSHostGPU()
        guard rs_host_gpu(&raw) == 0 else {
            lock.lock()
            lastGPU = .unavailable
            lastGPUSampleAt = now
            gpuHardwareSampleCount += 1
            lock.unlock()
            return .unavailable
        }
        let instant = min(100, max(0, raw.device_percent))
        lock.lock()
        gpuWindow.append(instant)
        if gpuWindow.count > gpuWindowSize {
            gpuWindow.removeFirst()
        }
        let smoothed = Self.median(gpuWindow)
        let sampled = HostGPU(
            usagePercent: smoothed,
            memoryUsedBytes: raw.memory_used_bytes,
            memoryTotalBytes: raw.memory_total_bytes,
            name: stringFromCChar(raw.name),
            available: true
        )
        lastGPU = sampled
        lastGPUSampleAt = now
        gpuHardwareSampleCount += 1
        lock.unlock()
        return sampled
    }

    public func cpuPercent(pid: Int32, cpuTimeNs: UInt64, now: Date) -> Double {
        lock.lock()
        let previous = previousProcessCPU[pid]
        previousProcessCPU[pid] = (cpuTimeNs, now)
        lock.unlock()
        guard let previous else { return 0 }
        let dt = now.timeIntervalSince(previous.sampledAt)
        guard dt > 0.2, cpuTimeNs >= previous.timeNs else { return 0 }
        let dCPU = Double(cpuTimeNs - previous.timeNs) / 1_000_000_000.0
        return max(0, (dCPU / dt) * 100)
    }

    public func pruneProcessCPU(livePIDs: Set<Int32>) {
        lock.lock()
        previousProcessCPU = previousProcessCPU.filter { livePIDs.contains($0.key) }
        lock.unlock()
    }

    public func sampleProcessGPUTimes(maxCount: Int = 512) -> [Int32: UInt64] {
        var buffer = Array(repeating: RSProcessGPUSample(), count: maxCount)
        let count = buffer.withUnsafeMutableBufferPointer { ptr in
            rs_sample_process_gpu_times(ptr.baseAddress, Int32(maxCount))
        }
        guard count > 0 else { return [:] }
        var result: [Int32: UInt64] = [:]
        for sample in buffer.prefix(Int(count)) {
            result[sample.pid] = sample.gpu_time_ns
        }
        return result
    }

    public func gpuPercent(pid: Int32, gpuTimeNs: UInt64, now: Date) -> Double {
        lock.lock()
        let previous = previousProcessGPU[pid]
        previousProcessGPU[pid] = (gpuTimeNs, now)
        lock.unlock()
        guard let previous else { return 0 }
        let dt = now.timeIntervalSince(previous.sampledAt)
        guard dt > 0.2, gpuTimeNs >= previous.timeNs else { return 0 }
        let dGPU = Double(gpuTimeNs - previous.timeNs) / 1_000_000_000.0
        return max(0, min(100, (dGPU / dt) * 100))
    }

    public func pruneProcessGPU(livePIDs: Set<Int32>) {
        lock.lock()
        previousProcessGPU = previousProcessGPU.filter { livePIDs.contains($0.key) }
        lock.unlock()
    }

    public static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}

public final class MemoryPressureMonitor: @unchecked Sendable {
    private var source: DispatchSourceMemoryPressure?
    private let lock = NSLock()
    private var _level: MemoryPressureLevel = .normal

    public var level: MemoryPressureLevel {
        lock.lock()
        defer { lock.unlock() }
        return _level
    }

    public init() {}

    public func start() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let event = source.data
            let level: MemoryPressureLevel
            if event.contains(.critical) {
                level = .critical
            } else if event.contains(.warning) {
                level = .warning
            } else {
                level = .normal
            }
            self.lock.lock()
            self._level = level
            self.lock.unlock()
        }
        source.resume()
        self.source = source
    }

    public func stop() {
        source?.cancel()
        source = nil
    }
}

private func stringFromCChar<T>(_ tuple: T) -> String {
    withUnsafeBytes(of: tuple) { raw in
        let buffer = raw.bindMemory(to: CChar.self)
        return String(cString: buffer.baseAddress!)
    }
}
