import Foundation
import Combine

/// The four states of System Settings › Desktop & Dock › "Automatically hide
/// and show the menu bar", as macOS stores them.
enum MenuBarAutoHide: Int {
    case always = 0
    case onDesktopOnly = 1
    case inFullScreenOnly = 2
    case never = 3

    var hidesOnDesktop: Bool { self == .always || self == .onDesktopOnly }
    var hidesInFullScreen: Bool { self == .always || self == .inFullScreenOnly }

    static func from(hidesOnDesktop desktop: Bool, hidesInFullScreen full: Bool) -> MenuBarAutoHide {
        switch (desktop, full) {
        case (true, true): return .always
        case (true, false): return .onDesktopOnly
        case (false, true): return .inFullScreenOnly
        case (false, false): return .never
        }
    }
}

/// Flips macOS's menu-bar auto-hiding between "in full screen" and "not at all",
/// leaving the desktop half of the setting exactly as the user has it.
///
/// The setting lives in three places and only two of them do anything. The pair
/// that macOS actually reads are the global-domain keys `_HIHideMenuBar`
/// (desktop) and `AppleMenuBarVisibleInFullscreen` (full screen, stored
/// inverted). `AutoHideMenuBarOption` in ControlCenter's domain is just the
/// System Settings picker's own state — no system framework reads it, so
/// writing it alone changed the picker and nothing else, which is why an
/// earlier version of this toggle appeared to do nothing. It is still written
/// here so the picker agrees with reality.
@MainActor
final class MenuBarVisibilityController: ObservableObject {
    /// True when the menu bar is set to slide away in full screen.
    @Published private(set) var hidesInFullScreen = false

    /// Stored inverted: true means the bar stays *visible* in full screen.
    private static let fullScreenKey = "AppleMenuBarVisibleInFullscreen" as CFString
    private static let desktopKey = "_HIHideMenuBar" as CFString
    /// The System Settings picker's mirror of the two keys above.
    private static let pickerDomain = "com.apple.controlcenter" as CFString
    private static let pickerKey = "AutoHideMenuBarOption" as CFString

    /// AppKit watches for this and re-reads the setting, so apps already
    /// running pick the change up without being relaunched.
    private static let changeNotification = "AppleInterfaceFullScreenMenuBarVisibilityChangedNotification"

    init() {
        refresh()
    }

    /// Re-reads the setting, which System Settings may have changed behind our
    /// back since the panel was last opened.
    func refresh() {
        hidesInFullScreen = current.hidesInFullScreen
    }

    /// Preserves the desktop half: someone set to "Always" stays hiding on the
    /// desktop and just moves to "On Desktop Only", rather than being quietly
    /// switched to a mode they never chose.
    func setHidesInFullScreen(_ hides: Bool) {
        let option = MenuBarAutoHide.from(hidesOnDesktop: current.hidesOnDesktop,
                                          hidesInFullScreen: hides)

        setGlobal(Self.fullScreenKey, option.hidesInFullScreen ? kCFBooleanFalse : kCFBooleanTrue)
        setGlobal(Self.desktopKey, option.hidesOnDesktop ? kCFBooleanTrue : kCFBooleanFalse)
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)

        CFPreferencesSetValue(Self.pickerKey, option.rawValue as CFNumber, Self.pickerDomain,
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(Self.pickerDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)

        DistributedNotificationCenter.default().post(
            name: Notification.Name(Self.changeNotification), object: nil
        )

        hidesInFullScreen = hides
    }

    func toggle() {
        setHidesInFullScreen(!hidesInFullScreen)
    }

    private func setGlobal(_ key: CFString, _ value: CFBoolean) {
        CFPreferencesSetValue(key, value, kCFPreferencesAnyApplication,
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    private func globalBool(_ key: CFString) -> Bool? {
        (CFPreferencesCopyValue(key, kCFPreferencesAnyApplication,
                                kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? NSNumber)?
            .boolValue
    }

    private var current: MenuBarAutoHide {
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        // Both keys absent means the macOS default: the bar shows on the
        // desktop and hides in full screen.
        let desktop = globalBool(Self.desktopKey) ?? false
        let full = !(globalBool(Self.fullScreenKey) ?? false)
        return .from(hidesOnDesktop: desktop, hidesInFullScreen: full)
    }
}
