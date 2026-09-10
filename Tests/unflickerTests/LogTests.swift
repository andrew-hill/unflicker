import Testing
@testable import UVCCore
@testable import unflicker

// The suite logs fixtures for things that never happened: installs from paths
// that do not exist, cameras that were not attached, configs that were never
// written. Without a separate subsystem they land where the README tells users
// to grep, and read as the real agent in a live `log stream`.
//
// This test guards the detection. There is no environment variable to key off
// (measured 2026-08-31, `swift test` sets none), so it goes by the runner's
// process name, and if SwiftPM ever renames the helper this fails rather than
// quietly logging to the real subsystem again.
@Test func logsToASeparateSubsystemUnderTest() {
    #expect(Log.subsystem == "unflicker.test")
}
