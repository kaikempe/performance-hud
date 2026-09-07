import Foundation
import SensorBridge

/// One metered SoC block, ready for display.
struct PowerBlock: Identifiable {
    let id: String
    let label: String
    let watts: Double
}

struct PowerSample {
    /// Watts arriving from the adapter — 0 when running on battery, nil on Macs
    /// that don't expose the sensor.
    let inputWatts: Double?
    /// Watts the machine is currently drawing, nil if unsupported.
    let systemWatts: Double?
    /// Per-block SoC draw, keyed as `PHUDSoCPowerReader` documents. Empty when
    /// IOReport is unavailable.
    let blocks: [String: Double]

    static let unavailable = PowerSample(inputWatts: nil, systemWatts: nil, blocks: [:])

    // The four headline blocks, shown in the always-visible summary.
    var cpuWatts: Double? { blocks["cpu"] }
    var gpuWatts: Double? { blocks["gpu"] }
    var aneWatts: Double? { blocks["ane"] }
    var dramWatts: Double? { blocks["dram"] }

    /// The headline blocks, summed — nil if none of them are readable.
    var headlineWatts: Double? {
        let parts = [cpuWatts, gpuWatts, aneWatts, dramWatts].compactMap { $0 }
        return parts.isEmpty ? nil : parts.reduce(0, +)
    }

    /// System draw minus the headline blocks. This is what the summary row calls
    /// "Other", and the hover card itemises: partly further SoC blocks that *are*
    /// metered (memory controller, fabric, display engine …), partly hardware the
    /// Mac never meters at all.
    var otherWatts: Double? {
        guard let systemWatts, let headlineWatts else { return nil }
        return max(0, systemWatts - headlineWatts)
    }

    /// Every block the SoC meters, summed.
    var meteredWatts: Double { blocks.values.reduce(0, +) }

    /// What no counter accounts for: screen backlight, SSD, Wi-Fi, speakers,
    /// charging USB devices, and regulator conversion losses. A remainder, not a
    /// measurement.
    var unmeteredWatts: Double? {
        guard let systemWatts, !blocks.isEmpty else { return nil }
        return max(0, systemWatts - meteredWatts)
    }

    /// The non-headline metered blocks, in a fixed display order — fixed rather
    /// than sorted by size so rows don't swap places while you're reading them.
    var secondaryBlocks: [PowerBlock] {
        Self.secondaryOrder.compactMap { key, label in
            blocks[key].map { PowerBlock(id: key, label: label, watts: $0) }
        }
    }

    /// MSR and AFR keep Apple's raw acronyms — see `PHUDSoCBucketForChannel`.
    private static let secondaryOrder: [(String, String)] = [
        ("dramController", "DRAM controller"),
        ("systemCache", "System cache"),
        ("fabric", "SoC fabric"),
        ("displayEngine", "Display engine"),
        ("displayExternal", "External display"),
        ("isp", "Camera ISP"),
        ("videoEncoder", "Video encoder"),
        ("msr", "MSR"),
        ("afr", "AFR"),
        ("pcie", "PCIe"),
    ]
}

/// Reads adapter input and total system draw (SMC PDTR / PSTR) plus the
/// per-block SoC breakdown (IOReport "Energy Model").
final class PowerUsage {
    // Watts are a delta between samples, so the reader has to persist.
    private let socReader = PHUDSoCPowerReader()

    func sample() -> PowerSample {
        let rails = PHUDReadPower()
        let soc = socReader.sample().mapValues { $0.doubleValue }
        return PowerSample(inputWatts: rails["in"]?.doubleValue,
                           systemWatts: rails["system"]?.doubleValue,
                           blocks: soc)
    }
}
