import Testing
import Foundation
@testable import PerformanceHUD

@MainActor
@Suite("SystemMonitor")
struct SystemMonitorTests {
    let t0 = Date()

    @Test("Publishes what the sensors report")
    func publishes() {
        let rig = Rig(); rig.cpu.value = 42; rig.gpu.utilization = 17
        let m = rig.monitor()
        m.tick(now: t0)
        #expect(m.cpu == 42)
        #expect(m.gpu == 17)
        #expect(m.cpuHistory == [42])
    }

    @Test("With only the menu bar showing, the thermal sweep runs once per 15 s")
    func thermalIsRationed() {
        let rig = Rig(); let m = rig.monitor()
        for s in 0..<10 { m.tick(now: t0 + Double(s)) }
        #expect(rig.thermal.calls == 1)
        m.tick(now: t0 + 16)
        #expect(rig.thermal.calls == 2)
    }

    @Test("Processes and clocks are read only while the panel is open")
    func panelOnlyReaders() {
        let rig = Rig(); let m = rig.monitor()
        m.tick(now: t0)
        #expect(rig.processes.calls == 0)
        #expect(rig.clocks.calls == 0)

        m.setPanelVisible(true)           // ticks once on its own
        let processCalls = rig.processes.calls
        #expect(processCalls >= 1)
        #expect(rig.clocks.calls >= 1)

        m.setPanelVisible(false)
        m.tick(now: Date().addingTimeInterval(1))
        #expect(rig.processes.calls == processCalls)
        #expect(m.topProcesses.isEmpty)
    }

    @Test("Closing the panel clears the process list")
    func closingClears() {
        let rig = Rig()
        rig.processes.value = [ProcessSample(pid: 1, name: "a", cpuPercent: 10)]
        let m = rig.monitor()
        m.setPanelVisible(true)
        #expect(m.topProcesses.count == 1)
        m.setPanelVisible(false)
        #expect(m.topProcesses.isEmpty)
    }

    @Test("An idle machine with the panel shut reads no power")
    func idleSkipsPower() {
        let rig = Rig(); rig.cpu.value = 5
        let m = rig.monitor()
        for s in 0..<20 { m.tick(now: t0 + Double(s)) }
        #expect(rig.power.calls == 0)
        #expect(m.powerHistory.isEmpty)
    }

    @Test("Under heavy load power is sampled, and a drop flags power limiting")
    func loadedPowerLimit() {
        let rig = Rig(); rig.cpu.value = 95
        let m = rig.monitor()
        rig.power.systemWatts = 90
        m.tick(now: t0)
        rig.power.systemWatts = 55
        m.tick(now: t0 + 6)               // past the 5 s menu-bar power interval
        #expect(rig.power.calls == 2)
        #expect(m.isPowerLimited)
        #expect(m.powerPeakWatts == 90)
    }

    @Test("History is capped at 60 samples")
    func historyCap() {
        let rig = Rig(); let m = rig.monitor()
        for s in 0..<75 { rig.cpu.value = Double(s); m.tick(now: t0 + Double(s)) }
        #expect(m.cpuHistory.count == 60)
        #expect(m.cpuHistory.last == 74)
        #expect(m.cpuHistory.first == 15)
    }

    @Test("Battery and memory flow through to the suggestion state")
    func machineState() {
        let rig = Rig()
        rig.battery.value = makeBattery(percent: 12, pluggedIn: false)
        rig.memory.value = makeMemory(pressure: .critical)
        let m = rig.monitor(); m.tick(now: t0)
        let ids = SuggestionEngine.suggestions(for: m).map(\.id)
        #expect(ids.contains("memory"))
        #expect(ids.contains("battery"))
    }
}
