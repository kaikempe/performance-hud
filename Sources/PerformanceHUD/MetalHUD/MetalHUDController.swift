import Foundation
import Combine

/// Controls Apple's built-in, free Metal Performance HUD via the
/// `MTL_HUD_ENABLED` environment variable. No Apple Developer account required.
@MainActor
final class MetalHUDController: ObservableObject {
    @Published private(set) var isEnabled = false

    init() {
        refresh()
    }

    /// Reads the current global state from launchd.
    func refresh() {
        let output = run("/bin/launchctl", ["getenv", "MTL_HUD_ENABLED"])
        isEnabled = output.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    /// Sets the HUD globally for apps launched afterward (relaunch the game).
    func setEnabled(_ enabled: Bool) {
        run("/bin/launchctl", ["setenv", "MTL_HUD_ENABLED", enabled ? "1" : "0"])
        isEnabled = enabled
    }

    func toggle() { setEnabled(!isEnabled) }

    /// Launches a chosen .app with the HUD enabled for just that process,
    /// without changing the global setting.
    func launchAppWithHUD(_ appURL: URL) {
        run("/usr/bin/open", [appURL.path, "--env", "MTL_HUD_ENABLED=1"])
    }

    @discardableResult
    private func run(_ path: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}
