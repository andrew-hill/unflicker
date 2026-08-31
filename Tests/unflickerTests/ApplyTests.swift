import Testing
@testable import unflicker

@Test func setsAControlThatIsWrong() throws {
    let (info, connection) = c925e(powerLineFrequency: 2)
    let transport = FakeTransport(infos: [info], connections: [info.id: connection])
    let config = try Config.parse("[default]\npower-line-frequency = 50Hz")

    let results = try Apply.run(transport: transport, config: config, dryRun: false)

    #expect(results == [ApplyResult(device: info.id,
                                    outcomes: [.changed("power-line-frequency", from: 2, to: 1)])])
    #expect(connection.writes.map(\.0) == ["power-line-frequency"])
    #expect(connection.writes.map(\.1) == [1])
}

// Matching is per device, so an attach fires once, but login fires it too,
// and a dock can produce a burst. Re-running must be a no-op either way.
@Test func skipsAControlThatIsAlreadyCorrect() throws {
    let (info, connection) = c925e(powerLineFrequency: 1)
    let transport = FakeTransport(infos: [info], connections: [info.id: connection])
    let config = try Config.parse("[default]\npower-line-frequency = 50Hz")

    let results = try Apply.run(transport: transport, config: config, dryRun: false)

    #expect(results == [ApplyResult(device: info.id,
                                    outcomes: [.alreadyCorrect("power-line-frequency", 1)])])
    #expect(connection.writes.isEmpty)
}

@Test func applyIsIdempotent() throws {
    let (info, connection) = c925e(powerLineFrequency: 2)
    let transport = FakeTransport(infos: [info], connections: [info.id: connection])
    let config = try Config.parse("[default]\npower-line-frequency = 50Hz")

    _ = try Apply.run(transport: transport, config: config, dryRun: false)
    _ = try Apply.run(transport: transport, config: config, dryRun: false)

    #expect(connection.writes.count == 1)
}

@Test func dryRunWritesNothing() throws {
    let (info, connection) = c925e(powerLineFrequency: 2)
    let transport = FakeTransport(infos: [info], connections: [info.id: connection])
    let config = try Config.parse("[default]\npower-line-frequency = 50Hz")

    let results = try Apply.run(transport: transport, config: config, dryRun: true)

    #expect(results == [ApplyResult(device: info.id,
                                    outcomes: [.changed("power-line-frequency", from: 2, to: 1)])])
    #expect(connection.writes.isEmpty)
}

// Never clamp: substituting a value the user did not ask for is worse than
// doing nothing and saying so.
@Test func outOfRangeIsSkippedNotClamped() throws {
    let (info, connection) = c925e()
    let transport = FakeTransport(infos: [info], connections: [info.id: connection])
    let config = try Config.parse("[default]\npower-line-frequency = auto")

    let results = try Apply.run(transport: transport, config: config, dryRun: false)

    #expect(results == [ApplyResult(device: info.id,
                                    outcomes: [.outOfRange("power-line-frequency", 3, 1...2)])])
    #expect(connection.writes.isEmpty)
}

@Test func controlTheCameraDoesNotHaveIsSkipped() throws {
    let (info, connection) = c925e()
    let transport = FakeTransport(infos: [info], connections: [info.id: connection])
    let config = try Config.parse("[default]\ngamma = 100")

    let results = try Apply.run(transport: transport, config: config, dryRun: false)

    #expect(results == [ApplyResult(device: info.id, outcomes: [.unsupported("gamma")])])
    #expect(connection.writes.isEmpty)
}

// A config may be shared across machines, so an unknown name warns rather than
// failing the whole run. `set` is stricter: the user typed that name.
@Test func unknownControlNameWarnsAndContinues() throws {
    let (info, connection) = c925e(powerLineFrequency: 2)
    let transport = FakeTransport(infos: [info], connections: [info.id: connection])
    let config = try Config.parse("""
    [default]
    made-up-control = 5
    power-line-frequency = 50Hz
    """)

    let results = try Apply.run(transport: transport, config: config, dryRun: false)

    #expect(results.count == 1)
    #expect(results[0].outcomes.contains(.unknownControl("made-up-control")))
    #expect(results[0].outcomes.contains(.changed("power-line-frequency", from: 2, to: 1)))
}

