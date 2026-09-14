import Foundation

// Entry point. `--dump-sensors` prints the raw sensor list, `--bench` times
// each reader, and `--login-item` reads or sets the launch-at-login
// registration; all exit afterwards. Otherwise the SwiftUI menu-bar app runs.
if CommandLine.arguments.contains("--dump-sensors") {
    SensorDump.run()
} else if CommandLine.arguments.contains("--bench") {
    SensorDump.bench()
} else if CommandLine.arguments.contains(LoginItemCLI.flag) {
    LoginItemCLI.run(CommandLine.arguments)
} else {
    PerformanceHUDApp.main()
}
