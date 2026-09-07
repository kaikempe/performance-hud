import Foundation

/// Debug helper: prints every temperature sensor and fan the machine exposes,
/// so we can identify which names to surface / aggregate. Cross-check the values
/// against the Macs Fan Control window. Run: PerformanceHUD --dump-sensors
enum SensorDump {
    /// `String(format:)` silently ignores field widths on `%@`, so pad by hand.
    private static func pad(_ text: String, _ width: Int) -> String {
        text + String(repeating: " ", count: max(0, width - text.count))
    }

    private static func padLeading(_ text: String, _ width: Int) -> String {
        String(repeating: " ", count: max(0, width - text.count)) + text
    }

    static func run() {
        let thermal = ThermalSensors().sample()

        print("=== Temperature sensors (°C) ===")
        if thermal.temperatures.isEmpty {
            print("  (none found — IOHID thermal hub returned nothing)")
        }
        for (name, value) in thermal.temperatures.sorted(by: { $0.key < $1.key }) {
            print(String(format: "  %@ %6.2f", pad(name, 28), value))
        }

        print("\n=== Fans (RPM) ===")
        if thermal.fans.isEmpty {
            print("  (none found — no fans or SMC unavailable)")
        }
        for (name, value) in thermal.fans.sorted(by: { $0.key < $1.key }) {
            print(String(format: "  %@ %6.0f", pad(name, 10), value))
        }

        // Per-block watts are a delta between samples, so prime and re-read.
        let powerReader = PowerUsage()
        _ = powerReader.sample()
        Thread.sleep(forTimeInterval: 1.0)
        let power = powerReader.sample()
        print("\n=== Power (W) ===")
        print("  In (adapter):    \(Format.watts(power.inputWatts))")
        print("  System draw:     \(Format.watts(power.systemWatts))")
        func line(_ label: String, _ watts: Double?) {
            print("    \(pad(label, 18))\(padLeading(Format.wattsPrecise(watts), 8))")
        }
        line("CPU", power.cpuWatts)
        line("GPU", power.gpuWatts)
        line("Neural Engine", power.aneWatts)
        line("DRAM", power.dramWatts)
        for block in power.secondaryBlocks { line(block.label, block.watts) }
        line("Not metered", power.unmeteredWatts)
        print("    (not metered = backlight, SSD, Wi-Fi, USB devices, regulator losses)")

        let disk = DiskUsage()
        _ = disk.sample()
        Thread.sleep(forTimeInterval: 1.0)
        let diskSample = disk.sample()
        print("\n=== Disk (1s sample) ===")
        print("  Read:  \(Format.rate(diskSample.readBytesPerSec))")
        print("  Write: \(Format.rate(diskSample.writeBytesPerSec))")

        print("\n=== Battery ===")
        let batteryReader = BatteryUsage()
        batteryReader.primeHealth()   // One-shot dump: no later tick to catch up on.
        if let battery = batteryReader.sample() {
            print(String(format: "  Charge:  %.0f%%", battery.percent))
            print("  State:   \(battery.isCharging ? "charging" : (battery.isPluggedIn ? "plugged in, not charging" : "on battery"))")
            print("  Rate:    \(Format.watts(battery.watts))")
            print("  Left:    \(battery.minutesRemaining.map { Format.duration(minutes: $0) } ?? "—")")
            print("  Health:  \(battery.healthPercent.map { String(format: "%.0f%%", $0) } ?? "—")")
            print("  Capacity: \(battery.maxCapacitymAh.map { String(format: "%.0f", $0) } ?? "—") / \(battery.designCapacitymAh.map { String(format: "%.0f", $0) } ?? "—") mAh")
            print("  Cycles:  \(battery.cycleCount.map(String.init) ?? "—")")
        } else {
            print("  (no battery — desktop Mac)")
        }

        let clocks = ClockUsage()
        let procs = ProcessUsage()
        _ = clocks.sample()
        _ = procs.sample()
        Thread.sleep(forTimeInterval: 1.0)
        let clockSample = clocks.sample()
        print("\n=== Clocks (DVFS residency) ===")
        for cluster in clockSample.cpu {
            print(String(format: "  %@ (%d cores): clock %.0f%% of max, active %.0f%%",
                         pad(cluster.label, 16), cluster.coreCount,
                         cluster.clockPercent, cluster.activePercent))
        }
        if let gpuClock = clockSample.gpu {
            print(String(format: "  %@          clock %.0f%% of max, active %.0f%%",
                         pad(gpuClock.label, 16), gpuClock.clockPercent, gpuClock.activePercent))
        }

        let gpuDetail = GPUUsage().sample()
        print("\n=== GPU ===")
        print(String(format: "  Utilization: %.0f%%  (tiler %@, renderer %@)",
                     gpuDetail.utilization,
                     gpuDetail.tilerPercent.map { String(format: "%.0f%%", $0) } ?? "—",
                     gpuDetail.rendererPercent.map { String(format: "%.0f%%", $0) } ?? "—"))
        print("  Memory in use: \(gpuDetail.inUseBytes.map { Format.bytes($0) } ?? "—")")
        print("  Memory alloc:  \(gpuDetail.allocatedBytes.map { Format.bytes($0) } ?? "—")")

        print("\n=== Top processes by CPU ===")
        let top = procs.sample()
        if top.isEmpty { print("  (nothing above 0.5%)") }
        for p in top {
            print(String(format: "  %@ %6.1f%%  pid %d", pad(p.name, 24), p.cpuPercent, p.pid))
        }

        print("\n=== Thermal pressure ===")
        let pressure: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: pressure = "nominal (not throttling)"
        case .fair: pressure = "fair"
        case .serious: pressure = "serious (throttling)"
        case .critical: pressure = "critical"
        @unknown default: pressure = "unknown"
        }
        print("  \(pressure)")