@Test func multipleCamerasEachGetTheirOwnSettings() throws {
    let (logitech, logitechConnection) = c925e(powerLineFrequency: 2)
    let otherID = UVCDeviceID(vendor: 0x1234, product: 0x5678)
    let other = UVCDeviceInfo(id: otherID, name: "Other Camera", registryID: 2)
    let otherConnection = FakeConnection(
        supported: ["power-line-frequency"],
        values: ["power-line-frequency": 1],
        ranges: ["power-line-frequency": 0...3]
    )
    let transport = FakeTransport(
        infos: [logitech, other],
        connections: [logitech.id: logitechConnection, otherID: otherConnection]
    )
    let config = try Config.parse("""
    [default]
    power-line-frequency = 50Hz

    [1234:5678]
    power-line-frequency = 60Hz
    """)

    let results = try Apply.run(transport: transport, config: config, dryRun: false)

    #expect(results.count == 2)
    #expect(logitechConnection.values["power-line-frequency"] == 1)
    #expect(otherConnection.values["power-line-frequency"] == 2)
}

// An unplug mid-apply is not a failure: what already applied stands, and the
// run ends quietly. The device has to vanish *after* a control has applied, or
// the test trips the very first read and proves nothing about "mid".
@Test func deviceVanishingMidApplyIsNotAnError() throws {
    let (info, connection) = c925e(powerLineFrequency: 2)
    connection.values["gain"] = 0
    connection.ranges["gain"] = 0...255
    connection.fail(.deviceGone, on: "power-line-frequency")
    let transport = FakeTransport(infos: [info], connections: [info.id: connection])
    let config = try Config.parse("[default]\ngain = 64\npower-line-frequency = 50Hz")

    let results = try Apply.run(transport: transport, config: config, dryRun: false)

    #expect(results == [ApplyResult(device: info.id, outcomes: [.changed("gain", from: 0, to: 64)])])
    #expect(connection.writes.map(\.0) == ["gain"])
}

// The cable can go between the read and the write. Same rule, different catch.
// This needs a `fail` scoped by direction: without one nothing reaches the
// write branch, and deleting that branch leaves the whole suite green.
@Test func deviceVanishingBetweenTheReadAndTheWriteIsNotAnError() throws {
    let (info, connection) = c925e(powerLineFrequency: 2)
    connection.fail(.deviceGone, on: "power-line-frequency", reads: false)
    let transport = FakeTransport(infos: [info], connections: [info.id: connection])
    let config = try Config.parse("[default]\npower-line-frequency = 50Hz")

    let results = try Apply.run(transport: transport, config: config, dryRun: false)

    #expect(results == [ApplyResult(device: info.id, outcomes: [])])
    #expect(connection.writes.isEmpty)
}

@Test func closesTheConnectionEvenWhenNothingChanges() throws {
    let (info, connection) = c925e(powerLineFrequency: 1)
    let transport = FakeTransport(infos: [info], connections: [info.id: connection])
    let config = try Config.parse("[default]\npower-line-frequency = 50Hz")

    _ = try Apply.run(transport: transport, config: config, dryRun: false)

    #expect(connection.closed)
}

// A real USB failure is not an unplug. A `try?` here collapses the two: the
// IOKit code vanishes and apply returns silently.
@Test func aTransferFailureIsReportedWithItsIOKitCode() throws {
    let (info, connection) = c925e(powerLineFrequency: 2)
    connection.fail(.transferFailed(control: "power-line-frequency",
                                    code: IOReturnCode(value: Int32(bitPattern: 0xe00002c9))))
    let transport = FakeTransport(infos: [info], connections: [info.id: connection])
    let config = try Config.parse("[default]\npower-line-frequency = 50Hz")

    let results = try Apply.run(transport: transport, config: config, dryRun: false)

    #expect(results == [ApplyResult(device: info.id, outcomes: [
        .failed("power-line-frequency: USB transfer failed: IOKit 0xe00002c9")])])
    #expect(connection.writes.isEmpty)
}

// The good explanation already exists on UVCControlError. Rebuilding a weaker
// one meant `apply` and `set` disagreed about the same mistake.
@Test func badValueOutcomeCarriesTheFullExplanation() {
    #expect(ApplyOutcome.badValue("power-line-frequency", "55Hz").line
            == "'55Hz' is not a valid power-line-frequency value (expected 50Hz, 60Hz, auto, disabled, or a number), skipped")
}

// The user wrote `auto`; the device speaks in raw integers. Show both.
@Test func outOfRangeOutcomeShowsTheValueTheUserWrote() {
    #expect(ApplyOutcome.outOfRange("power-line-frequency", 3, 1...2).line
            == "power-line-frequency auto (3) outside device range 1..2, skipped")
    #expect(ApplyOutcome.outOfRange("brightness", 999, 0...255).line
            == "brightness 999 outside device range 0..255, skipped")
}

