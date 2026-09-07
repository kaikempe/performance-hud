import Foundation
import IOKit

struct DiskSample {
    let readBytesPerSec: Double
    let writeBytesPerSec: Double

    static let zero = DiskSample(readBytesPerSec: 0, writeBytesPerSec: 0)
}

/// Disk throughput from the `IOBlockStorageDriver` statistics dictionary, summed
/// across every drive and divided by elapsed time — the same counters `iostat`
/// reads, and no more privileged.
final class DiskUsage {
    private var prevRead: UInt64 = 0
    private var prevWrite: UInt64 = 0
    private var prevTime: Date?

    func sample(now: Date = Date()) -> DiskSample {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOBlockStorageDriver"),
                                           &iterator) == KERN_SUCCESS else {
            return .zero
        }
        defer { IOObjectRelease(iterator) }

        var totalRead: UInt64 = 0
        var totalWrite: UInt64 = 0

        while case let drive = IOIteratorNext(iterator), drive != 0 {
            defer { IOObjectRelease(drive) }

            var unmanaged: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(drive, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let props = unmanaged?.takeRetainedValue() as? [String: Any],
                  let stats = props["Statistics"] as? [String: Any] else { continue }

            totalRead += stats["Bytes (Read)"] as? UInt64 ?? 0
            totalWrite += stats["Bytes (Write)"] as? UInt64 ?? 0
        }

        defer { prevRead = totalRead; prevWrite = totalWrite; prevTime = now }
        guard let last = prevTime else { return .zero }
        let dt = now.timeIntervalSince(last)
        guard dt > 0 else { return .zero }

        // Guard against a drive disappearing and the totals going backwards.
        let readDelta = totalRead >= prevRead ? totalRead - prevRead : 0
        let writeDelta = totalWrite >= prevWrite ? totalWrite - prevWrite : 0
        return DiskSample(readBytesPerSec: Double(readDelta) / dt,
                          writeBytesPerSec: Double(writeDelta) / dt)
    }
}
