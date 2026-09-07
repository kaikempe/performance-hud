import Foundation
import IOKit

struct BatterySample {
    let percent: Double
    let isCharging: Bool
    /// True when a power adapter is connected, whether or not it's charging —
    /// macOS often sits at "plugged in, not charging" to preserve battery health.
    let isPluggedIn: Bool
    /// Magnitude of the charge/discharge rate. `isCharging` gives the direction:
    /// the raw amperage sign isn't relied on, since it varies by model.
    let watts: Double?
    /// Minutes until empty (discharging) or full (charging), nil while unknown —
    /// the gauge reports 65535 for "still estimating".
    let minutesRemaining: Int?
    let cycleCount: Int?
    /// Battery health, as reported by System Information's "Maximum Capacity".
    /// Read from macOS itself rather than derived here — see
    /// `BatteryHealthReporter` for why the two don't agree.
    let healthPercent: Double?
    /// What the battery can hold today, in mAh.
    let maxCapacitymAh: Double?
    /// What it could hold when new, in mAh.
    let designCapacitymAh: Double?

    /// Plugged in and holding — macOS parks at ~80% to preserve battery health,
    /// so this is the normal resting state, not a fault.
    var isHolding: Bool { isPluggedIn && !isCharging && watts == nil }

    var stateDescription: String {
        if isCharging { return "Charging" }
        if isPluggedIn { return "Plugged in, not charging" }
        return "On battery"
    }
}

/// Reads the internal battery from the `AppleSmartBattery` IORegistry node.
final class BatteryUsage {
    private let healthReporter = BatteryHealthReporter()

    /// Fetches battery health up front instead of letting the first sample fall
    /// back to the derived figure. Only worth it when there'll be no second
    /// sample — see `BatteryHealthReporter.prime()`.
    func primeHealth() { healthReporter.prime() }

    func sample() -> BatterySample? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }   // Desktop Mac — no battery.
        defer { IOObjectRelease(service) }

        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = unmanaged?.takeRetainedValue() as? [String: Any] else { return nil }

        let isCharging = props["IsCharging"] as? Bool ?? false
        let isPluggedIn = props["ExternalConnected"] as? Bool ?? false

        // Percent: prefer the gauge's own figure, else derive it from capacities.
        let percent: Double
        if let current = props["CurrentCapacity"] as? Double, let max = props["MaxCapacity"] as? Double, max > 0 {
            // MaxCapacity is 100 on Apple Silicon, making CurrentCapacity a percent already.
            percent = max == 100 ? current : current / max * 100
        } else {
            percent = 0
        }

        // Amperage is mA and Voltage mV, so their product is µW.
        var watts: Double?
        if let amperage = props["Amperage"] as? Double, let voltage = props["Voltage"] as? Double {
            let value = abs(amperage) * voltage / 1_000_000
            watts = value > 0.01 ? value : nil   // Idle battery: neither charging nor draining.
        }

        // 65535 is the gauge's "unknown" sentinel, seen while plugged in or still
        // settling after a state change.
        let rawMinutes = props[isCharging ? "AvgTimeToFull" : "AvgTimeToEmpty"] as? Int
        let minutesRemaining = (rawMinutes.map { $0 > 0 && $0 < 65535 } ?? false) ? rawMinutes : nil

        // The mAh figures behind the capacity row. NominalChargeCapacity is the
        // calibrated value System Information shows; AppleRawMaxCapacity is the
        // raw gauge estimate, which drifts by tens of mAh between samples, so
        // it's only a fallback for Macs that don't publish the nominal one.
        let designCapacity = props["DesignCapacity"] as? Double
        let maxCapacity = (props["NominalChargeCapacity"] as? Double)
            ?? (props["AppleRawMaxCapacity"] as? Double)

        // Health comes from macOS, not from the ratio of those two: powerd rounds
        // and smooths its estimate, so dividing them here lands a point or so off
        // what the user sees in System Information. Nil until the first reading
        // lands, a moment after launch — the row shows "—" rather than flashing a
        // derived figure that then corrects itself.
        let healthPercent = healthReporter.healthPercent()

        return BatterySample(percent: percent,
                             isCharging: isCharging,
                             isPluggedIn: isPluggedIn,
                             watts: watts,
                             minutesRemaining: minutesRemaining,
                             cycleCount: props["CycleCount"] as? Int,
                             healthPercent: healthPercent,
                             maxCapacitymAh: maxCapacity,
                             designCapacitymAh: designCapacity)
    }
}