// A camera may STALL any request it does not really implement, whatever its
// bmControls advertises. `apply` walks controls alphabetically, so a stall on
// `gain` must not end the run before power-line-frequency, the one control this
// project exists for, is written.
@Test func aStalledControlIsSkippedSoTheOnesAfterItStillApply() throws {
    let (info, connection) = c925e(powerLineFrequency: 2)
    connection.values["gain"] = 0
    connection.ranges["gain"] = 0...255
    connection.fail(.transferFailed(control: "gain", code: .pipeStalled), on: "gain")
    let transport = FakeTransport(infos: [info], connections: [info.id: connection])
    let config = try Config.parse("[default]\ngain = 64\npower-line-frequency = 50Hz")

    let results = try Apply.run(transport: transport, config: config, dryRun: false)

    #expect(results == [ApplyResult(device: info.id, outcomes: [
        .stalled("gain", .pipeStalled),
        .changed("power-line-frequency", from: 2, to: 1)])])
    #expect(connection.writes.map(\.0) == ["power-line-frequency"])
}

// A device is as free to stall the write as the read. Same rule either way.
@Test func aStalledWriteIsSkippedSoTheControlsAfterItStillApply() throws {
    let (info, connection) = c925e(powerLineFrequency: 2)
    connection.values["gain"] = 0
    connection.ranges["gain"] = 0...255
    connection.fail(.transferFailed(control: "gain", code: .pipeStalled), on: "gain", reads: false)
    let transport = FakeTransport(infos: [info], connections: [info.id: connection])
    let config = try Config.parse("[default]\ngain = 64\npower-line-frequency = 50Hz")

    let results = try Apply.run(transport: transport, config: config, dryRun: false)

    #expect(results == [ApplyResult(device: info.id, outcomes: [
        .stalled("gain", .pipeStalled),
        .changed("power-line-frequency", from: 2, to: 1)])])
    #expect(connection.writes.map(\.0) == ["power-line-frequency"])
}

// The camera claimed the control in bmControls and then refused the request.
// Say both halves, and keep the IOKit code: it is what tells a stall apart
// from a real fault.
@Test func stalledOutcomeSaysTheCameraAdvertisedTheControl() {
    #expect(ApplyOutcome.stalled("gain", .pipeStalled).line
            == "gain advertised but not supported by this camera (IOKit 0xe0005000), skipped")
}

// MARK: - a camera that will not open

private let dellID = UVCDeviceID(vendor: 0x413c, product: 0xd003)
private let dellInfo = UVCDeviceInfo(id: dellID, name: "Dell Monitor Webcam", registryID: 2)

// The whole point of the tool is reapplying on attach. One camera being owned
// by something else must not cost the others their settings, and the writes
// already made must still be reported.
@Test func aCameraThatWillNotOpenDoesNotStopTheOthers() throws {
    let (info, connection) = c925e(powerLineFrequency: 2)
    let code = IOReturnCode(value: Int32(bitPattern: 0xe00002c9))
    let transport = FakeTransport(infos: [dellInfo, info],
                                  connections: [info.id: connection],
                                  openErrors: [dellID: .openFailed(dellID, code)])
    let config = try Config.parse("[default]\npower-line-frequency = 50Hz")

    let results = try Apply.run(transport: transport, config: config, dryRun: false)

    #expect(results == [
        ApplyResult(device: dellID, outcomes: [.notOpened("could not open: IOKit 0xe00002c9")]),
        ApplyResult(device: info.id, outcomes: [.changed("power-line-frequency", from: 2, to: 1)]),
    ])
    #expect(connection.writes.map(\.1) == [1])
}

// A camera with no processing unit has no controls at all, which is the
// whole-device form of `.unsupported`, not a fault. It would otherwise fail
// every run for anyone with an IR sensor enumerating alongside their camera.
@Test func aCameraWithNoProcessingUnitIsSkippedNotFailed() throws {
    let (info, connection) = c925e(powerLineFrequency: 2)
    let transport = FakeTransport(infos: [dellInfo, info],
                                  connections: [info.id: connection],
                                  openErrors: [dellID: .noProcessingUnit(dellID)])
    let config = try Config.parse("[default]\npower-line-frequency = 50Hz")

    let results = try Apply.run(transport: transport, config: config, dryRun: false)

    #expect(results.first == ApplyResult(device: dellID, outcomes: [.noProcessingUnit]))
    #expect(results.map(\.outcomes).flatMap { $0 }.contains { $0.isFault } == false)
    #expect(connection.writes.map(\.1) == [1])
}

@Test func notOpenedOutcomeReadsAsEnglish() {
    #expect(ApplyOutcome.notOpened("could not open: IOKit 0xe00002c9").line
            == "could not open: IOKit 0xe00002c9, skipped")
    #expect(ApplyOutcome.noProcessingUnit.line == "exposes no UVC processing unit, skipped")
}
