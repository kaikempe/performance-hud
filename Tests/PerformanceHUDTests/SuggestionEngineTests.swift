import Testing
@testable import PerformanceHUD

@Suite("SuggestionEngine")
struct SuggestionEngineTests {
    private func ids(_ state: MachineState) -> [String] {
        SuggestionEngine.suggestions(for: state).map(\.id)
    }

    @Test("A calm machine gets only the health check")
    func healthy() {
        #expect(ids(MachineState(memory: makeMemory())) == ["checkup"])
    }

    @Test("Memory pressure raises the memory suggestion")
    func memoryPressureRaisesMemory() {
        #expect(ids(MachineState(memory: makeMemory(pressure: .warning))) == ["memory"])
    }

    @Test("More than 2 GB of swap raises it even at normal pressure")
    func swapRaisesMemory() {
        #expect(ids(MachineState(memory: makeMemory(swapGB: 3))) == ["memory"])
        #expect(ids(MachineState(memory: makeMemory(swapGB: 1))) == ["checkup"])
    }

    @Test("Serious thermal state reads as throttling")
    func seriousThermal() {
        let s = SuggestionEngine.suggestions(for: MachineState(memory: makeMemory(), thermalPressure: .serious))
        #expect(s.map(\.id) == ["thermal"])
        #expect(s[0].title == "Running hot, throttling")
    }

    @Test("Power limiting alone raises the thermal suggestion, worded differently")
    func powerLimited() {
        let s = SuggestionEngine.suggestions(for: MachineState(memory: makeMemory(), isPowerLimited: true))
        #expect(s.map(\.id) == ["thermal"])
        #expect(s[0].title == "Power limited under load")
    }

    @Test("Pinned CPU names the busiest processes")
    func pinnedCPU() {
        let procs = [ProcessSample(pid: 1, name: "Xcode", cpuPercent: 300),
                     ProcessSample(pid: 2, name: "mds", cpuPercent: 90)]
        let s = SuggestionEngine.suggestions(for: MachineState(cpu: 92, memory: makeMemory(), topProcesses: procs))
        #expect(s.map(\.id) == ["cpu"])
        #expect(s[0].detail == "Busiest: Xcode, mds.")
    }

    @Test("Heat takes the place of the plain CPU suggestion")
    func heatBeatsCPU() {
        let state = MachineState(cpu: 95, memory: makeMemory(), thermalPressure: .critical)
        #expect(ids(state) == ["thermal"])
    }

    @Test("Low battery only matters when unplugged")
    func lowBattery() {
        #expect(ids(MachineState(memory: makeMemory(), battery: makeBattery(percent: 20, pluggedIn: false))) == ["battery"])
        #expect(ids(MachineState(memory: makeMemory(), battery: makeBattery(percent: 20, pluggedIn: true))) == ["checkup"])
        #expect(ids(MachineState(memory: makeMemory(), battery: makeBattery(percent: 60, pluggedIn: false))) == ["checkup"])
    }

    @Test("Every prompt tells Claude to look first and ask before changing anything")
    func guardrail() {
        let all = MachineState(cpu: 90, memory: makeMemory(pressure: .critical),
                               thermalPressure: .serious,
                               battery: makeBattery(percent: 10, pluggedIn: false))
        for s in SuggestionEngine.suggestions(for: all) {
            #expect(s.prompt.contains("read-only commands first"))
            #expect(s.prompt.contains("Ask me"))
        }
    }
}
