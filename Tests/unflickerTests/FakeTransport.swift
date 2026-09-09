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
func c925e(powerLineFrequency: Int = 2) -> (UVCDeviceInfo, FakeConnection) {
    let id = UVCDeviceID(vendor: 0x046d, product: 0x085b)
    let info = UVCDeviceInfo(id: id, name: "Logitech Webcam C925e", registryID: 1)
    let conn = FakeConnection(
        supported: ["power-line-frequency", "brightness", "contrast", "saturation",
                    "sharpness", "white-balance-temperature", "backlight-compensation",
                    "gain", "white-balance-temperature-auto"],
        values: ["power-line-frequency": powerLineFrequency, "brightness": 128],
        ranges: ["power-line-frequency": 1...2, "brightness": 0...255]
    )
    return (info, conn)
}

/// Reports no devices until the `appearOnCall`th call, and counts the calls.
/// Drives the readiness backoff without waiting on anything real, and proves
/// `apply` enumerates once rather than twice.
struct CountingTransport: UVCTransport {
    final class Counter: @unchecked Sendable { var calls = 0 }
    var appearOnCall = 1
    let info: UVCDeviceInfo
    var connection: FakeConnection?
    let counter = Counter()

    func devices() throws -> [UVCDeviceInfo] {
        counter.calls += 1
        return counter.calls >= appearOnCall ? [info] : []
    }

    func open(_ device: UVCDeviceInfo) throws -> any UVCConnection {
        guard let connection else { throw UVCError.deviceGone }
        return connection
    }
}

/// Fails enumeration outright, the way a broken IOKit lookup would.
struct BrokenTransport: UVCTransport {
    func devices() throws -> [UVCDeviceInfo] { throw UVCError.deviceGone }
    func open(_ device: UVCDeviceInfo) throws -> any UVCConnection { throw UVCError.deviceGone }
}

/// Hands `body` a config file in a directory of its own and removes the
/// directory afterwards. `contents` nil leaves the path empty, for the tests
/// that write their own bytes. A file left at mode 0o000 still unlinks, so the
/// permission tests need no restore of their own.
func withConfigFile<T>(_ contents: String?, _ body: (URL) throws -> T) rethrows -> T {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("unflicker-tests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("unflicker.conf")
    if let contents { try! contents.write(to: path, atomically: true, encoding: .utf8) }
    defer { try? FileManager.default.removeItem(at: dir) }
    return try body(path)
}
