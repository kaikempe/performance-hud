import SwiftUI
import AppKit
import Combine

/// Relays the monitor's updates to the panel, but only while the panel is on
/// screen.
///
/// SwiftUI keeps a `MenuBarExtra`'s content view alive after its window closes,
/// and every published sample then drives a full AppKit layout pass over the
/// whole hidden tree — measured at ~1% of a core here, more than all the sensors
/// put together, for a view nobody can see. So the panel reads the monitor
/// without subscribing to it and takes its refreshes from this instead.
@MainActor
final class PanelRefresh: ObservableObject {
    private var subscription: AnyCancellable?

    func setActive(_ active: Bool, monitor: SystemMonitor) {
        subscription = active
            ? monitor.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            : nil
    }
}

/// The dropdown panel: live sensor rows, the Metal HUD toggle, and controls.
struct StatsPanelView: View {
    /// Deliberately not `@ObservedObject` — see `PanelRefresh`.
    let monitor: SystemMonitor
    @ObservedObject var hud: MetalHUDController
    @ObservedObject var overlay: OverlayController
    @ObservedObject var menuBarVisibility: MenuBarVisibilityController
    @ObservedObject var loginItem: LoginItemController

    @StateObject private var refresh = PanelRefresh()

    @AppStorage(SettingsKey.mbCPU) private var mbCPU = true
    @AppStorage(SettingsKey.mbGPU) private var mbGPU = true
    @AppStorage(SettingsKey.mbRAM) private var mbRAM = false
    @AppStorage(SettingsKey.mbRAMasGB) private var mbRAMasGB = false
    @AppStorage(SettingsKey.mbPower) private var mbPower = false
    @AppStorage(SettingsKey.mbThrottle) private var mbThrottle = true

    @AppStorage(SettingsKey.ovCPU) private var ovCPU = true
    @AppStorage(SettingsKey.ovGPU) private var ovGPU = true
    @AppStorage(SettingsKey.ovRAM) private var ovRAM = true
    @AppStorage(SettingsKey.ovTemp) private var ovTemp = true
    @AppStorage(SettingsKey.ovNet) private var ovNet = true

    @AppStorage(SettingsKey.refreshInterval) private var refreshInterval = 1.0
    @AppStorage(SettingsKey.batterySaver) private var batterySaverOff = false

    @State private var showPowerDetail = false
    @State private var showProcessDetail = false
    @State private var showBatteryDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Performance HUD")
                .font(.system(size: 14, weight: .semibold))
                .tracking(-0.1)

            Divider()

            // Above the sections below it, so the power hover card floats over
            // them instead of being painted over by later siblings.
            metrics.zIndex(1)

            Divider()

            suggestionsSection

            Divider()

            overlaySection

            Divider()

            metalHUDSection

            Divider()

            menuBarSection

            Divider()

            fullScreenMenuBarSection

            Divider()

            loginItemSection

            Divider()

            samplingSection

            Divider()

            HStack {
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("⌘Q")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .frame(width: 300)
        // Everything in here reads the expensive sensors, and redrawing it is
        // expensive in its own right. Both stop while the panel is closed.
        .onAppear {
            refresh.setActive(true, monitor: monitor)
            monitor.setPanelVisible(true)
        }
        .onDisappear {
            refresh.setActive(false, monitor: monitor)
            monitor.setPanelVisible(false)
        }
    }

