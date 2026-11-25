import Darwin
import Foundation

@MainActor final class PerformanceResourceSampler {
    struct ProcessReading {
        let footprint: UInt64?
        let cpuFraction: Double?
    }

    private struct Sample {
        let time: Double
        let cpuSeconds: Double?
        let reading: ProcessReading
    }

    private struct MetalReading {
        let bytes: UInt64?
    }

    static let shared = PerformanceResourceSampler()
    private let consumers = NSHashTable<NSObject>.weakObjects()
    private let now: () -> Double
    private let processCPUSeconds: () -> Double?
    private let footprint: () -> UInt64?
    private var previous: Sample?
    private var metal: [UInt64: MetalReading] = [:]

    init(
        now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
        processCPUSeconds: @escaping () -> Double? = { PerformanceResourceSampler.cpuSeconds() },
        footprint: @escaping () -> UInt64? = { PerformanceMemory.processFootprintBytes() }
    ) {
        self.now = now
        self.processCPUSeconds = processCPUSeconds
        self.footprint = footprint
    }

    func setDemand(_ enabled: Bool, for consumer: NSObject) {
        if enabled {
            if consumers.allObjects.isEmpty { reset() }
            consumers.add(consumer)
        } else {
            consumers.remove(consumer)
            if consumers.allObjects.isEmpty { reset() }
        }
    }

    func processReading() -> ProcessReading? {
        guard !consumers.allObjects.isEmpty else { return nil }
        let time = now()
        guard time.isFinite else { return nil }
        if let previous, time >= previous.time, time - previous.time < 1 { return previous.reading }
        let cpu = processCPUSeconds()
        let fraction: Double?
        if let previous, let before = previous.cpuSeconds, let cpu,
            time > previous.time, cpu.isFinite, before.isFinite, before >= 0, cpu >= before
        {
            fraction = (cpu - before) / (time - previous.time)
        } else {
            fraction = nil
        }
        let reading = ProcessReading(footprint: footprint(), cpuFraction: fraction)
        previous = Sample(time: time, cpuSeconds: cpu, reading: reading)
        metal.removeAll(keepingCapacity: true)
        return reading
    }

    // Called alongside processReading(), which advances the shared sampling interval.
    func metalBytes(registryID: UInt64, query: () -> UInt64?) -> UInt64? {
        guard !consumers.allObjects.isEmpty else { return nil }
        if let cached = metal[registryID] { return cached.bytes }
        let reading = MetalReading(bytes: query())
        metal[registryID] = reading
        return reading.bytes
    }

    private func reset() {
        previous = nil
        metal.removeAll()
    }

    private nonisolated static func cpuSeconds() -> Double? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_stime.tv_sec)
            + (Double(usage.ru_utime.tv_usec) + Double(usage.ru_stime.tv_usec)) / 1_000_000
    }
}
