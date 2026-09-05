import Foundation
import Testing
@testable import unflicker

// Hardware cross-check: the point of a second transport is that it disagrees
// when one of them is wrong. `UNFLICKER_HW=413c:d003 swift test` runs these
// against that camera; without the variable they are reported as skipped.

private var hardwareID: String? {
    ProcessInfo.processInfo.environment["UNFLICKER_HW"]
}

private func requiredDevice() throws -> UVCDeviceID {
    let text = try #require(hardwareID)
    return try #require(UVCDeviceID(text),
                        "UNFLICKER_HW is \(text), not a vendor:product hex pair")
}

private struct Reading: Equatable, CustomStringConvertible {
    let name: String
    let current: Int
    let range: ClosedRange<Int>
    var description: String { "\(name) = \(current) [\(range)]" }
}

// The transports are opened one after the other, never together: IOUSBLib's
// open is exclusive per user client and the test is not about contention.
private func readings(_ transport: any UVCTransport, _ id: UVCDeviceID) throws -> [Reading] {
    let info = try #require(try transport.devices().first { $0.id == id },
                            "\(id) is not attached")
    let connection = try transport.open(info)
    defer { connection.close() }
    var result: [Reading] = []
    for name in connection.supported.sorted() {
        let control = try #require(UVCControl.all.first { $0.name == name })
        result.append(Reading(name: name,
                              current: try connection.current(control),
                              range: try connection.range(control)))
    }
    return result
}

// Serialized: opening the camera is exclusive, so two tests holding it at
// once fail each other with 0xe00002c5 rather than telling us anything.
@Suite(.serialized) struct TransportCrossCheck {
    @Test(.enabled(if: hardwareID != nil))
    func transportsAgreeOnEveryControl() throws {
        let id = try requiredDevice()
        let host = try readings(IOUSBHostTransport(), id)
        let lib = try readings(IOUSBLibTransport(), id)
        #expect(!host.isEmpty)
        #expect(host == lib)
    }

    // Writes back the value just read, so the camera is left as it was. This
    // is the only execution of IOUSBLibTransport.set before the app exists.
    @Test(.enabled(if: hardwareID != nil))
    func writeBackLandsThroughBothTransports() throws {
        let id = try requiredDevice()
        let control = try #require(UVCControl.all.first { $0.name == "power-line-frequency" })
        for transport: any UVCTransport in [IOUSBHostTransport(), IOUSBLibTransport()] {
            let info = try #require(try transport.devices().first { $0.id == id },
                                    "\(id) is not attached")
            let connection = try transport.open(info)
            defer { connection.close() }
            let value = try connection.current(control)
            try connection.set(control, to: value)
            #expect(try connection.current(control) == value)
        }
    }
}