    private var metrics: some View {
        VStack(spacing: 10) {
            cpuSection.zIndex(2)
            gpuSection
            memorySection
            tempSection
            powerSection.zIndex(1)

            VStack(spacing: 4) {
                HStack {
                    Label(fanSummary, systemImage: "fan")
                    Spacer()
                    Label(netSummary, systemImage: "arrow.up.arrow.down")
                }
                HStack {
                    Label(diskSummary, systemImage: "internaldrive")
                    Spacer()
                    if let battery = monitor.battery {
                        Label(batterySummary(battery), systemImage: batteryIcon(battery))
                            .hoverCard(isShown: $showBatteryDetail, enabled: true,
                                       alignment: .topTrailing) { batteryCard(battery) }
                    }
                }
            }
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    /// Temp row. The headline is the hottest *core*, not the die-area average —
    /// the SMC core sensors run 15–20 °C above the IOHID ones and are what the
    /// throttle point actually tracks.
    private var tempSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            StatRow(title: "Temp", value: Format.temp(monitor.thermal.hottest),
                    history: monitor.tempHistory, maxValue: 110, color: .orange,
                    badge: thermalBadge?.label,
                    badgeColor: thermalBadge?.color ?? .orange,
                    badgeHelp: thermalBadge?.help)
            HStack(spacing: 10) {
                if let cpu = monitor.thermal.hottestCPUCore, let cpuAvg = monitor.thermal.averageCPUCore {
                    Text("CPU \(Int(cpu))° max · \(Int(cpuAvg))° avg")
                }
                if let gpu = monitor.thermal.hottestGPU {
                    Text("GPU \(Int(gpu))°")
                }
                Spacer()
            }
            .font(.system(size: 10).monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    /// CPU row, per-cluster clock speeds, and the busiest processes on hover.
    private var cpuSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            StatRow(title: "CPU", value: Format.percent(monitor.cpu),
                    history: monitor.cpuHistory, maxValue: 100, color: .blue)
            // One line per cluster: side by side these overflow 300pt and clip.
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(monitor.cpuClocks.enumerated()), id: \.element.id) { index, cluster in
                    HStack(spacing: 6) {
                        Text(cluster.label).frame(width: 74, alignment: .leading)
                        // Below ~10% busy the clock figure is race-to-idle noise:
                        // a core that wakes briefly runs flat out, reading 100%.
                        if cluster.activePercent < 10 {
                            Text("idle").foregroundStyle(.tertiary)
                        } else {
                            Text("\(Int(cluster.clockPercent))% clk · \(Int(cluster.activePercent))% busy")
                        }
                        Spacer()
                        if index == 0 {
                            Text("hover ⌄")
                                .foregroundStyle(.tertiary)
                                .opacity(showProcessDetail ? 0 : 1)
                        }
                    }
                }
            }
            .font(.system(size: 10).monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .hoverCard(isShown: $showProcessDetail, enabled: true) { processCard }
    }

    /// The closest honest answer to "what's using my CPU" — real percentages,
    /// but CPU time, not watts, and not every process is visible.
    private var processCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Busiest processes").font(.system(size: 10, weight: .semibold))

            if monitor.topProcesses.isEmpty {
                Text("Nothing above 0.5%")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
                    ForEach(monitor.topProcesses) { process in
                        GridRow {
                            Text(process.name).lineLimit(1).truncationMode(.middle)
                            Text(String(format: "%.0f%%", process.cpuPercent))
                                .gridColumnAlignment(.trailing)
                                .foregroundStyle(.secondary)
                        }
                        .font(.system(size: 10).monospacedDigit())
                    }
                }
            }

