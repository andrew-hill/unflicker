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

// MARK: - one camera failing must not cost the others

private let dellID = UVCDeviceID(vendor: 0x413c, product: 0xd003)
private let dellInfo = UVCDeviceInfo(id: dellID, name: "Dell Monitor Webcam", registryID: 2)

// Same shape as `apply`, for the same reason: a bare `try` here threw away the
// write already made to the camera before it, so the user was told the command
// failed and never told what had already changed.
@Test func setOnACameraThatWillNotOpenStillWritesToTheOthers() throws {
    let (info, connection) = c925e(powerLineFrequency: 2)
    let code = IOReturnCode(value: Int32(bitPattern: 0xe00002c9))
    let transport = FakeTransport(infos: [dellInfo, info],
                                  connections: [info.id: connection],
                                  openErrors: [dellID: .openFailed(dellID, code)])

    let results = try CLI.setOnce(transport, control: powerLineFrequency, value: 1, device: nil)

    #expect(results == [
        ApplyResult(device: dellID, outcomes: [.notOpened("could not open: IOKit 0xe00002c9")]),
        ApplyResult(device: info.id, outcomes: [.wrote("power-line-frequency", 1)]),
    ])
    #expect(connection.writes.map(\.1) == [1])
}

// The write did happen on one camera, and did not on the other. `set` is one
// request the user typed, so it did not do what was asked.
@Test func setExitsNonZeroWhenOnlySomeCamerasTookIt() {
    let (info, connection) = c925e(powerLineFrequency: 2)
    let transport = FakeTransport(infos: [dellInfo, info],
                                  connections: [info.id: connection],
                                  openErrors: [dellID: .openFailed(dellID, IOReturnCode(value: 0))])

    let status = CLI.setControl(transport, assignment: "power-line-frequency=50Hz", device: nil)

    #expect(status != 0)
    #expect(connection.writes.map(\.1) == [1])
}

// A stall is the camera refusing a control it advertised, which `apply` already
// reports and skips. Reported in the same words here, and it does not take the
// next camera down with it.
@Test func setOnACameraThatStallsStillWritesToTheOthers() throws {
    let (info, connection) = c925e(powerLineFrequency: 2)
    let stalling = FakeConnection(supported: ["power-line-frequency"],
                                  values: ["power-line-frequency": 2],
                                  ranges: ["power-line-frequency": 1...2])
    stalling.fail(.transferFailed(control: "power-line-frequency", code: .pipeStalled))
    let transport = FakeTransport(infos: [dellInfo, info],
                                  connections: [dellID: stalling, info.id: connection])

    let results = try CLI.setOnce(transport, control: powerLineFrequency, value: 1, device: nil)

    #expect(results == [
        ApplyResult(device: dellID, outcomes: [.stalled("power-line-frequency", .pipeStalled)]),
        ApplyResult(device: info.id, outcomes: [.wrote("power-line-frequency", 1)]),
    ])
    #expect(connection.writes.map(\.1) == [1])
}

// The camera was there and then was not, which is the hot-plug case the tool
// exists for. Dropping it from the results made `setControl` fall through to
// "no matching camera" - a camera that did match, reported as one that did not.
@Test func aCameraVanishingMidWriteIsReportedNotReadAsNoMatch() throws {
    let (info, connection) = c925e(powerLineFrequency: 2)
    connection.fail(.deviceGone)
    let transport = FakeTransport(infos: [info], connections: [info.id: connection])

    let results = try CLI.setOnce(transport, control: powerLineFrequency, value: 1, device: nil)

    #expect(results == [ApplyResult(device: info.id, outcomes: [.notOpened("camera disconnected")])])
    #expect(results.isEmpty == false)
}

@Test func aCameraVanishingBeforeItOpensIsReportedNotReadAsNoMatch() throws {
    let (info, connection) = c925e()
    let transport = FakeTransport(infos: [info], connections: [info.id: connection],
                                  openErrors: [info.id: .deviceGone])

    let results = try CLI.setOnce(transport, control: powerLineFrequency, value: 1, device: nil)

    #expect(results == [ApplyResult(device: info.id, outcomes: [.notOpened("camera disconnected")])])
}

// `set` reported the value it sent, not the value the camera holds. It reads
// back for the same reason `apply` does.
@Test func setReportsAWriteTheCameraDoesNotKeep() throws {
    let (info, connection) = c925e(powerLineFrequency: 2)
    connection.discards = ["power-line-frequency"]
    let transport = FakeTransport(infos: [info], connections: [info.id: connection])

    let results = try CLI.setOnce(transport, control: powerLineFrequency, value: 1, device: nil)

    #expect(results == [ApplyResult(device: info.id,
                                    outcomes: [.notKept("power-line-frequency", wrote: 1, reads: 2)])])
    // Not a write, so setControl exits 1 rather than reporting success.
    #expect(results[0].outcomes[0].isWrite == false)
}
