import Foundation

enum Format {
    /// Bytes/sec → human string, e.g. "1.2 MB/s".
    static func rate(_ bytesPerSec: Double) -> String {
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var value = bytesPerSec
        var unit = 0
        while value >= 1024 && unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return String(format: value >= 100 || unit == 0 ? "%.0f %@" : "%.1f %@", value, units[unit])
    }

    /// Bytes → "1.5 GB". Sizes, not rates.
    static func bytes(_ value: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var size = value
        var unit = 0
        while size >= 1024 && unit < units.count - 1 {
            size /= 1024
            unit += 1
        }
        return String(format: size >= 100 || unit == 0 ? "%.0f %@" : "%.1f %@", size, units[unit])
    }

    static func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value)
    }

    static func watts(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: value >= 100 ? "%.0f W" : "%.1f W", value)
    }

    /// Two decimals, for the itemised breakdown where blocks draw well under a
    /// watt and "0.0 W" would flatten them all to the same number.
    static func wattsPrecise(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.2f W", value)
    }

    /// Minutes → "3:42 left" style clock, for battery time remaining.
    static func duration(minutes: Int) -> String {
        String(format: "%d:%02d", minutes / 60, minutes % 60)
    }

    static func temp(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.0f°C", value)
    }
}
