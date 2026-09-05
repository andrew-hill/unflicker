import Foundation
import os

// One subsystem, three categories. There is no log file: this is a background
// agent, and `/usr/bin/log show --predicate 'subsystem == "unflicker"'` is how
// you debug one of those. Absolute path: `log` is a zsh builtin that shadows it.
public enum Log {
    /// What the shipped binary logs under. The README documents this string.
    public static let shipped = "unflicker"

    /// `Logger` writes to the system log wherever it is called from, so
    /// without this the suite's fixtures land in the subsystem users are told
    /// to grep, indistinguishable from the real agent in a live `log stream`.
    ///
    /// There is no environment variable to key off: measured 2026-08-31,
    /// `swift test` sets none. So this goes by the test runner's process name.
    /// SwiftPM's is `swiftpm-testing-helper`, Xcode's is `xctest`. Brittle, but
    /// guarded: `logsToASeparateSubsystemUnderTest` fails loudly if either is
    /// ever renamed, and the worst case is logging to `shipped` again.
    public static let subsystem: String = {
        let runner = ProcessInfo.processInfo.processName
        let underTest = runner == "swiftpm-testing-helper" || runner == "xctest"
        return underTest ? "\(shipped).test" : shipped
    }()

    public static let general = Logger(subsystem: subsystem, category: "general")
    public static let usb = Logger(subsystem: subsystem, category: "usb")
    public static let agent = Logger(subsystem: subsystem, category: "agent")
}
