import Foundation
import Combine

/// How much of the sensor set the UI actually needs right now.
///
/// The readers are wildly uneven in cost: everything except the thermal sweep and
/// the per-process sweep together costs well under a millisecond, while the
/// thermal sweep alone is ~110 SMC key reads plus a round trip per IOHID sensor.
/// A menu bar showing "C 12%" reads none of that, so polling it at 1 Hz burned
/// several percent of a core around the clock. Demand decides who pays.
enum SensorDemand: Int, Comparable {
    /// Only the menu-bar label is on screen. It shows CPU/GPU/RAM/power and the
    /// throttle flag — none of which touch the expensive readers.
    case menuBar
    /// The floating overlay is up; it can show the hottest temperature.
    case overlay
    /// The dropdown panel is open, so everything is visible.
    case panel

    static func < (lhs: SensorDemand, rhs: SensorDemand) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Seconds between thermal sweeps. Die temperatures move over seconds, not
    /// frames, so even the open panel loses nothing by not sampling every tick —
    /// but it stays closest to live, since it's only open for a moment.
    var thermalInterval: TimeInterval {
        switch self {
        case .menuBar: return 15
        case .overlay: return 5
        case .panel: return 1
        }
    }

    /// The top-process list appears only in the panel, so nothing else pays for
    /// the ~750 `proc_pid_rusage` calls it takes to build.
    var samplesProcesses: Bool { self == .panel }

    /// So is the DVFS residency ladder, and reading it is one of the two most
    /// expensive things left once the thermal sweep is under control.
    var samplesClocks: Bool { self == .panel }

    /// Seconds between power samples. Watts reach the screen only in the panel or
    /// via the optional menu-bar readout, but `ThrottleDetector` needs a running
    /// series to recognise power limiting when it happens, so this slows down
    /// rather than stopping — a 180 s window still holds ~36 samples.
    var powerInterval: TimeInterval { self == .panel ? 0 : 5 }
}

/// Central poller. Samples every sensor on a timer and publishes values +
/// rolling history for the UI. Runs on the main actor since it drives SwiftUI.
@MainActor
final class SystemMonitor: ObservableObject {
    @Published private(set) var cpu: Double = 0
    @Published private(set) var gpu: Double = 0
    @Published private(set) var gpuDetail = GPUSample.zero
    @Published private(set) var cpuClocks: [ClockSample] = []
    @Published private(set) var gpuClock: ClockSample?
    @Published private(set) var topProcesses: [ProcessSample] = []
    @Published private(set) var memory = MemorySample.empty(total: ProcessInfo.processInfo.physicalMemory)
    @Published private(set) var network = NetworkSample(downBytesPerSec: 0, upBytesPerSec: 0)
    @Published private(set) var thermal = ThermalSample.empty
    /// Set when the machine is loaded but drawing well under its recent peak.
    @Published private(set) var isPowerLimited = false
    @Published private(set) var powerPeakWatts: Double?
    @Published private(set) var power = PowerSample.unavailable
    @Published private(set) var disk = DiskSample.zero
    @Published private(set) var battery: BatterySample?
    /// macOS's own throttling signal. Anything but `.nominal` means the system is
    /// actively backing off to shed heat — the thing that silently costs you FPS.
    @Published private(set) var thermalPressure: ProcessInfo.ThermalState = .nominal

    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var gpuHistory: [Double] = []
    @Published private(set) var memHistory: [Double] = []
    @Published private(set) var tempHistory: [Double] = []
    @Published private(set) var powerHistory: [Double] = []

    private let sensors: SensorSet
    private let throttleDetector = ThrottleDetector()

    /// Drives the menu-bar label. Kept separate from this object's own published
    /// values so the label only redraws when its text changes — see `MenuBarText`.
    let menuBar = MenuBarText()

    private var timer: Timer?
    private let historyLength = 60
    /// Longest gap after which the per-block power delta still describes "now".
    private static let maxUsefulPowerGap: TimeInterval = 10

