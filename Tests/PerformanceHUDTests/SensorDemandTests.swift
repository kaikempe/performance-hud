import Testing
@testable import PerformanceHUD

@Suite("SensorDemand")
struct SensorDemandTests {
    @Test("Demand orders menu bar < overlay < panel")
    func ordering() {
        #expect(SensorDemand.menuBar < .overlay)
        #expect(SensorDemand.overlay < .panel)
    }

    @Test("Thermal sweeps speed up as more UI is visible")
    func thermalIntervals() {
        #expect(SensorDemand.menuBar.thermalInterval == 15)
        #expect(SensorDemand.overlay.thermalInterval == 5)
        #expect(SensorDemand.panel.thermalInterval == 1)
    }

    @Test("Only the panel pays for processes and clocks")
    func panelOnly() {
        for d in [SensorDemand.menuBar, .overlay] {
            #expect(!d.samplesProcesses)
            #expect(!d.samplesClocks)
        }
        #expect(SensorDemand.panel.samplesProcesses)
        #expect(SensorDemand.panel.samplesClocks)
    }
}
