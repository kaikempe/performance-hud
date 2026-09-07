import Foundation

/// Battery health exactly as System Information reports it.
///
/// macOS works the figure out inside powerd and publishes it on the power source
/// as `Maximum Capacity Percent`, but reading that key needs the private
/// `com.apple.private.iokit.batterydata` entitlement that only Apple's own tools
/// carry — an ad-hoc-signed app can't ask for it. The ratio we *can* read from
/// the IORegistry isn't the same number: powerd rounds and smooths its estimate,
/// so a pack that System Information calls 100% works out to 99% from
/// NominalChargeCapacity ÷ DesignCapacity.
///
/// So ask the one tool that does hold the entitlement. `system_profiler` costs
/// around 100 ms, far too much for the sample tick, so it runs off the main
/// thread and its answer is cached for an hour — battery health moves over
/// months, not seconds.
final class BatteryHealthReporter {
    /// How long a reading stays good for. Health barely moves in a day, let
    /// alone an hour; this is only here so a long-running app doesn't go stale.
    private static let refreshInterval: TimeInterval = 3600

    private let queue = DispatchQueue(label: "PerformanceHUD.battery-health", qos: .utility)
    private let lock = NSLock()
    private var cached: Double?
    private var lastRead: Date?
    private var isReading = false

    /// The last figure System Information reported, or nil until the first read
    /// lands — a fraction of a second after launch. Callers show nothing while
    /// it's nil: there's no second source for this number worth guessing from.
    /// Kicks off a refresh whenever the cached answer has aged out.
    func healthPercent() -> Double? {
        lock.lock()
        let value = cached
        let stale = lastRead.map { Date().timeIntervalSince($0) >= Self.refreshInterval } ?? true
        let shouldRead = stale && !isReading
        if shouldRead { isReading = true }
        lock.unlock()

        if shouldRead { queue.async { [weak self] in self?.read() } }
        return value
    }

    /// Blocks until a reading is in hand. For the one-shot `--dump-sensors`
    /// path, which has no second tick to pick the async answer up on.
    func prime() {
        queue.sync { self.read() }
    }

    private func read() {
        let value = Self.querySystemProfiler()
        lock.lock()
        // Keep the previous answer if this run failed — a transient hiccup
        // shouldn't blank the row out — but still restamp so we don't respawn
        // system_profiler on every single tick.
        if value != nil { cached = value }
        lastRead = Date()
        isReading = false
        lock.unlock()
    }

    /// Runs `system_profiler` and digs out the same value the Power pane shows.
    private static func querySystemProfiler() -> Double? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        // `mini` skips the personally-identifying fields; XML keeps the keys
        // stable, since the human-readable labels are localised.
        process.arguments = ["-xml", "-detailLevel", "mini", "SPPowerDataType"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        let data: Data
        do {
            try process.run()
            // Read before waiting: SPPowerDataType is a few KB, but draining the
            // pipe first is what stops a larger payload from deadlocking us.
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }

        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let sections = plist as? [[String: Any]] else { return nil }

        for section in sections {
            guard let items = section["_items"] as? [[String: Any]] else { continue }
            for item in items {
                guard let health = item["sppower_battery_health_info"] as? [String: Any],
                      let text = health["sppower_battery_health_maximum_capacity"] as? String,
                      let percent = parsePercent(text) else { continue }
                return percent
            }
        }
        return nil
    }

    /// The value arrives pre-formatted — "100 %", with a non-breaking space and
    /// whatever separators the user's locale uses — so parse it as a percentage
    /// rather than trusting it to look like a plain number.
    private static func parsePercent(_ text: String) -> Double? {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        if let value = formatter.number(from: text)?.doubleValue { return value * 100 }
        // Some locales format in a way the parser won't take back; the digits
        // are still all we need.
        let digits = text.filter { $0.isNumber || $0 == "." }
        return Double(digits)
    }
}