    private var panelVisible = false
    private var overlayVisible = false
    private var lastThermalSample = Date.distantPast
    private var lastPowerSample = Date.distantPast
    /// Watts in the menu bar are opt-in, and they have to stay live when they're
    /// on — the one case where a closed panel still justifies polling power.
    private var showsPowerInMenuBar = false
    private var clocksArePrimed = false
    /// Tracked so the timer can be rebuilt when the machine is plugged or unplugged.
    private var wasOnBattery: Bool?

    /// What the UI needs right now — the highest demand of anything on screen.
    private var demand: SensorDemand {
        if panelVisible { return .panel }
        if overlayVisible { return .overlay }
        return .menuBar
    }

    /// Seconds between samples, as configured. Changing it restarts the timer.
    var interval: TimeInterval = 1.0 {
        didSet { if timer != nil && interval != oldValue { start() } }
    }

    /// Halve the rate on battery. Nothing here is worth a shorter runtime.
    var batterySaver = true {
        didSet { if timer != nil && batterySaver != oldValue { start() } }
    }

    private var onBattery: Bool { battery.map { !$0.isPluggedIn } ?? false }

    /// What the timer actually runs at, after the battery-saver adjustment.
    private var effectiveInterval: TimeInterval {
        batterySaver && onBattery ? interval * 2 : interval
    }

