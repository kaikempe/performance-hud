import Foundation
import Darwin

struct ProcessSample: Identifiable {
    let pid: Int32
    let name: String
    /// Percent of one core. A process using four cores flat reads 400%.
    let cpuPercent: Double

    var id: Int32 { pid }
}

/// Ranks processes by CPU use, from `libproc` CPU-time deltas — the same basis
/// as Activity Monitor's %CPU, and the closest honest answer to "what's using my
/// CPU right now". Note this is CPU time, not watts: no Mac meters power per
/// process (see README).
final class ProcessUsage {
    private var previousTimes: [Int32: UInt64] = [:]
    private var previousStamp: Date?

    /// Longest gap between samples that still describes "now" rather than a
    /// long-run average.
    private static let maxUsefulGap: TimeInterval = 10

    /// `rusage_info` reports CPU time in mach absolute ticks, not nanoseconds —
    /// on Apple Silicon a tick is 41.67 ns, so skipping this conversion
    /// understates every process by ~24×.
    private let ticksToNanos: Double = {
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom > 0 else { return 1 }
        return Double(timebase.numer) / Double(timebase.denom)
    }()

    /// The `count` busiest processes. Returns [] until it has two samples to diff.
    func sample(count: Int = 5, now: Date = Date()) -> [ProcessSample] {
        var current: [Int32: UInt64] = [:]

        // proc_listpids wants a byte count; ask for the size, then the list.
        let capacity = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity) / MemoryLayout<pid_t>.size)
        let written = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, capacity)
        guard written > 0 else { return [] }
        pids = Array(pids.prefix(Int(written) / MemoryLayout<pid_t>.size))

        for pid in pids where pid > 0 {
            var info = rusage_info_v2()
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
                }
            }
            // EPERM on processes we don't own — skip rather than fail the sweep.
            guard result == 0 else { continue }
            current[pid] = info.ri_user_time + info.ri_system_time
        }

        defer { previousTimes = current; previousStamp = now }
        guard let last = previousStamp else { return [] }
        let elapsed = now.timeIntervalSince(last)
        // This reader is only polled while the panel is open, so the previous
        // snapshot can be minutes old. Diffing against it would report an average
        // over that whole gap and call it "right now" — prime instead and let the
        // next tick produce a real figure.
        guard elapsed > 0, elapsed <= Self.maxUsefulGap else { return [] }

        let elapsedNanos = elapsed * 1_000_000_000
        var samples: [ProcessSample] = []
        for (pid, time) in current {
            // A pid absent last time is newly launched; its lifetime CPU would
            // read as a spike, so wait for the next tick to rank it.
            guard let before = previousTimes[pid], time > before else { continue }
            let percent = Double(time - before) * ticksToNanos / elapsedNanos * 100
            guard percent >= 0.5 else { continue }
            samples.append(ProcessSample(pid: pid, name: Self.name(of: pid), cpuPercent: percent))
        }

        return Array(samples.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(count))
    }

    private static func name(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: Int(2 * MAXCOMLEN) + 1)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return "pid \(pid)" }
        return String(cString: buffer)
    }
}
