import Testing
@testable import unflicker

// Absent means every camera. That is the whole reason a typo must not also
// mean nil: `set --device 413c:dOO3` would write to every camera attached.
@Test func noDeviceFlagMeansEveryCamera() throws {
    #expect(try CLI.deviceFilter(["unflicker", "show"]) == nil)
}

@Test func aDeviceIdIsParsed() throws {
    #expect(try CLI.deviceFilter(["unflicker", "show", "--device", "046d:085b"])
            == UVCDeviceID(vendor: 0x046d, product: 0x085b))
}

@Test func anUnparseableDeviceIdIsRejected() {
    // Capital O for zero: the mistake that has to fail loudly.
    #expect(throws: CLIError.self) {
        try CLI.deviceFilter(["unflicker", "set", "power-line-frequency=60Hz", "--device", "413c:dOO3"])
    }
}

@Test func aTrailingDeviceFlagIsRejected() {
    #expect(throws: CLIError.self) { try CLI.deviceFilter(["unflicker", "show", "--device"]) }
}

@Test func deviceErrorsReadAsEnglish() {
    #expect("\(CLIError.missingValue("--device"))" == "--device needs a value")
    #expect("\(CLIError.badDeviceID("413c:dOO3"))"
            == "'413c:dOO3' is not a vendor:product id like 046d:085b")
}
