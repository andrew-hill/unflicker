import Testing
@testable import unflicker

private func dell() -> FakeConnection {
    // The Dell 413c:d003, cut down to two controls: it STALLs
    // white-balance-temperature-auto's GET_MIN but answers everything else.
    FakeConnection(supported: ["gain", "power-line-frequency"],
                   values: ["gain": 0, "power-line-frequency": 2],
                   ranges: ["gain": 0...255, "power-line-frequency": 1...2])
}

// One control the camera does not really implement must not hide the value of
// every other control, or take the listing down before the device header.
@Test func showListsTheOtherControlsWhenOneStalls() throws {
    let connection = dell()
    connection.fail(.transferFailed(control: "gain", code: .pipeStalled), on: "gain")

    #expect(try CLI.controlLines(connection) == [
        "gain advertised but not supported by this camera (IOKit 0xe0005000), skipped",
        "power-line-frequency = 60Hz  [1..2]",
    ])
}

// Tolerance is for stalls only. A transfer failing for any other reason is a
// real fault and still has to stop the command.
@Test func showStillFailsOnAnErrorThatIsNotAStall() {
    let connection = dell()
    connection.fail(.transferFailed(control: "gain",
                                    code: IOReturnCode(value: Int32(bitPattern: 0xe00002c9))))

    #expect(throws: UVCError.self) { try CLI.controlLines(connection) }
}

// MARK: - exit status

// An empty bus is not an error. A --device the user typed that matches nothing
// is, and it is the same condition `set` already exits 1 for.
@Test func showWithADeviceFilterMatchingNothingExitsNonZero() {
    let (info, connection) = c925e()
    let transport = FakeTransport(infos: [info], connections: [info.id: connection])

    let status = CLI.showControls(transport, device: UVCDeviceID(vendor: 0x9999, product: 0x9999))

    #expect(status != 0)
}

@Test func showWithNoCamerasAtAllIsNotAnError() {
    #expect(CLI.showControls(FakeTransport(infos: [], connections: [:]), device: nil) == 0)
}

@Test func showExitsZeroWhenTheDeviceFilterMatches() {
    let (info, _) = c925e()
    let transport = FakeTransport(infos: [info], connections: [info.id: dell()])

    #expect(CLI.showControls(transport, device: info.id) == 0)
}
