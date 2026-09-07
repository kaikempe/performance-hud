import Foundation

/// Which screen corner the in-game overlay pins to.
enum OverlayCorner: Int, CaseIterable, Identifiable {
    case topLeft, topRight, bottomLeft, bottomRight

    var id: Int { rawValue }
    var label: String {
        switch self {
        case .topLeft: return "Top Left"
        case .topRight: return "Top Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        }
    }
}

enum SettingsKey {
    static let overlayCorner = "overlayCorner"

    /// Seconds between samples. 0 means "use the default".
    static let refreshInterval = "refreshInterval"
    /// Whether to halve the sample rate when running on battery.
    static let batterySaver = "batterySaver"

    // Independent menu-bar toggles — any combination.
    static let mbCPU = "mb.cpu"
    static let mbGPU = "mb.gpu"
    static let mbRAM = "mb.ram"
    static let mbRAMasGB = "mb.ramAsGB"
    static let mbPower = "mb.power"
    static let mbThrottle = "mb.throttle"

    // Independent overlay-row toggles.
    static let ovCPU = "ov.cpu"
    static let ovGPU = "ov.gpu"
    static let ovRAM = "ov.ram"
    static let ovTemp = "ov.temp"
    static let ovNet = "ov.net"
}
