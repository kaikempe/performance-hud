import Foundation
import ServiceManagement

/// "Launch at login", backed by `SMAppService.mainApp` — the supported
/// replacement for both the deprecated `SMLoginItemSetEnabled` and for dropping
/// a hand-written plist in `~/Library/LaunchAgents`.
///
/// Registering adds this bundle to System Settings › General › Login Items,
/// which launchd then starts at every login — so it also covers a reboot, since
/// a reboot ends in a login. The user can switch it off there behind our back,
/// so the status is re-read whenever the panel opens rather than cached.
@MainActor
final class LoginItemController: ObservableObject {
    @Published private(set) var isEnabled = false

    /// Why the toggle is unavailable or didn't take, shown beneath it. `nil`
    /// when the toggle simply reflects an on/off the user chose.
    @Published private(set) var problem: String?

    /// True when the toggle can do anything at all. Login Items are registered
    /// per *bundle* — launchd stores the path of the `.app` and re-launches
    /// that — so there is nothing to register when running the bare SwiftPM
    /// binary during development.
    var isAvailable: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    init() {
        refresh()
    }

    /// Re-reads the system's view of the registration.
    func refresh() {
        guard isAvailable else {
            isEnabled = false
            problem = "Only available from PerformanceHUD.app — run ./build-app.sh."
            return
        }

        switch SMAppService.mainApp.status {
        case .enabled:
            isEnabled = true
            problem = nil
        case .requiresApproval:
            // Registered, but the user (or a previous denial) has it switched
            // off in System Settings; only they can turn it back on.
            isEnabled = false
            problem = "Blocked — enable “Performance HUD” in System Settings › General › Login Items."
        case .notRegistered, .notFound:
            isEnabled = false
            problem = nil
        @unknown default:
            isEnabled = false
            problem = nil
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard isAvailable else { refresh(); return }

        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            isEnabled = enabled
            problem = nil
        } catch {
            // Trust the system over our intent: a failed register leaves the
            // previous state, whatever that was.
            refresh()
            problem = error.localizedDescription
        }
    }

    func toggle() { setEnabled(!isEnabled) }
}

/// `PerformanceHUD --login-item [status|on|off]`: the same switch without
/// opening the panel, so it can be set from a script or a fresh build.
enum LoginItemCLI {
    static let flag = "--login-item"

    /// Top-level code in `main.swift` is not main-actor isolated under the
    /// Swift 5 language mode, but it does run on the main thread — which is all
    /// `LoginItemController` needs.
    static func run(_ arguments: [String]) {
        MainActor.assumeIsolated { perform(arguments) }
    }

    @MainActor
    private static func perform(_ arguments: [String]) {
        let controller = LoginItemController()
        let action = arguments.drop(while: { $0 != flag }).dropFirst().first ?? "status"

        switch action {
        case "on": controller.setEnabled(true)
        case "off": controller.setEnabled(false)
        case "status": break
        default:
            print("usage: PerformanceHUD \(flag) [status|on|off]")
            exit(2)
        }

        print("Launch at login: \(controller.isEnabled ? "on" : "off")")
        if let problem = controller.problem {
            print("  \(problem)")
        }
        // A failed on/off is a failed command, so scripts can tell.
        if action != "status", controller.problem != nil { exit(1) }
    }
}
