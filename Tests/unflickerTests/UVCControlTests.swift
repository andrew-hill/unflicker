import Testing
@testable import UVCCore
@testable import unflicker

@Test func lookupByName() {
    #expect(UVCControl.named("power-line-frequency")?.selector == 0x05)
    #expect(UVCControl.named("brightness")?.selector == 0x02)
    #expect(UVCControl.named("nonsense") == nil)
}

@Test func friendlyValuesMapToRaw() throws {
    let plf = UVCControl.named("power-line-frequency")!
    #expect(try plf.parse("50Hz") == 1)
    #expect(try plf.parse("60Hz") == 2)
    #expect(try plf.parse("disabled") == 0)
    #expect(try plf.parse("auto") == 3)
}

@Test func friendlyValuesAreCaseInsensitive() throws {
    let plf = UVCControl.named("power-line-frequency")!
    #expect(try plf.parse("50hz") == 1)
    #expect(try plf.parse("50HZ") == 1)
}

@Test func rawNumbersStillParse() throws {
    let plf = UVCControl.named("power-line-frequency")!
    #expect(try plf.parse("1") == 1)
    #expect(try UVCControl.named("brightness")!.parse("128") == 128)
}

@Test func nonsenseValueThrows() {
    let plf = UVCControl.named("power-line-frequency")!
    #expect(throws: UVCControlError.self) { try plf.parse("55Hz") }
}

@Test func formatPrefersTheFriendlyName() {
    let plf = UVCControl.named("power-line-frequency")!
    #expect(plf.format(1) == "50Hz")
    // The C925e rejects 0 and 3, but a value the device somehow reports and the
    // map doesn't cover must still print as something.
    #expect(UVCControl.named("brightness")!.format(128) == "128")
}

@Test func bitPositionsMatchTheUVCSpec() {
    // Confirmed against a C925e: bmControls 0x175b, which has D10 set and the
    // camera does support power-line-frequency.
    #expect(UVCControl.named("power-line-frequency")?.bit == 10)
    #expect(UVCControl.named("brightness")?.bit == 0)
    #expect(UVCControl.named("white-balance-temperature")?.bit == 6)
}

// UVC mandates only GET_CUR, SET_CUR, GET_DEF and GET_INFO for a boolean
// control, so GET_MIN is entitled to STALL. The Dell 413c:d003 does, with
// 0xe0005000, on white-balance-temperature-auto. A boolean is 0...1 by
// definition and nothing has to ask the device.
@Test func booleanControlsAreFlaggedSoTheirRangeIsNeverProbed() {
    #expect(UVCControl.all.filter(\.isBoolean).map(\.name) == ["white-balance-temperature-auto"])
}