        print("\n=== Aggregates ===")
        func temp(_ v: Double?) -> String { v.map { String(format: "%.1f°C", $0) } ?? "—" }
        print("  CPU cores:  \(thermal.cpuCoreTemps.count) sensors, max \(temp(thermal.hottestCPUCore)), avg \(temp(thermal.averageCPUCore))")
        print("  GPU:        \(thermal.gpuTemps.count) sensors, max \(temp(thermal.hottestGPU)), avg \(temp(thermal.averageGPU))")
        print("  IOHID die:  avg \(temp(thermal.dieAverage))  (die-area sensors, read ~15-20°C low)")
        print("  Hottest:    \(temp(thermal.hottest))")

        // Validate the CPU/GPU/memory/network readers with a 1s delta.
        let cpu = CPUUsage(), gpu = GPUUsage(), mem = MemoryUsage(), net = NetworkUsage()
        _ = cpu.sample(); _ = net.sample()
        Thread.sleep(forTimeInterval: 1.0)
        let memSample = mem.sample()
        let netSample = net.sample()
        print("\n=== System (1s sample) ===")
        print(String(format: "  CPU:     %.1f%%", cpu.sample()))
        print(String(format: "  GPU:     %.1f%%", gpu.sample().utilization))
        print(String(format: "  Memory:  %.1f / %.0f GB (%.0f%%)",
                     memSample.usedGB, memSample.totalGB, memSample.percent))
        print(String(format: "    compressed %.2f GB · swap %.2f GB of %.2f GB · pressure %@",
                     memSample.compressedGB, memSample.swapUsedGB,
                     Double(memSample.swapTotalBytes) / 1_073_741_824,
                     memSample.pressure.label))
        print("  Network: ↓\(Format.rate(netSample.downBytesPerSec))  ↑\(Format.rate(netSample.upBytesPerSec))")
    }

    /// Times every reader. This app's whole job is to be invisible, and the
    /// readers differ by three orders of magnitude in cost — the thermal sweep
    /// alone once outweighed everything else put together — so the numbers that
    /// decide how often each one is polled need to be measurable, not guessed.
    /// Run: PerformanceHUD --bench
    static func bench() {
        let cpu = CPUUsage(), gpu = GPUUsage(), mem = MemoryUsage(), net = NetworkUsage()
        let thermal = ThermalSensors(), power = PowerUsage(), disk = DiskUsage()
        let battery = BatteryUsage(), clocks = ClockUsage(), processes = ProcessUsage()

        // Prime the delta-based readers; several do real work only on their
        // second call, which would otherwise read as free.
        _ = cpu.sample(); _ = net.sample(); _ = disk.sample()
        _ = clocks.sample(); _ = processes.sample(); _ = power.sample()

        let cases: [(String, Int, () -> Void)] = [
            ("cpu", 50, { _ = cpu.sample() }),
            ("gpu", 50, { _ = gpu.sample() }),
            ("memory", 50, { _ = mem.sample() }),
            ("network", 50, { _ = net.sample() }),
            ("disk", 50, { _ = disk.sample() }),
            ("battery", 50, { _ = battery.sample() }),
            ("clocks", 50, { _ = clocks.sample() }),
            ("power", 50, { _ = power.sample() }),
            ("processes", 20, { _ = processes.sample() }),
            ("thermal (total)", 20, { _ = thermal.sample() }),
        ]

        print("=== Reader cost (ms per sample) ===")
        var total = 0.0
        for (name, iterations, body) in cases {
            var wall = 0.0, cpuTime = 0.0
            for _ in 0..<iterations {
                let w0 = Date(), c0 = processCPUSeconds()
                body()
                wall += -w0.timeIntervalSinceNow
                cpuTime += processCPUSeconds() - c0
            }
            let perCall = wall / Double(iterations) * 1000
            total += perCall
            print(String(format: "  %@ %7.3f ms wall  %7.3f ms cpu",
                         pad(name, 18), perCall, cpuTime / Double(iterations) * 1000))
        }
        print(String(format: "  %@ %7.3f ms wall", pad("all readers", 18), total))
    }

    /// User + system CPU time consumed by this process so far, in seconds.
    private static func processCPUSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
        return user + system
    }
}
