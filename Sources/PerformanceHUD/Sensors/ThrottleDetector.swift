import Foundation

/// Detects sustained power limiting — the thing `ProcessInfo.thermalState` fails
/// to report.
///
/// Measured on an M5 Max during a 15-minute soak: package power peaked at 93.7 W,
/// was cut to 49.7 W, and settled at ~74 W, with GPU clocks falling from 55% to
/// 20% — while `thermalState` sat at `.fair` the entire time and never once
/// reached `.serious`. The signal that *did* track it is power falling while
/// utilization stays pinned, which is what this watches.
final class ThrottleDetector {
    /// Utilization (%) above which the machine counts as "being asked to work".
    /// Public because the monitor skips reading power below it — every reading
    /// this detector is handed under that load is discarded, so taking them at
    /// all is pure cost.
    static let loadThreshold: Double = 70
    /// Power must fall this far below the recent peak to count as limited.
    private let dropRatio: Double = 0.85
    /// How far back to look for the peak. Long enough to span the boost window.
    private let window: TimeInterval = 180

    private var recentPeaks: [(time: Date, watts: Double)] = []

    /// True when the machine is loaded but drawing meaningfully less than it
    /// recently did under the same kind of load.
    private(set) var isPowerLimited = false
    /// The peak this is being compared against, for the explanatory tooltip.
    private(set) var peakWatts: Double?

    func update(load: Double, watts: Double?, now: Date = Date()) {
        guard let watts, watts > 0 else {
            reset()
            return
        }
        // Off-load power tells us nothing about a ceiling: an idle machine draws
        // little because there's nothing to do, not because it's being held back.
        guard load >= Self.loadThreshold else {
            reset()
            return
        }

        recentPeaks.append((now, watts))
        recentPeaks.removeAll { now.timeIntervalSince($0.time) > window }

        let peak = recentPeaks.map(\.watts).max() ?? watts
        peakWatts = peak
        // A low peak means we never saw the machine stretch its legs, so there's
        // nothing to claim it has fallen from.
        isPowerLimited = peak >= 20 && watts < peak * dropRatio
    }

    private func reset() {
        recentPeaks.removeAll()
        peakWatts = nil
        isPowerLimited = false
    }
}
