import SwiftUI

/// The floating in-game overlay, styled after Apple's Metal HUD: a dark, rounded,
/// translucent card with monospaced labels and green values. Rows are individually
/// toggleable.
struct OverlayView: View {
    @ObservedObject var monitor: SystemMonitor

    @AppStorage(SettingsKey.ovCPU) private var showCPU = true
    @AppStorage(SettingsKey.ovGPU) private var showGPU = true
    @AppStorage(SettingsKey.ovRAM) private var showRAM = true
    @AppStorage(SettingsKey.ovTemp) private var showTemp = true
    @AppStorage(SettingsKey.ovNet) private var showNet = true

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if showCPU { row("CPU", String(format: "%.0f%%", monitor.cpu)) }
            if showGPU { row("GPU", String(format: "%.0f%%", monitor.gpu)) }
            if showRAM { row("RAM", String(format: "%.1f GB", monitor.memory.usedGB)) }
            if showTemp { row("TMP", Format.temp(monitor.thermal.hottest)) }
            if showNet { row("NET", Format.rate(monitor.network.downBytesPerSec)) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(width: 150, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .fixedSize()
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(spacing: 0) {
            Text(label).foregroundStyle(.white.opacity(0.85))
            Spacer(minLength: 8)
            Text(value).foregroundStyle(Color.green)
        }
        .font(.system(size: 13, weight: .semibold, design: .monospaced))
    }
}
