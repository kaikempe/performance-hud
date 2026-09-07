import Foundation
import SensorBridge

/// One CPU cluster (or the GPU) and how hard it's clocking.
struct ClockSample: Identifiable {
    /// Display name — "Super"/"Performance" from `hw.perflevelN.name` where the
    /// core count identifies the cluster, else the raw IOReport name.
    let label: String
    /// Residency-weighted rung on the DVFS ladder while running, 0–100.
    let clockPercent: Double
    /// Share of the interval spent running rather than idle, 0–100.
    let activePercent: Double
    let coreCount: Int

    var id: String { label }
}

/// Reads DVFS residency per CPU cluster and for the GPU.
final class ClockUsage {
    // Residency is a delta between samples, so the reader has to persist.
    private let reader = PHUDClockReader()
    /// Core count → perf-level name, e.g. 6 → "Super", 12 → "Performance".
    private let clusterNames: [Int: String] = ClockUsage.performanceLevelNames()

    /// CPU clusters, ordered fastest-tier first; and the GPU, separately.
    func sample() -> (cpu: [ClockSample], gpu: ClockSample?) {
        let raw = reader.sample()

        var cpu: [ClockSample] = []
        var gpu: ClockSample?

        for (cluster, state) in raw {
            let cores = state.coreCount
            let sample = ClockSample(label: cluster == "GPU" ? "GPU" : (clusterNames[cores] ?? cluster),
                                     clockPercent: state.clockPercent,
                                     activePercent: state.activePercent,
                                     coreCount: cores)
            if cluster == "GPU" { gpu = sample } else { cpu.append(sample) }
        }

        // Fewer cores = the higher-performance tier on Apple Silicon, and it's
        // the one worth reading first.
        cpu.sort { ($0.coreCount, $0.label) < ($1.coreCount, $1.label) }
        return (cpu, gpu)
    }

    /// `hw.perflevelN.name` / `.physicalcpu`, so clusters get the names Apple
    /// gives them on this specific chip rather than a hardcoded E/P guess —
    /// this Mac reports "Super" and "Performance", not "Efficiency".
    private static func performanceLevelNames() -> [Int: String] {
        var names: [Int: String] = [:]
        let levels = sysctlInt("hw.nperflevels").map(Int.init) ?? 0
        for level in 0..<levels {
            guard let cores = sysctlInt("hw.perflevel\(level).physicalcpu").map(Int.init),
                  let name = sysctlString("hw.perflevel\(level).name") else { continue }
            names[cores] = name
        }
        return names
    }

    private static func sysctlInt(_ name: String) -> Int64? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
