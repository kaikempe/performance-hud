import Foundation
import IOKit

struct GPUSample {
    /// Overall device utilization, 0–100.
    let utilization: Double
    /// The two halves of the tile-based pipeline, 0–100 — a lopsided pair points
    /// at which stage a frame is bottlenecked on.
    let tilerPercent: Double?
    let rendererPercent: Double?
    /// GPU-addressable memory actually in use, in bytes. Unified memory, so this
    /// comes out of the same pool as system RAM.
    let inUseBytes: Double?
    /// Total the driver has allocated, in bytes — its high-water reservation.
    let allocatedBytes: Double?

    static let zero = GPUSample(utilization: 0, tilerPercent: nil, rendererPercent: nil,
                                inUseBytes: nil, allocatedBytes: nil)
}

/// GPU statistics from the IORegistry `IOAccelerator` service's
/// `PerformanceStatistics`. Pure IOKit, no entitlement.
final class GPUUsage {
    func sample() -> GPUSample {
        var iterator = io_iterator_t()
        let match = IOServiceMatching("IOAccelerator")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &iterator) == KERN_SUCCESS else {
            return .zero
        }
        defer { IOObjectRelease(iterator) }

        var utilization = 0.0
        var tiler: Double?
        var renderer: Double?
        var inUse: Double?
        var allocated: Double?

        var service = IOIteratorNext(iterator)
        while service != 0 {
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = props?.takeRetainedValue() as? [String: Any],
               let perf = dict["PerformanceStatistics"] as? [String: Any] {
                // Values arrive as NSNumber; read them uniformly.
                func value(_ key: String) -> Double? { (perf[key] as? NSNumber)?.doubleValue }

                if let util = value("Device Utilization %") { utilization = max(utilization, util) }
                if let value = value("Tiler Utilization %") { tiler = max(tiler ?? 0, value) }
                if let value = value("Renderer Utilization %") { renderer = max(renderer ?? 0, value) }
                // Several accelerators can be present; the memory figures add up.
                if let value = value("In use system memory") { inUse = (inUse ?? 0) + value }
                if let value = value("Alloc system memory") { allocated = (allocated ?? 0) + value }
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }

        return GPUSample(utilization: utilization, tilerPercent: tiler, rendererPercent: renderer,
                         inUseBytes: inUse, allocatedBytes: allocated)
    }
}