            Text("Percent of one core, so 400% means four cores saturated. System "
                 + "daemons owned by other users can't be read without root and are "
                 + "left out. This is CPU time — no Mac meters watts per process.")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .detailCardChrome()
    }

    /// GPU row, plus unified-memory use and how hard the GPU is clocking.
    private var gpuSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            StatRow(title: "GPU", value: Format.percent(monitor.gpu),
                    history: monitor.gpuHistory, maxValue: 100, color: .green)
            HStack(spacing: 10) {
                if let inUse = monitor.gpuDetail.inUseBytes {
                    // Allocated is the driver's high-water reservation, which for
                    // a game is the more telling half of the pair.
                    if let allocated = monitor.gpuDetail.allocatedBytes, allocated > inUse {
                        Text("\(Format.bytes(inUse)) of \(Format.bytes(allocated))")
                    } else {
                        Text("\(Format.bytes(inUse)) in use")
                    }
                }
                if let clock = monitor.gpuClock {
                    Text("\(Int(clock.clockPercent))% clk")
                }
                if let tiler = monitor.gpuDetail.tilerPercent,
                   let renderer = monitor.gpuDetail.rendererPercent {
                    Text("tile \(Int(tiler))% · rend \(Int(renderer))%")
                }
                Spacer()
            }
            .font(.system(size: 10).monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    /// Memory row, plus the two figures that actually say whether the machine is
    /// short of RAM. "Used" on its own does not: macOS fills memory on purpose
    /// and counts compressed pages as used, so a healthy Mac and a struggling
    /// one both sit near the top of the bar. Pressure and swap separate them.
    private var memorySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            StatRow(title: "Memory",
                    value: String(format: "%.1f / %.0f GB", monitor.memory.usedGB, monitor.memory.totalGB),
                    history: monitor.memHistory, maxValue: 100, color: .purple,
                    badge: memoryBadge?.label,
                    badgeColor: memoryBadge?.color ?? .yellow,
                    badgeHelp: memoryBadge?.help)
            HStack(spacing: 10) {
                if monitor.memory.compressedBytes > 0 {
                    Text("\(Format.bytes(Double(monitor.memory.compressedBytes))) compressed")
                }
                if monitor.memory.swapUsedBytes > 0 {
                    Text("\(Format.bytes(Double(monitor.memory.swapUsedBytes))) swap")
                        .foregroundStyle(monitor.memory.pressure == .normal ? AnyShapeStyle(.secondary)
                                                                            : AnyShapeStyle(Color.yellow))
                }
                Spacer()
            }
            .font(.system(size: 10).monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    /// Only shown when the kernel itself says memory is tight — the same 1/2/4
    /// level behind Activity Monitor's green / yellow / red bar.
    private var memoryBadge: (label: String, color: Color, help: String)? {
        switch monitor.memory.pressure {
        case .normal:
            return nil
        case .warning:
            return ("pressure", .yellow,
                    "The kernel is reclaiming memory: compressing pages and pushing them "
                    + "to swap. Apps still run, but allocation is costing time.")
        case .critical:
            return ("pressure critical", .red,
                    "The kernel is out of room to reclaim. Expect stalls, and apps being "
                    + "killed if it does not ease.")
        }
    }

    /// "38.2 W used · 48.1 W in" — the sparkline tracks the "used" figure.
    private var powerSummary: String {
        guard monitor.power.systemWatts != nil || monitor.power.inputWatts != nil else {
            return "—"
        }
        return "\(Format.watts(monitor.power.systemWatts)) used · \(Format.watts(monitor.power.inputWatts)) in"
    }

    /// The power row plus its summary. Hovering anywhere over it floats the full
    /// itemised card on top of the sections below — floating rather than inline
    /// so the panel doesn't jump around under the cursor.
    private var powerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            StatRow(title: "Power", value: powerSummary,
                    history: monitor.powerHistory, maxValue: powerScale, color: .teal)
            powerBreakdown
        }
        .hoverCard(isShown: $showPowerDetail, enabled: !monitor.power.blocks.isEmpty) {
            powerDetailCard
        }
    }

    /// Every watt the machine reports, reconciled against the system total. The
    /// itemised rows decompose the summary's "Other" — the metered SoC blocks
    /// first, then the remainder no counter accounts for.
    private var powerDetailCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Where the power goes")
                .font(.system(size: 10, weight: .semibold))

            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
                ForEach(headlineBlocks) { block in
                    detailRow(block.label, block.watts)
                }

                GridRow {
                    Text("Other, itemised")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 3)
                        .gridCellColumns(2)
                }

                ForEach(monitor.power.secondaryBlocks) { block in
                    detailRow(block.label, block.watts)
                }
                detailRow("Not metered", monitor.power.unmeteredWatts)

                GridRow {
                    Divider().gridCellColumns(2).padding(.vertical, 1)
                }
                detailRow("System total", monitor.power.systemWatts, bold: true)
            }

            Text("Not metered = screen backlight, SSD, Wi-Fi, speakers, charging USB "
                 + "devices and regulator losses. No Mac reports these individually, so "
                 + "it's the total minus everything above — a remainder, not a reading.")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .detailCardChrome()
    }

    private func detailRow(_ label: String, _ watts: Double?, bold: Bool = false) -> some View {
        GridRow {
            Text(label)
            Text(Format.wattsPrecise(watts))
                .gridColumnAlignment(.trailing)
                .foregroundStyle(bold ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        }
        .font(.system(size: 10, weight: bold ? .semibold : .regular).monospacedDigit())
    }

    /// The four headline blocks, skipping any this Mac doesn't report.
    private var headlineBlocks: [PowerBlock] {
        [("cpu", "CPU", monitor.power.cpuWatts),
         ("gpu", "GPU", monitor.power.gpuWatts),
         ("ane", "Neural Engine", monitor.power.aneWatts),
         ("dram", "DRAM", monitor.power.dramWatts)]
            .compactMap { id, label, watts in
                watts.map { PowerBlock(id: id, label: label, watts: $0) }
            }
    }

    /// Where the watts are going, for the parts the SoC actually meters. "Other"
    /// is the unmetered remainder, not a measurement — see `PowerSample`.
    @ViewBuilder private var powerBreakdown: some View {
        if monitor.power.headlineWatts != nil {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 2) {
                GridRow {
                    powerPart("CPU", monitor.power.cpuWatts)
                    powerPart("GPU", monitor.power.gpuWatts)
                    powerPart("ANE", monitor.power.aneWatts)
                }
                GridRow {
                    powerPart("RAM", monitor.power.dramWatts)
                    powerPart("Other", monitor.power.otherWatts)
                    // The hover card breaks "Other" down; hint that it's there.
                    Text("hover ⌄")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .opacity(showPowerDetail ? 0 : 1)
                }
            }
            .font(.system(size: 10).monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func powerPart(_ label: String, _ watts: Double?) -> some View {
        if let watts {
            Text("\(label) \(Format.watts(watts))")
        } else {
            Color.clear.frame(width: 0, height: 0)
        }
    }

    /// Sparkline ceiling: next 20 W step above the recent peak, so an idle
    /// machine doesn't get a flat line pinned to the bottom of a 100 W scale.
    private var powerScale: Double {
        let peak = monitor.powerHistory.max() ?? 0
        return max(20, (peak / 20).rounded(.up) * 20)
    }

    private var fanSummary: String {
        let fans = monitor.thermal.fans.values.sorted(by: >)
        guard let top = fans.first else { return "No fans" }
        return "\(Int(top)) rpm"
    }

    private var netSummary: String {
        "↓\(Format.rate(monitor.network.downBytesPerSec))  ↑\(Format.rate(monitor.network.upBytesPerSec))"
    }

    private var diskSummary: String {
        "↓\(Format.rate(monitor.disk.readBytesPerSec))  ↑\(Format.rate(monitor.disk.writeBytesPerSec))"
    }

    /// "80% · plugged in". Kept short because it shares a line with disk I/O —
    /// the charge rate and capacities live in the hover card.
    private func batterySummary(_ battery: BatterySample) -> String {
        var state: String
        if let minutes = battery.minutesRemaining {
            state = battery.isCharging
                ? "\(Format.duration(minutes: minutes)) to full"
                : "\(Format.duration(minutes: minutes)) left"
        } else if battery.isCharging {
            state = "charging"
        } else if battery.isPluggedIn {
            state = "plugged in"
        } else {
            state = "on battery"
        }
        return String(format: "%.0f%% · %@", battery.percent, state)
    }

    private func batteryCard(_ battery: BatterySample) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Battery").font(.system(size: 10, weight: .semibold))
            Text(battery.stateDescription)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
                infoRow("Charge", String(format: "%.0f%%", battery.percent))
                infoRow("Rate", battery.watts.map {
                    "\(battery.isCharging ? "+" : "−")\(Format.watts($0))"
                } ?? "—")
                infoRow(battery.isCharging ? "Time to full" : "Time remaining",
                        battery.minutesRemaining.map { Format.duration(minutes: $0) } ?? "—")
                infoRow("Capacity", capacityText(battery))
                infoRow("Health", battery.healthPercent.map { String(format: "%.0f%%", $0) } ?? "—")
                infoRow("Cycles", battery.cycleCount.map(String.init) ?? "—")
                if let temp = monitor.thermal.temperatures["gas gauge battery"] {
                    infoRow("Temperature", Format.temp(temp))
                }
            }

            Text(battery.isPluggedIn
                 ? "Time remaining only appears on battery power — the gauge reports "
                   + "\"unknown\" while plugged in. Sitting below 100% on AC means a "
                   + "charge limit or Optimised Charging is holding it there, not a fault. "
                   + "Health is the same \"Maximum Capacity\" figure System Information "
                   + "shows, read from macOS itself, so it won't quite match the mAh "
                   + "ratio above."
                 : "Time remaining is the gauge's own estimate from the current draw, "
                   + "so it moves around as load changes.")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .detailCardChrome()
    }

    private func capacityText(_ battery: BatterySample) -> String {
        guard let max = battery.maxCapacitymAh, let design = battery.designCapacitymAh else { return "—" }
        return String(format: "%.0f / %.0f mAh", max, design)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
            Text(value).gridColumnAlignment(.trailing).foregroundStyle(.secondary)
        }
        .font(.system(size: 10).monospacedDigit())
    }

    private func batteryIcon(_ battery: BatterySample) -> String {
        if battery.isCharging { return "battery.100.bolt" }
        switch battery.percent {
        case ..<15: return "battery.0"
        case ..<40: return "battery.25"
        case ..<70: return "battery.50"
        case ..<90: return "battery.75"
        default: return "battery.100"
        }
    }

    /// macOS's thermal advisory. Only `.serious` and above actually mean reduced
    /// performance — `.fair` just means "warm, fans up", so calling it throttling
    /// would be alarmist and wrong.
    private var thermalBadge: (label: String, color: Color, help: String)? {
        // Measured limiting beats macOS's advisory: during a 15-minute soak this
        // machine cut power 47% while `thermalState` never left `.fair`.
        if monitor.isPowerLimited, monitor.thermalPressure != .serious,
           monitor.thermalPressure != .critical {
            let peak = Format.watts(monitor.powerPeakWatts)
            return ("power limited", .orange,
                    "Fully loaded but drawing well under the \(peak) peak seen in the last "
                    + "few minutes, so clocks are being held below boost. This is the normal "
                    + "sustained state after the boost window — more cooling won't lift it.")
        }
        switch monitor.thermalPressure {
        case .nominal:
            return nil
        case .fair:
            return ("warm", .yellow,
                    "Slightly elevated. macOS is asking apps to ease off, but it is NOT "
                    + "reducing performance — clocks can still hit their top state. Normal "
                    + "under sustained load, especially while charging.")
        case .serious:
            return ("throttling", .orange,
                    "macOS is reducing performance to shed heat. Expect the clock "
                    + "percentages above to drop.")
        case .critical:
            return ("critical", .red,
                    "Performance is heavily cut until the machine cools down.")
        @unknown default:
            return nil
        }
    }

    private var suggestionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Suggestions").font(.system(size: 12, weight: .medium))
            ForEach(SuggestionEngine.suggestions(for: monitor)) { SuggestionRow(suggestion: $0) }
        }
    }

    private var overlaySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(
                get: { overlay.isVisible },
                set: { overlay.setVisible($0) }
            )) {
                Text("Game overlay").font(.system(size: 12, weight: .medium))
            }
            .toggleStyle(.switch)

            Picker("Corner", selection: Binding(
                get: { overlay.corner },
                set: { overlay.corner = $0 }
            )) {
                ForEach(OverlayCorner.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
            .font(.system(size: 11))
            .disabled(!overlay.isVisible)

            if overlay.isVisible {
                GroupBox {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 12) {
                            Toggle("CPU", isOn: $ovCPU)
                            Toggle("GPU", isOn: $ovGPU)
                            Toggle("RAM", isOn: $ovRAM)
                        }
                        HStack(spacing: 12) {
                            Toggle("Temp", isOn: $ovTemp)
                            Toggle("Net", isOn: $ovNet)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text("Overlay contents").font(.system(size: 11, weight: .medium))
                }
            }
        }
    }

    private var menuBarSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Menu bar").font(.system(size: 12, weight: .medium))
            Toggle("CPU %", isOn: $mbCPU)
            Toggle("GPU %", isOn: $mbGPU)
            Toggle("RAM", isOn: $mbRAM)
            Toggle("RAM as GB (instead of %)", isOn: $mbRAMasGB)
                .disabled(!mbRAM)
                .padding(.leading, 18)
            Toggle("Power (W)", isOn: $mbPower)
                .disabled(monitor.power.systemWatts == nil)
            Toggle("🔥 while throttling", isOn: $mbThrottle)
        }
        .toggleStyle(.checkbox)
        .font(.system(size: 11))
    }

    /// macOS's own menu-bar setting, not one of ours: one click to get the bar
    /// out of the way of a full-screen video and back again.
    private var fullScreenMenuBarSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(
                get: { menuBarVisibility.hidesInFullScreen },
                set: { menuBarVisibility.setHidesInFullScreen($0) }
            )) {
                Text("Hide menu bar in full screen").font(.system(size: 12, weight: .medium))
            }
            .toggleStyle(.switch)
            // System Settings may have changed it since the panel last opened.
            .onAppear { menuBarVisibility.refresh() }

            Text("Applies the next time a window enters full screen.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// Starts the app at every login, and so after a restart too.
    private var loginItemSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(
                get: { loginItem.isEnabled },
                set: { loginItem.setEnabled($0) }
            )) {
                Text("Launch at login").font(.system(size: 12, weight: .medium))
            }
            .toggleStyle(.switch)
            .disabled(!loginItem.isAvailable)
            // System Settings may have changed it since the panel last opened.
            .onAppear { loginItem.refresh() }

            Text(loginItem.problem ?? "Starts automatically after you log in or restart.")
                .font(.caption2)
                .foregroundStyle(loginItem.problem == nil ? AnyShapeStyle(.secondary)
                                                          : AnyShapeStyle(Color.orange))
        }
    }

    private var samplingSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Update every", selection: $refreshInterval) {
                Text("0.5 s").tag(0.5)
                Text("1 s").tag(1.0)
                Text("2 s").tag(2.0)
                Text("5 s").tag(5.0)
            }
            .pickerStyle(.menu)

            // Stored inverted so an unset default reads as "on" — see
            // SystemMonitor.loadSettings().
            Toggle("Halve the rate on battery", isOn: Binding(
                get: { !batterySaverOff },
                set: { batterySaverOff = !$0 }
            ))
            .toggleStyle(.checkbox)
        }
        .font(.system(size: 11))
    }

    private var metalHUDSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(
                get: { hud.isEnabled },
                set: { hud.setEnabled($0) }
            )) {
                Text("Metal Performance HUD").font(.system(size: 12, weight: .medium))
            }
            .toggleStyle(.switch)
            .onAppear { hud.refresh() }

            Text("Applies to Metal games launched after toggling.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Button("Launch game with HUD…") { pickAndLaunch() }
                .buttonStyle(.link)
                .font(.system(size: 11))
        }
    }

    private func pickAndLaunch() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Launch with HUD"
        if panel.runModal() == .OK, let url = panel.url {
            hud.launchAppWithHUD(url)
        }
    }
}

