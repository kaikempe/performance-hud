import SwiftUI
import AppKit

/// Manages a click-through floating panel that draws over other apps — including
/// windowed / borderless-fullscreen games (via canJoinAllSpaces + a shielding
/// window level). It cannot composite over a game in *exclusive* fullscreen; for
/// that, use Apple's Metal HUD instead.
@MainActor
final class OverlayController: ObservableObject {
    @Published private(set) var isVisible = false
    @Published var corner: OverlayCorner {
        didSet {
            UserDefaults.standard.set(corner.rawValue, forKey: SettingsKey.overlayCorner)
            reposition()
        }
    }

    private var panel: NSPanel?
    private var hosting: NSHostingView<OverlayView>?
    private let monitor: SystemMonitor

    init(monitor: SystemMonitor) {
        self.monitor = monitor
        let stored = UserDefaults.standard.integer(forKey: SettingsKey.overlayCorner)
        self.corner = OverlayCorner(rawValue: stored) ?? .topLeft

        // Toggling which rows show changes the overlay's size — resize to fit.
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // Defer so SwiftUI has applied the new @AppStorage state first.
                DispatchQueue.main.async { self?.refreshLayout() }
            }
        }
    }

    func setVisible(_ visible: Bool) {
        isVisible = visible
        // The overlay can show temperature, so it has to pull the thermal sweep
        // back up from its idle rate while it's on screen.
        monitor.setOverlayVisible(visible)
        if visible { showPanel() } else { hidePanel() }
    }

    /// Ordering the window out would leave its SwiftUI tree alive and re-laid-out
    /// on every sample for the rest of the session — see `PanelRefresh`. Tear it
    /// down instead; showing it again costs one rebuild.
    private func hidePanel() {
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        hosting = nil
    }

    func toggle() { setVisible(!isVisible) }

    private func showPanel() {
        if panel == nil {
            let hosting = NSHostingView(rootView: OverlayView(monitor: monitor))
            hosting.autoresizingMask = [.width, .height]
            hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
            self.hosting = hosting

            let p = NSPanel(
                contentRect: hosting.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.ignoresMouseEvents = true
            p.hidesOnDeactivate = false
            // High enough to sit above fullscreen game Spaces.
            p.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            p.contentView = hosting
            panel = p
        }
        panel?.orderFrontRegardless()
        refreshLayout()
    }

    /// Resizes the panel to the overlay's current intrinsic size and repositions.
    private func refreshLayout() {
        guard isVisible, let panel, let hosting else { return }
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        if size.width > 0 && size.height > 0 {
            panel.setContentSize(size)
        }
        reposition()
    }

    private func reposition() {
        guard let panel, let screen = NSScreen.main else { return }
        let frame = screen.frame
        let size = panel.frame.size
        let pad: CGFloat = 24
        // `visibleFrame` stops below the menu bar (and the notch it sits in), so
        // the top corners tuck under it instead of being drawn over it. When the
        // bar is hidden — which is the case in the full-screen games this is for —
        // the two frames share a top edge and the overlay rides up with it. Only
        // the top is inset: the Dock also shrinks `visibleFrame`, and there is no
        // reason to let it shove the bottom corners upward.
        let top = min(frame.maxY, screen.visibleFrame.maxY)
        let origin: CGPoint
        switch corner {
        case .topLeft:
            origin = CGPoint(x: frame.minX + pad, y: top - size.height - pad)
        case .topRight:
            origin = CGPoint(x: frame.maxX - size.width - pad, y: top - size.height - pad)
        case .bottomLeft:
            origin = CGPoint(x: frame.minX + pad, y: frame.minY + pad)
        case .bottomRight:
            origin = CGPoint(x: frame.maxX - size.width - pad, y: frame.minY + pad)
        }
        panel.setFrameOrigin(origin)
    }
}
