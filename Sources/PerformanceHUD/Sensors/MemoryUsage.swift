import Foundation

/// The kernel's own memory-pressure level — the same signal that drives
/// Activity Monitor's green / yellow / red bar.
enum MemoryPressure: Int {
    case normal = 1
    case warning = 2
    case critical = 4

    var label: String {
        switch self {
        case .normal: return "normal"
        case .warning: return "warning"
        case .critical: return "critical"
        }
    }
}

struct MemorySample {
    let usedBytes: UInt64
    let totalBytes: UInt64
    /// Pages the compressor is holding. Counted inside `usedBytes` — as Activity
    /// Monitor does — but broken out, because RAM that is only "used" because it
    /// has been squeezed is a different situation from RAM held by live apps.
    let compressedBytes: UInt64
    let swapUsedBytes: UInt64
    let swapTotalBytes: UInt64
    let pressure: MemoryPressure

    var usedGB: Double { Double(usedBytes) / 1_073_741_824 }
    var totalGB: Double { Double(totalBytes) / 1_073_741_824 }
    var percent: Double { totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) * 100 : 0 }

    var compressedGB: Double { Double(compressedBytes) / 1_073_741_824 }
    var swapUsedGB: Double { Double(swapUsedBytes) / 1_073_741_824 }

    /// Swap and pressure are the two signals worth interrupting someone over;
    /// "used GB" on macOS is close to meaningless on its own, because the OS
    /// deliberately fills RAM and counts compressed pages as used.
    var isStrained: Bool { pressure != .normal || swapUsedBytes > 0 }

    static func empty(total: UInt64) -> MemorySample {
        MemorySample(usedBytes: 0, totalBytes: total, compressedBytes: 0,
                     swapUsedBytes: 0, swapTotalBytes: 0, pressure: .normal)
    }
}

/// Physical memory usage via `host_statistics64` / `vm_statistics64`.
/// "Used" mirrors Activity Monitor: active + wired + compressed pages.
final class MemoryUsage {
    private let pageSize = UInt64(vm_kernel_page_size)
    private let total = ProcessInfo.processInfo.physicalMemory

    func sample() -> MemorySample {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return .empty(total: total) }

        let active = UInt64(stats.active_count) * pageSize
        let wired = UInt64(stats.wire_count) * pageSize
        let compressed = UInt64(stats.compressor_page_count) * pageSize
        let swap = Self.swapUsage()

        return MemorySample(usedBytes: active + wired + compressed,
                            totalBytes: total,
                            compressedBytes: compressed,
                            swapUsedBytes: swap?.xsu_used ?? 0,
                            swapTotalBytes: swap?.xsu_total ?? 0,
                            pressure: Self.pressure())
    }

    private static func swapUsage() -> xsw_usage? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return usage
    }

    /// `kern.memorystatus_vm_pressure_level` reports the same 1 / 2 / 4 levels
    /// that `DISPATCH_SOURCE_TYPE_MEMORYPRESSURE` delivers as events — polled
    /// here because the panel already samples on a timer and only wants the
    /// level as it stands, not a change notification.
    private static func pressure() -> MemoryPressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else {
            return .normal
        }
        return MemoryPressure(rawValue: Int(level)) ?? .normal
    }
}
