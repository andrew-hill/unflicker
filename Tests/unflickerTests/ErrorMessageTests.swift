import Testing
@testable import UVCCore
@testable import unflicker

// The messages whose construction does something: a hex format, a friendly
// value looked up from the catalogue, a branch between two wordings. Ones that
// only interpolate their own case's values are read off the source instead.
// Nothing here touches a camera, a file or the argument parser.

@Test func controlErrorsReadAsEnglish() {
    #expect("\(UVCControlError.unknownControl("nope"))" == "unknown control 'nope'")
    let bad = UVCControlError.badValue(control: "power-line-frequency", text: "55Hz")
    #expect("\(bad)" == "'55Hz' is not a valid power-line-frequency value (expected 50Hz, 60Hz, auto, disabled, or a number)")
    let numeric = UVCControlError.badValue(control: "brightness", text: "loud")
    #expect("\(numeric)" == "'loud' is not a valid brightness value (expected a number)")
}

@Test func usbErrorsShowTheRawIOKitCode() {
    // If launchd USB access ever breaks, that hex code is the whole diagnosis.
    let err = UVCError.openFailed(UVCDeviceID(vendor: 0x046d, product: 0x085b),
                                 IOReturnCode(value: Int32(bitPattern: 0xe00002c9)))
    #expect("\(err)" == "could not open camera 046d:085b: IOKit 0xe00002c9")
    #expect("\(UVCError.deviceGone)" == "camera disconnected")
}

@Test func notKeptOutcomeReadsAsEnglish() {
    #expect(ApplyOutcome.notKept("power-line-frequency", wrote: 1, reads: 2).line
            == "power-line-frequency accepted 50Hz but reads 60Hz")
}

@Test func installerErrorsReadAsEnglish() {
    let failed = AgentInstallerError.launchctlFailed(["bootstrap", "gui/501", "/x.plist"],
                                                     status: 5, output: "Load failed: 5")
    #expect("\(failed)" == "launchctl bootstrap failed (status 5): Load failed: 5 "
                         + "[launchctl bootstrap gui/501 /x.plist]")
    #expect("\(AgentInstallerError.binaryNotFound("/nope/unflicker"))"
            == "cannot find the running unflicker binary (looked at /nope/unflicker)")
}
