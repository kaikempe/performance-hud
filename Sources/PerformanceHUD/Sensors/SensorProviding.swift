import Foundation

// The seam between `SystemMonitor` and the hardware. Each reader sits behind one
// small protocol so tests can hand the monitor scripted values — a hot machine, a
// draining battery, an idle one — without touching IOKit, the SMC or `proc_*`.
//
// Only the boundary is abstracted: `ThrottleDetector` and the sample structs are
// plain logic and are tested as they are.

protocol CPUSampling { func sample() -> Double }
protocol GPUSampling { func sample() -> GPUSample }
protocol MemorySampling { func sample() -> MemorySample }
protocol NetworkSampling { func sample(now: Date) -> NetworkSample }
protocol DiskSampling { func sample(now: Date) -> DiskSample }
protocol BatterySampling { func sample() -> BatterySample? }
protocol ThermalSampling { func sample() -> ThermalSample }
protocol PowerSampling { func sample() -> PowerSample }
protocol ClockSampling { func sample() -> (cpu: [ClockSample], gpu: ClockSample?) }
protocol ProcessSampling { func sample(count: Int, now: Date) -> [ProcessSample] }

extension CPUUsage: CPUSampling {}
extension GPUUsage: GPUSampling {}
extension MemoryUsage: MemorySampling {}
extension NetworkUsage: NetworkSampling {}
extension DiskUsage: DiskSampling {}
extension BatteryUsage: BatterySampling {}
extension ThermalSensors: ThermalSampling {}
extension PowerUsage: PowerSampling {}
extension ClockUsage: ClockSampling {}
extension ProcessUsage: ProcessSampling {}

/// Everything `SystemMonitor` reads, bundled so one argument swaps the lot.
struct SensorSet {
    var cpu: any CPUSampling
    var gpu: any GPUSampling
    var memory: any MemorySampling
    var network: any NetworkSampling
    var disk: any DiskSampling
    var battery: any BatterySampling
    var thermal: any ThermalSampling
    var power: any PowerSampling
    var clocks: any ClockSampling
    var processes: any ProcessSampling

    /// The real hardware readers.
    static func live() -> SensorSet {
        SensorSet(
            cpu: CPUUsage(), gpu: GPUUsage(), memory: MemoryUsage(),
            network: NetworkUsage(), disk: DiskUsage(), battery: BatteryUsage(),
            thermal: ThermalSensors(), power: PowerUsage(), clocks: ClockUsage(),
            processes: ProcessUsage()
        )
    }
}
