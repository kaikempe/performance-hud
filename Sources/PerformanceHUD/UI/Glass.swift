import SwiftUI

// Liquid Glass, where the OS has it.
//
// The app still targets macOS 14, so every use goes through here: macOS 26 and
// later get the glass material, older systems keep the look they had. The
// `compiler(>=6.2)` guard keeps the package building with an Xcode that predates
// the SDK — without it, an older toolchain would fail on `glassEffect` itself.
//
// Glass is for the layer that floats above content: the hover cards and the
// action buttons. The panel's own background is already the system's material,
// and the rows inside it stay flat, so nothing sits glass-on-glass.

extension View {
    /// A floating card's surface: glass on macOS 26+, the opaque card before it.
    @ViewBuilder
    func floatingCardSurface(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            // Glass supplies its own edge highlight and shadow, so the manual
            // stroke and double shadow below would only muddy it.
            self.glassEffect(.regular, in: shape)
        } else {
            self.legacyCardSurface(shape)
        }
        #else
        self.legacyCardSurface(shape)
        #endif
    }

    /// The pre-glass card. Opaque on purpose: a nested material makes macOS drop
    /// the blur of the whole panel while a card is up.
    private func legacyCardSurface(_ shape: RoundedRectangle) -> some View {
        self
            .background(Color(nsColor: .windowBackgroundColor), in: shape)
            .overlay(shape.strokeBorder(.quaternary))
            // Big surface, deeper shadow: a soft ambient layer plus a tighter one.
            .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
            .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
    }

    /// Small in-row action button: system glass on macOS 26+, else `fallback`.
    @ViewBuilder
    func glassActionButton<Fallback: ButtonStyle>(fallback: Fallback) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            self.buttonStyle(.glass).controlSize(.small)
        } else {
            self.buttonStyle(fallback)
        }
        #else
        self.buttonStyle(fallback)
        #endif
    }
}
