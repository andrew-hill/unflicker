import Foundation
import Testing
@testable import unflicker

private let gamma = UVCControl.named("gamma")!
private let powerLineFrequency = UVCControl.named("power-line-frequency")!

// A camera matched; it just could not do what was asked. Reporting both
// "046d:085b: gamma not supported by this camera" and "no matching camera" in
// the same breath contradicts itself.
@Test func setOnAnUnsupportedControlStillReportsTheCameraItMatched() throws {
    let (info, connection) = c925e()
    let transport = FakeTransport(infos: [info], connections: [info.id: connection])

    let results = try CLI.setOnce(transport, control: gamma, value: 100, device: nil)

    #expect(results == [ApplyResult(device: info.id, outcomes: [.unsupported("gamma")])])
    #expect(connection.writes.isEmpty)
}

@Test func setWithADeviceFilterMatchingNothingReturnsNoResults() throws {
    let (info, connection) = c925e()
    let transport = FakeTransport(infos: [info], connections: [info.id: connection])

    let results = try CLI.setOnce(transport, control: powerLineFrequency, value: 1,
                                  device: UVCDeviceID(vendor: 0x9999, product: 0x9999))

    #expect(results.isEmpty)
    #expect(connection.writes.isEmpty)
}

// Same condition, same wording as `apply`. Two paths, and only one of them
// naming the control, is how they drift.
@Test func setOutOfRangeUsesTheSameWordingAsApply() throws {
    let (info, connection) = c925e()
    let transport = FakeTransport(infos: [info], connections: [info.id: connection])

    let results = try CLI.setOnce(transport, control: powerLineFrequency, value: 3, device: nil)

    #expect(results == [ApplyResult(device: info.id,
                                    outcomes: [.outOfRange("power-line-frequency", 3, 1...2)])])
    #expect(connection.writes.isEmpty)
}

@Test func setReportsTheFriendlyValueItWrote() throws {
    let (info, connection) = c925e(powerLineFrequency: 2)
    let transport = FakeTransport(infos: [info], connections: [info.id: connection])

    let results = try CLI.setOnce(transport, control: powerLineFrequency, value: 1, device: nil)

    #expect(results == [ApplyResult(device: info.id, outcomes: [.wrote("power-line-frequency", 1)])])
    #expect(results[0].outcomes[0].line == "power-line-frequency = 50Hz")
    #expect(connection.writes.map(\.1) == [1])
}

// MARK: - exit status

// `set` is one explicit request. Printing "not supported by this camera" and
// exiting 0 tells a script the write happened.
@Test func setExitsNonZeroWhenTheControlIsUnsupported() {
    let (info, connection) = c925e()
    let transport = FakeTransport(infos: [info], connections: [info.id: connection])

    let status = CLI.setControl(transport, assignment: "gamma=100", device: nil)

    #expect(status != 0)
    #expect(connection.writes.isEmpty)
}

@Test func setExitsNonZeroWhenTheValueIsOutOfRange() {
    let (info, connection) = c925e()
    let transport = FakeTransport(infos: [info], connections: [info.id: connection])

    // The C925e answers 1...2, so `auto` is not a value it has.
    let status = CLI.setControl(transport, assignment: "power-line-frequency=auto", device: nil)

    #expect(status != 0)
    #expect(connection.writes.isEmpty)
}

@Test func setExitsZeroWhenItWrote() {
    let (info, connection) = c925e(powerLineFrequency: 2)
    let transport = FakeTransport(infos: [info], connections: [info.id: connection])

    let status = CLI.setControl(transport, assignment: "power-line-frequency=50Hz", device: nil)

    #expect(status == 0)
    #expect(connection.writes.map(\.1) == [1])
}

// Same class again: the camera the user named is not attached, so the write
// they asked for did not happen.
@Test func setExitsNonZeroWhenNoCameraMatches() {
    let (info, connection) = c925e()
    let transport = FakeTransport(infos: [info], connections: [info.id: connection])

    let status = CLI.setControl(transport, assignment: "power-line-frequency=50Hz",
                                device: UVCDeviceID(vendor: 0x9999, product: 0x9999))

    #expect(status != 0)
    #expect(connection.writes.isEmpty)
}
