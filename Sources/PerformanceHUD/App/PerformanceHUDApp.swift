import SwiftUI
import AppKit

struct PerformanceHUDApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // Held with `@State`, not `@StateObject`: both keep the object alive for the
    // app's lifetime, but `@StateObject` would also subscribe to it, and this
    // scene must not be re-evaluated on every sample. The two views below
    // subscribe for themselves, each to the narrowest thing it needs.
    @State private var monitor: SystemMonitor
    @State private var hud = MetalHUDController()
    @State private var overlay: OverlayController
    @State private var menuBarVisibility = MenuBarVisibilityController()
    @State private var loginItem = LoginItemController()

    init() {
        let monitor = SystemMonitor()
        _monitor = State(initialValue: monitor)
        _overlay = State(initialValue: OverlayController(monitor: monitor))
    }

    var body: some Scene {
        MenuBarExtra {
            StatsPanelView(monitor: monitor, hud: hud, overlay: overlay,
                           menuBarVisibility: menuBarVisibility, loginItem: loginItem)
        } label: {
            MenuBarLabel(menuBar: monitor.menuBar)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Hides the Dock icon so this behaves as a pure menu-bar app, without needing an
/// LSUIElement Info.plist at development time (the .app bundle also sets it).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
