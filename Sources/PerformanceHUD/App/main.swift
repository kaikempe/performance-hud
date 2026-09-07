import Foundation

// Entry point. `--dump-sensors` prints the raw sensor list and `--bench` times
// each reader, both then exiting; otherwise the SwiftUI menu-bar app runs.
if CommandLine.arguments.contains("--dump-sensors") {
    SensorDump.run()
} else if CommandLine.arguments.contains("--bench") {
    SensorDump.bench()
} else {
    PerformanceHUDApp.main()
}
