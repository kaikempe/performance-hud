import Foundation

/// Overall CPU utilization via the Mach `HOST_CPU_LOAD_INFO` tick counters.
/// Usage is the delta of busy ticks over total ticks between two samples.
final class CPUUsage {
    private var previous: host_cpu_load_info?

    /// Returns CPU usage as a percentage (0–100). The first call primes the delta
    /// and returns 0.
    func sample() -> Double {
        var size = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride
        )
        var info = host_cpu_load_info()
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { intPtr in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, intPtr, &size)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }

        defer { previous = info }
        guard let prev = previous else { return 0 }

        // cpu_ticks indices: 0 = user, 1 = system, 2 = idle, 3 = nice.
        let user = Double(info.cpu_ticks.0 &- prev.cpu_ticks.0)
        let system = Double(info.cpu_ticks.1 &- prev.cpu_ticks.1)
        let idle = Double(info.cpu_ticks.2 &- prev.cpu_ticks.2)
        let nice = Double(info.cpu_ticks.3 &- prev.cpu_ticks.3)
        let total = user + system + idle + nice
        guard total > 0 else { return 0 }
        return (user + system + nice) / total * 100.0
    }
}
