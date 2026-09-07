import Foundation

struct NetworkSample {
    let downBytesPerSec: Double
    let upBytesPerSec: Double
}

/// Network throughput via `getifaddrs`, summing per-interface byte counters
/// (excluding loopback) and dividing the delta by elapsed time.
final class NetworkUsage {
    private var prevIn: UInt64 = 0
    private var prevOut: UInt64 = 0
    private var prevTime: Date?

    func sample(now: Date = Date()) -> NetworkSample {
        var totalIn: UInt64 = 0
        var totalOut: UInt64 = 0

        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else {
            return NetworkSample(downBytesPerSec: 0, upBytesPerSec: 0)
        }
        defer { freeifaddrs(ifaddrPtr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            if let addr = cur.pointee.ifa_addr,
               addr.pointee.sa_family == UInt8(AF_LINK),
               let data = cur.pointee.ifa_data {
                let name = String(cString: cur.pointee.ifa_name)
                if !name.hasPrefix("lo") {
                    let netData = data.assumingMemoryBound(to: if_data.self)
                    totalIn += UInt64(netData.pointee.ifi_ibytes)
                    totalOut += UInt64(netData.pointee.ifi_obytes)
                }
            }
            ptr = cur.pointee.ifa_next
        }

        defer { prevIn = totalIn; prevOut = totalOut; prevTime = now }
        guard let last = prevTime else {
            return NetworkSample(downBytesPerSec: 0, upBytesPerSec: 0)
        }
        let dt = now.timeIntervalSince(last)
        guard dt > 0 else { return NetworkSample(downBytesPerSec: 0, upBytesPerSec: 0) }

        // Guard against counter resets / wraps.
        let inDelta = totalIn >= prevIn ? totalIn - prevIn : 0
        let outDelta = totalOut >= prevOut ? totalOut - prevOut : 0
        return NetworkSample(
            downBytesPerSec: Double(inDelta) / dt,
            upBytesPerSec: Double(outDelta) / dt
        )
    }
}
