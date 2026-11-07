import Testing
import Foundation
@testable import PerformanceHUD

@Suite("ThrottleDetector")
struct ThrottleDetectorTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test("Power falling while load stays pinned counts as limited")
    func detectsDrop() {
        let d = ThrottleDetector()
        d.update(load: 95, watts: 90, now: t0)
        d.update(load: 95, watts: 60, now: t0 + 30)
        #expect(d.isPowerLimited)
        #expect(d.peakWatts == 90)
    }

    @Test("A small dip is not a limit")
    func smallDipIgnored() {
        let d = ThrottleDetector()
        d.update(load: 95, watts: 90, now: t0)
        d.update(load: 95, watts: 80, now: t0 + 30)
        #expect(!d.isPowerLimited)
    }

    @Test("Below the load threshold nothing is claimed and history resets")
    func idleResets() {
        let d = ThrottleDetector()
        d.update(load: 95, watts: 90, now: t0)
        d.update(load: 10, watts: 5, now: t0 + 10)
        #expect(!d.isPowerLimited)
        #expect(d.peakWatts == nil)
        // The old 90 W peak is gone, so 60 W under load is a fresh baseline.
        d.update(load: 95, watts: 60, now: t0 + 20)
        #expect(!d.isPowerLimited)
    }

    @Test("A low peak never counts: nothing to have fallen from")
    func lowPeak() {
        let d = ThrottleDetector()
        d.update(load: 95, watts: 15, now: t0)
        d.update(load: 95, watts: 5, now: t0 + 10)
        #expect(!d.isPowerLimited)
    }

    @Test("Peaks older than the 180 s window stop counting")
    func peakExpires() {
        let d = ThrottleDetector()
        d.update(load: 95, watts: 90, now: t0)
        d.update(load: 95, watts: 60, now: t0 + 200)
        #expect(!d.isPowerLimited)
        #expect(d.peakWatts == 60)
    }

    @Test("Missing watts reset the detector")
    func missingWatts() {
        let d = ThrottleDetector()
        d.update(load: 95, watts: 90, now: t0)
        d.update(load: 95, watts: nil, now: t0 + 5)
        #expect(d.peakWatts == nil)
        #expect(!d.isPowerLimited)
    }
}
