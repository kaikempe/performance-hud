import SwiftUI

/// The menu-bar label's text, republished only when it actually changes.
///
/// This label is the one thing on screen at all times, so it is also the one view
/// SwiftUI would otherwise re-lay-out on every single sample: observing the
/// monitor directly means any one of its dozen published values invalidates the
/// label, and a menu-bar redraw pulls in AppKit layout and a WindowServer commit.
/// The visible string, though, only moves when a rounded percentage does — on an
/// idle machine most samples change nothing at all. So the monitor hands its
/// numbers here, and this republishes only on a real change.
///
/// The toggles that decide what the label shows are cached rather than read from
/// `UserDefaults` per tick, for the same reason.
@MainActor
final class MenuBarText: ObservableObject {
    @Published private(set) var text = ""

    private var showCPU = true
    private var showGPU = true
    private var showRAM = false
    private var ramAsGB = false
    private var showPower = false
    private var showThrottle = true

    init() { refreshSettings() }

    /// Re-reads the menu-bar toggles. `UserDefaults.bool(forKey:)` reads false for
    /// an absent key, which would flip the on-by-default toggles, so go through
    /// `object(forKey:)` and fall back the way `@AppStorage` does.
    func refreshSettings() {
        func flag(_ key: String, _ fallback: Bool) -> Bool {
            UserDefaults.standard.object(forKey: key) as? Bool ?? fallback
        }
        showCPU = flag(SettingsKey.mbCPU, true)
        showGPU = flag(SettingsKey.mbGPU, true)
        showRAM = flag(SettingsKey.mbRAM, false)
        ramAsGB = flag(SettingsKey.mbRAMasGB, false)
        showPower = flag(SettingsKey.mbPower, false)
        showThrottle = flag(SettingsKey.mbThrottle, true)
    }

    /// Recomputes the label from the latest sample. Assigning only on a change is
    /// the whole point — an unchanged string means no `objectWillChange`, no
    /// layout pass, and no menu-bar redraw.
    func update(from monitor: SystemMonitor) {
        var parts: [String] = []
        // `.fair` only means "warm, fans up" — macOS doesn't cut performance until
        // `.serious`, so anything below that would be a false alarm.
        let isThrottling = monitor.thermalPressure == .serious || monitor.thermalPressure == .critical
        if showThrottle && isThrottling { parts.append("🔥") }
        if showCPU { parts.append(String(format: "C %.0f%%", monitor.cpu)) }
        if showGPU { parts.append(String(format: "G %.0f%%", monitor.gpu)) }
        if showRAM {
            parts.append(ramAsGB
                ? String(format: "R %.1fGB", monitor.memory.usedGB)
                : String(format: "R %.0f%%", monitor.memory.percent))
        }
        if showPower, let watts = monitor.power.systemWatts {
            parts.append(String(format: "P %.0fW", watts))
        }
        // Never show an empty menu bar.
        let next = parts.isEmpty
            ? String(format: "C %.0f%%", monitor.cpu)
            : parts.joined(separator: "  ")
        if next != text { text = next }
    }
}

/// The compact status-bar label. Fully configurable via independent toggles.
struct MenuBarLabel: View {
    @ObservedObject var menuBar: MenuBarText

    var body: some View {
        Text(menuBar.text)
            .font(.system(size: 11, weight: .medium).monospacedDigit())
    }
}
