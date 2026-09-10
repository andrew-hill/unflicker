import Testing
@testable import UVCCore
@testable import unflicker

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

