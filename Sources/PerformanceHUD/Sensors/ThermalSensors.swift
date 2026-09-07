import Foundation
import SensorBridge

struct ThermalSample {
    /// Raw sensor name (from the IOHID hub) → temperature in °C. These are
    /// die-*area* sensors; see `cpuCoreTemps` for the ones that matter.
    let temperatures: [String: Double]
    /// Fan label → RPM.
    let fans: [String: Double]
    /// Per-CPU-core temperatures in °C, from the SMC.
    let cpuCoreTemps: [Double]
    /// Per-GPU temperatures in °C, from the SMC.
    let gpuTemps: [Double]

    static let empty = ThermalSample(temperatures: [:], fans: [:], cpuCoreTemps: [], gpuTemps: [])

    var hottestCPUCore: Double? { cpuCoreTemps.max() }
    var averageCPUCore: Double? { Self.mean(cpuCoreTemps) }
    var hottestGPU: Double? { gpuTemps.max() }
    var averageGPU: Double? { Self.mean(gpuTemps) }

    /// The IOHID hub's generic die sensors ("PMU tdieN"), averaged.
    var dieAverage: Double? { average(matching: ["tdie", "tcal"]) }

    /// Hottest reading anywhere — what actually drives thermal throttling. Uses
    /// the SMC core sensors when available and only falls back to the IOHID die
    /// sensors, which read 15–20 °C low, if the SMC is unreachable.
    var hottest: Double? {
        let core = [hottestCPUCore, hottestGPU].compactMap { $0 }.max()
        return core ?? temperatures.values.max()
    }

    private static func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private func average(matching keys: [String]) -> Double? {
        let values = temperatures
            .filter { entry in keys.contains { entry.key.localizedCaseInsensitiveContains($0) } }
            .map(\.value)
        return Self.mean(values)
    }
}

/// Reads temperatures (SMC per-core sensors + the IOHID thermal hub) and fan RPM
/// via the SensorBridge.
final class ThermalSensors {
    // Enumerates the SMC key list once, so hold onto it.
    private let temperatureReader = PHUDTemperatureReader()

    func sample() -> ThermalSample {
        var temps: [String: Double] = [:]
        for (key, value) in PHUDReadTemperatureSensors() {
            temps[key] = value.doubleValue
        }
        var fans: [String: Double] = [:]
        for (key, value) in PHUDReadFanSpeeds() {
            fans[key] = value.doubleValue
        }
        return ThermalSample(temperatures: temps,
                             fans: fans,
                             cpuCoreTemps: temperatureReader.cpuCoreTemperatures().map(\.doubleValue),
                             gpuTemps: temperatureReader.gpuTemperatures().map(\.doubleValue))
    }
}