/// One metric row: title, value, and a sparkline of its recent history.
struct StatRow: View {
    let title: String
    let value: String
    let history: [Double]
    let maxValue: Double
    let color: Color
    /// Optional chip beside the title, e.g. the thermal state.
    var badge: String? = nil
    var badgeColor: Color = .orange
    var badgeHelp: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.system(size: 12, weight: .medium))
                if let badge {
                    Text(badge)
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(badgeColor.opacity(0.22), in: Capsule())
                        .foregroundStyle(badgeColor)
                        .help(badgeHelp ?? "")
                }
                Spacer()
                Text(value)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Sparkline(values: history, maxValue: maxValue, color: color)
                .frame(height: 22)
        }
    }
}

/// Shared look for the floating detail cards.
extension View {
    func detailCardChrome() -> some View {
        self
            .padding(10)
            .frame(width: 244, alignment: .leading)
            .floatingCardSurface(cornerRadius: 12)
    }

    /// Floats `card` just below this view while the pointer is over it. The card
    /// is measured off the row's own height rather than a hardcoded offset, and
    /// takes no hits, so moving onto it doesn't cancel the hover that spawned it.
    func hoverCard<Card: View>(isShown: Binding<Bool>,
                               enabled: Bool,
                               alignment: Alignment = .topLeading,
                               @ViewBuilder card: @escaping () -> Card) -> some View {
        modifier(HoverCardModifier(isShown: isShown, enabled: enabled,
                                   alignment: alignment, card: card))
    }
}

private struct HoverCardModifier<Card: View>: ViewModifier {
    @Binding var isShown: Bool
    let enabled: Bool
    let alignment: Alignment
    @ViewBuilder let card: () -> Card

    @State private var rowHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The card hangs just below the row, so it scales from its top edge.
    private var anchorPoint: UnitPoint {
        alignment == .topTrailing ? .topTrailing : .topLeading
    }

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { geo in
                    Color.clear.onChange(of: geo.size.height, initial: true) { _, height in
                        rowHeight = height
                    }
                }
            )
            .onHover { isShown = $0 && enabled }
            .overlay(alignment: alignment) {
                if isShown {
                    card()
                        .offset(y: rowHeight + 4)
                        .allowsHitTesting(false)
                        // Grows out of the row it belongs to, and leaves the same
                        // way. Cross-fade only under Reduce Motion.
                        .transition(reduceMotion
                                    ? .opacity
                                    : .scale(scale: 0.96, anchor: anchorPoint).combined(with: .opacity))
                        .zIndex(1)
                }
            }
            // Critically damped: it can be interrupted mid-flight without bounce.
            .animation(.spring(response: 0.28, dampingFraction: 1), value: isShown)
    }
}
