import Foundation
@testable import UVCCore
@testable import unflicker

final class FakeConnection: UVCConnection {
    var supported: Set<String>
    var values: [String: Int]
    var ranges: [String: ClosedRange<Int>]
    /// Every set() that reached the device, in order. Tests assert on this to
    /// prove skip-if-correct actually skips.
    private(set) var writes: [(String, Int)] = []
    var closed = false
    /// Controls the camera ACKs a write for and then does not keep. The C925e
    /// did this to `power-line-frequency`; see docs/hardware.md.
    var discards: Set<String> = []

    private struct Failure {
        let error: UVCError
        /// nil fails every control: the device vanished. A name fails only
        /// that one, which is what a camera stalling a request it does not
        /// really implement looks like.
        let control: String?
        let reads: Bool
        let writes: Bool
    }
    private var failure: Failure?

    /// Makes transfers fail. Scoped by control and by direction so a test can
    /// say "the read works, the write does not". A whole-connection switch
    /// cannot express either of the two hardware bugs found on the Dell.
    func fail(_ error: UVCError, on control: String? = nil, reads: Bool = true, writes: Bool = true) {
        failure = Failure(error: error, control: control, reads: reads, writes: writes)
    }

    private func failureFor(_ control: UVCControl, writing: Bool) -> UVCError? {
        guard let failure, failure.control == nil || failure.control == control.name else { return nil }
        return (writing ? failure.writes : failure.reads) ? failure.error : nil
    }

    init(supported: Set<String>, values: [String: Int], ranges: [String: ClosedRange<Int>]) {
        self.supported = supported
        self.values = values
        self.ranges = ranges
    }

    func current(_ control: UVCControl) throws -> Int {
        if let error = failureFor(control, writing: false) { throw error }
        guard let v = values[control.name] else { throw UVCError.deviceGone }
        return v
    }

    func range(_ control: UVCControl) throws -> ClosedRange<Int> {
        if let error = failureFor(control, writing: false) { throw error }
        guard let r = ranges[control.name] else { throw UVCError.deviceGone }
        return r
    }

    func set(_ control: UVCControl, to value: Int) throws {
        if let error = failureFor(control, writing: true) { throw error }
        writes.append((control.name, value))
        guard !discards.contains(control.name) else { return }
        values[control.name] = value
    }

    func close() { closed = true }
}

struct FakeTransport: UVCTransport {
    var infos: [UVCDeviceInfo]
    var connections: [UVCDeviceID: FakeConnection]
    /// Cameras that enumerate and then refuse to open. A camera with no entry
    /// in `connections` already throws openFailed; this is for choosing which
    /// error, since apply treats them differently.
    var openErrors: [UVCDeviceID: UVCError] = [:]

    func devices() throws -> [UVCDeviceInfo] { infos }

    func open(_ device: UVCDeviceInfo) throws -> any UVCConnection {
        if let error = openErrors[device.id] { throw error }
        guard let c = connections[device.id] else {
            throw UVCError.openFailed(device.id, IOReturnCode(value: 0))
        }
        return c
    }
}

/// A stand-in for the C925e, with the exact ranges read off the real device.
func c925e(powerLineFrequency: Int = 2, brightness: Int = 128) -> (UVCDeviceInfo, FakeConnection) {
    let id = UVCDeviceID(vendor: 0x046d, product: 0x085b)
    let info = UVCDeviceInfo(id: id, name: "Logitech Webcam C925e", registryID: 1)
    let conn = FakeConnection(
        supported: ["power-line-frequency", "brightness", "contrast", "saturation",
                    "sharpness", "white-balance-temperature", "backlight-compensation",
                    "gain", "white-balance-temperature-auto"],
        values: ["power-line-frequency": powerLineFrequency, "brightness": brightness],
        ranges: ["power-line-frequency": 1...2, "brightness": 0...255]
    )
    return (info, conn)
}