    /// `autoStart: false` is for tests: no timer, no `UserDefaults` observer, and
    /// the caller drives `tick(now:)` itself.
    init(sensors: SensorSet = .live(), autoStart: Bool = true) {
        self.sensors = sensors
        guard autoStart else { return }
        loadSettings()
        // The monitor lives as long as the app, so this observer is never removed.
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.loadSettings() }
        }
        start()
    }

    private func loadSettings() {
        // Before the interval assignments below, which can restart the timer and
        // tick straight into a label update.
        menuBar.refreshSettings()
        menuBar.update(from: self)

        let stored = UserDefaults.standard.double(forKey: SettingsKey.refreshInterval)
        interval = stored > 0 ? stored : 1.0
        // `bool(forKey:)` reads false for an unset key, so store the inverse and
        // let the default fall out as "on".
        batterySaver = !UserDefaults.standard.bool(forKey: SettingsKey.batterySaver)
        showsPowerInMenuBar = UserDefaults.standard.bool(forKey: SettingsKey.mbPower)
    }

    func start() {
        stop()
        // Prime delta-based readers so the first visible tick is meaningful.
        let primedAt = Date()
        _ = sensors.cpu.sample()
        _ = sensors.network.sample(now: primedAt)
        _ = sensors.disk.sample(now: primedAt)
        _ = sensors.clocks.sample()
        _ = sensors.processes.sample(count: 5, now: primedAt)

        // Read before scheduling: the power source decides the rate below.
        battery = sensors.battery.sample()
        wasOnBattery = onBattery

        let t = Timer(timeInterval: effectiveInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // Sampling is a background chore, not an animation — letting macOS group
        // these wakeups with other timers keeps the CPU asleep longer.
        t.tolerance = effectiveInterval * 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Called as the dropdown panel opens and closes.
    func setPanelVisible(_ visible: Bool) {
        guard panelVisible != visible else { return }
        panelVisible = visible
        demandDidChange()
    }

    /// Called as the floating overlay is shown and hidden.
    func setOverlayVisible(_ visible: Bool) {
        guard overlayVisible != visible else { return }
        overlayVisible = visible
        demandDidChange()
    }

    /// Something appeared or went away. Refresh right now so a newly-opened panel
    /// shows live numbers instead of whatever the slow cadence last left behind.
    private func demandDidChange() {
        if !demand.samplesProcesses { topProcesses = [] }
        tick()
    }

    /// One sampling pass. Internal, with an injectable clock, so tests can step it.
    func tick(now: Date = Date()) {
        let demand = self.demand

        // The cheap readers — a millisecond between the lot of them.
        cpu = sensors.cpu.sample()
        gpuDetail = sensors.gpu.sample()
        gpu = gpuDetail.utilization
        memory = sensors.memory.sample()
        network = sensors.network.sample(now: now)
        disk = sensors.disk.sample(now: now)
        battery = sensors.battery.sample()
        thermalPressure = ProcessInfo.processInfo.thermalState

        // The expensive ones, at whatever rate the visible UI justifies. The 10%
        // slack keeps a sweep from being pushed a whole period late by timer
        // jitter when the deadline lands just short.
        if now.timeIntervalSince(lastThermalSample) >= demand.thermalInterval * 0.9 {
            thermal = sensors.thermal.sample()
            lastThermalSample = now
        }
        // Watts reach the screen only in the panel or the optional menu-bar
        // readout. The one other consumer is ThrottleDetector, which throws away
        // everything it is handed below its load threshold — so an idle machine
        // with the panel shut reads no power at all.
        let load = max(cpu, gpuDetail.utilization)
        let wantsPower = demand == .panel || showsPowerInMenuBar
            || load >= ThrottleDetector.loadThreshold
        var sampledPower = false
        if wantsPower, now.timeIntervalSince(lastPowerSample) >= demand.powerInterval * 0.9 {
            let gap = now.timeIntervalSince(lastPowerSample)
            let sample = sensors.power.sample()
            // The per-block figures are an energy delta since the previous call,
            // so the first read after a pause describes the whole gap. The SMC
            // rails are instantaneous and stay valid — and they are what the
            // throttle detector reads — so keep those and drop the breakdown.
            power = gap > Self.maxUsefulPowerGap
                ? PowerSample(inputWatts: sample.inputWatts, systemWatts: sample.systemWatts, blocks: [:])
                : sample
            lastPowerSample = now
            sampledPower = true
        }
        if demand.samplesClocks {
            let clocks = sensors.clocks.sample()
            // Residency is a delta, so the first read after a pause describes the
            // whole gap — how the machine clocked while nobody was watching.
            // Treat it as the prime and publish from the next one on.
            if clocksArePrimed {
                cpuClocks = clocks.cpu
                gpuClock = clocks.gpu
            }
            clocksArePrimed = true
        } else if clocksArePrimed {
            clocksArePrimed = false
            cpuClocks = []
            gpuClock = nil
        }
        if demand.samplesProcesses {
            topProcesses = sensors.processes.sample(count: 5, now: now)
        }

        // Utilization of whichever engine is working hardest.
        throttleDetector.update(load: max(cpu, gpuDetail.utilization), watts: power.systemWatts, now: now)
        isPowerLimited = throttleDetector.isPowerLimited
        powerPeakWatts = throttleDetector.peakWatts

        menuBar.update(from: self)

        append(&cpuHistory, cpu)
        append(&gpuHistory, gpu)
        append(&memHistory, memory.percent)
        append(&tempHistory, thermal.hottest ?? 0)
        // The sparkline is the only thing that would keep reading watts after
        // sampling stops, and a line frozen at the last known value is worse than
        // no line — it fills back in from the moment the panel opens.
        if sampledPower {
            append(&powerHistory, power.systemWatts ?? 0)
        } else if !wantsPower && !powerHistory.isEmpty {
            powerHistory = []
        }

        // Plugging in or unplugging changes the rate the timer should run at, and
        // `battery` was only just read, so check it here rather than polling for
        // it. Rebuild on the next runloop pass, not from inside the timer's own
        // callback.
        if batterySaver, wasOnBattery != onBattery {
            wasOnBattery = onBattery
            DispatchQueue.main.async { [weak self] in self?.start() }
        }
    }

    private func append(_ array: inout [Double], _ value: Double) {
        array.append(value)
        if array.count > historyLength {
            array.removeFirst(array.count - historyLength)
        }
    }
}
