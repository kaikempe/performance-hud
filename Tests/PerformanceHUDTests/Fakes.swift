import Foundation
@testable import PerformanceHUD

/// Scripted stand-ins for the hardware readers. Each one returns whatever the
/// test last set and counts how often it was asked, which is how the tests
/// check that an expensive reader is left alone when nothing needs it.

final class FakeCPU: CPUSampling {
    var value = 0.0
    private(set) var calls = 0
    func sample() -> Double { calls += 1; return value }
}

final class FakeGPU: GPUSampling {
    var utilization = 0.0
    private(set) var calls = 0
    func sample() -> GPUSample {
        calls += 1
        return GPUSample(utilization: utilization, tilerPercent: nil, rendererPercent: nil,
                         inUseBytes: nil, allocatedBytes: nil)
    }
}

final class FakeMemory: MemorySampling {
    var value = MemorySample.empty(total: 16 << 30)
    func sample() -> MemorySample { value }
}

final class FakeNetwork: NetworkSampling {
    func sample(now: Date) -> NetworkSample { NetworkSample(downBytesPerSec: 0, upBytesPerSec: 0) }
}

final class FakeDisk: DiskSampling {
    func sample(now: Date) -> DiskSample { .zero }
}

final class FakeBattery: BatterySampling {
    var value: BatterySample?
    func sample() -> BatterySample? { value }
}

final class FakeThermal: ThermalSampling {
    var value = ThermalSample.empty
    private(set) var calls = 0
    func sample() -> ThermalSample { calls += 1; return value }
}

final class FakePower: PowerSampling {
    var systemWatts: Double? = nil
    private(set) var calls = 0
    func sample() -> PowerSample {
        calls += 1
        return PowerSample(inputWatts: nil, systemWatts: systemWatts, blocks: [:])
    }
}

final class FakeClocks: ClockSampling {
    private(set) var calls = 0
    func sample() -> (cpu: [ClockSample], gpu: ClockSample?) { calls += 1; return ([], nil) }
}

final class FakeProcesses: ProcessSampling {
    var value: [ProcessSample] = []
    private(set) var calls = 0
    func sample(count: Int, now: Date) -> [ProcessSample] { calls += 1; return value }
}

/// All ten fakes plus the `SensorSet` that wires them in.
struct Rig {
    let cpu = FakeCPU(), gpu = FakeGPU(), memory = FakeMemory(), network = FakeNetwork()
    let disk = FakeDisk(), battery = FakeBattery(), thermal = FakeThermal()
    let power = FakePower(), clocks = FakeClocks(), processes = FakeProcesses()

    var sensors: SensorSet {
        SensorSet(cpu: cpu, gpu: gpu, memory: memory, network: network, disk: disk,
                  battery: battery, thermal: thermal, power: power, clocks: clocks,
                  processes: processes)
    }

    @MainActor
    func monitor() -> SystemMonitor { SystemMonitor(sensors: sensors, autoStart: false) }
}

func makeMemory(pressure: MemoryPressure = .normal, swapGB: Double = 0) -> MemorySample {
    MemorySample(usedBytes: 8 << 30, totalBytes: 16 << 30, compressedBytes: 0,
                 swapUsedBytes: UInt64(swapGB * 1_073_741_824), swapTotalBytes: 0,
                 pressure: pressure)
}

func makeBattery(percent: Double, pluggedIn: Bool) -> BatterySample {
    BatterySample(percent: percent, isCharging: false, isPluggedIn: pluggedIn, watts: nil,
                  minutesRemaining: nil, cycleCount: nil, healthPercent: nil,
                  maxCapacitymAh: nil, designCapacitymAh: nil)
}
