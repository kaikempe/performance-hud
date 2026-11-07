import SwiftUI

/// One thing worth doing about the machine's current state, with the prompt that
/// hands it to Claude Code.
struct Suggestion: Identifiable {
    let id: String
    let icon: String
    let color: Color
    let title: String
    let detail: String
    let prompt: String
}

/// The slice of the monitor that suggestions depend on, as plain values — so the
/// rules below can be tested without a running monitor or any hardware.
struct MachineState {
    var cpu: Double
    var gpu: Double
    var memory: MemorySample
    var thermalPressure: ProcessInfo.ThermalState
    var isPowerLimited: Bool
    var topProcesses: [ProcessSample]
    var battery: BatterySample?

    @MainActor
    init(_ monitor: SystemMonitor) {
        cpu = monitor.cpu
        gpu = monitor.gpu
        memory = monitor.memory
        thermalPressure = monitor.thermalPressure
        isPowerLimited = monitor.isPowerLimited
        topProcesses = monitor.topProcesses
        battery = monitor.battery
    }

    init(cpu: Double = 0, gpu: Double = 0, memory: MemorySample,
         thermalPressure: ProcessInfo.ThermalState = .nominal, isPowerLimited: Bool = false,
         topProcesses: [ProcessSample] = [], battery: BatterySample? = nil) {
        self.cpu = cpu; self.gpu = gpu; self.memory = memory
        self.thermalPressure = thermalPressure; self.isPowerLimited = isPowerLimited
        self.topProcesses = topProcesses; self.battery = battery
    }
}

enum SuggestionEngine {
    /// Everything Claude is told is read off the monitor, so the prompt starts
    /// from what the HUD saw rather than from a vague "my Mac is slow".
    @MainActor
    static func suggestions(for monitor: SystemMonitor) -> [Suggestion] {
        suggestions(for: MachineState(monitor))
    }

    static func suggestions(for monitor: MachineState) -> [Suggestion] {
        var result: [Suggestion] = []
        let snapshot = Self.snapshot(of: monitor)

        let guardrail = """
        Investigate with read-only commands first (ps, top -l 1, vm_stat, pmset, \
        memory_pressure). Then tell me what you found and what you'd do. Ask me \
        before quitting any app, killing any process or changing any setting.
        """

        if monitor.memory.pressure != .normal || monitor.memory.swapUsedBytes > 2_000_000_000 {
            result.append(Suggestion(
                id: "memory", icon: "memorychip", color: .yellow,
                title: "Memory is tight",
                detail: "Find what's using the RAM and free some.",
                prompt: """
                My Mac is short on memory. \(snapshot)
                Find which apps and processes hold the most memory, which are safe to quit, \
                and whether anything looks like a leak.
                \(guardrail)
                """))
        }

        let hot = monitor.thermalPressure == .serious || monitor.thermalPressure == .critical
        if hot || monitor.isPowerLimited {
            result.append(Suggestion(
                id: "thermal", icon: "thermometer.high", color: .orange,
                title: hot ? "Running hot, throttling" : "Power limited under load",
                detail: "Work out what's driving the heat.",
                prompt: """
                My Mac is \(hot ? "thermally throttling" : "power-limited under sustained load"). \(snapshot)
                Find what is generating the load and heat, and what I can do about it.
                \(guardrail)
                """))
        } else if monitor.cpu > 85 {
            let names = monitor.topProcesses.prefix(3).map(\.name).joined(separator: ", ")
            result.append(Suggestion(
                id: "cpu", icon: "cpu", color: .blue,
                title: "CPU is pinned",
                detail: names.isEmpty ? "Find what's keeping it busy." : "Busiest: \(names).",
                prompt: """
                My CPU is close to fully used. \(snapshot)
                Work out which processes are responsible, whether that's expected, and what \
                I can do to bring it down.
                \(guardrail)
                """))
        }

        if let battery = monitor.battery, !battery.isPluggedIn, battery.percent < 30 {
            result.append(Suggestion(
                id: "battery", icon: "battery.25", color: .red,
                title: "Battery is low",
                detail: "Stretch what's left.",
                prompt: """
                My Mac is on battery at \(Int(battery.percent))%. \(snapshot)
                Find what's draining it fastest and how to make it last longer.
                \(guardrail)
                """))
        }

        if result.isEmpty {
            result.append(Suggestion(
                id: "checkup", icon: "checkmark.seal", color: .green,
                title: "Everything looks healthy",
                detail: "Want a deeper look anyway?",
                prompt: """
                Give my Mac a quick health check. \(snapshot)
                Look at startup items, background agents, disk space and anything else \
                quietly costing performance or battery.
                \(guardrail)
                """))
        }
        return result
    }

    private static func snapshot(of monitor: MachineState) -> String {
        let top = monitor.topProcesses.prefix(5)
            .map { "\($0.name) \(Int($0.cpuPercent))%" }.joined(separator: ", ")
        var parts = [
            "Right now (from my Performance HUD app): CPU \(Int(monitor.cpu))%, GPU \(Int(monitor.gpu))%",
            String(format: "memory %.1f of %.0f GB used", monitor.memory.usedGB, monitor.memory.totalGB),
            "memory pressure \(monitor.memory.pressure)",
            "thermal state \(monitor.thermalPressure.rawValue)",
        ]
        if !top.isEmpty { parts.append("busiest by CPU: \(top)") }
        return parts.joined(separator: "; ") + "."
    }
}

/// A suggestion row: what's wrong, and one button that hands it to Claude Code.
struct SuggestionRow: View {
    let suggestion: Suggestion

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: suggestion.icon)
                .font(.system(size: 13))
                .foregroundStyle(suggestion.color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(suggestion.title).font(.system(size: 12, weight: .medium))
                Text(suggestion.detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 6)
            Button("Ask Claude") { ClaudeLauncher.run(prompt: suggestion.prompt) }
                .glassActionButton(fallback: PressableCapsuleStyle())
                .help("Opens Claude Code in Terminal with what the HUD sees. It looks first and asks before changing anything.")
        }
    }
}

/// Feedback on press, not on release.
private struct PressableCapsuleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Color.accentColor.opacity(configuration.isPressed ? 0.35 : 0.18), in: Capsule())
            .foregroundStyle(Color.accentColor)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 1), value: configuration.isPressed)
    }
}
