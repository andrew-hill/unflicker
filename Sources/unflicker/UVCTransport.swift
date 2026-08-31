import Foundation

struct UVCDeviceID: Hashable, Sendable, CustomStringConvertible {
    let vendor: UInt16
    let product: UInt16

    init(vendor: UInt16, product: UInt16) {
        self.vendor = vendor
        self.product = product
    }

    /// Parses "046d:085b". Config sections use this form, so it has to be
    /// forgiving about case but not about shape.
    init?(_ text: String) {
        let parts = text.split(separator: ":", maxSplits: 1)
        guard parts.count == 2,
              let v = UInt16(parts[0], radix: 16),
              let p = UInt16(parts[1], radix: 16) else { return nil }
        self.init(vendor: v, product: p)
    }

    var description: String { String(format: "%04x:%04x", vendor, product) }
}

struct UVCDeviceInfo: Sendable {
    let id: UVCDeviceID
    let name: String
    /// IORegistry entry id, so a device found by enumeration can be reopened
    /// unambiguously when two identical cameras are attached.
    let registryID: UInt64
}

/// Raw IOKit return code, kept unwrapped so the log shows the real number.
/// If launchd USB access ever does break, that code is the whole diagnosis.
struct IOReturnCode: CustomStringConvertible, Sendable, Equatable {
    let value: Int32
    var description: String { String(format: "0x%08x", UInt32(bitPattern: value)) }

    /// kUSBHostReturnPipeStalled. A control transfer that stalls means the
    /// device does not implement that request. UVC lets it refuse anything it
    /// does not have, including requests its bmControls advertises.
    static let pipeStalled = IOReturnCode(value: Int32(bitPattern: 0xe0005000))

    /// A stall is a refusal, not a fault: the control is skipped and the rest
    /// of the run carries on. Anything else stops it. Three call sites have to
    /// agree on that, so the test lives here.
    var isStall: Bool { self == .pipeStalled }
}

enum UVCError: Error {
    case enumerationFailed(IOReturnCode)
    case openFailed(UVCDeviceID, IOReturnCode)
    case transferFailed(control: String, code: IOReturnCode)
    /// A successful transfer that moved fewer bytes than the data phase. USB
    /// lets a device end the data stage short, so IOKit reports no error and
    /// the untouched bytes decode as 0: `disabled` for power-line-frequency,
    /// which `apply` reads as the value it wanted. No IOReturnCode because
    /// IOKit produced none.
    case shortTransfer(control: String, expected: Int, moved: Int)
    case noProcessingUnit(UVCDeviceID)
    case deviceGone
}

protocol UVCTransport {
    func devices() throws -> [UVCDeviceInfo]
    func open(_ device: UVCDeviceInfo) throws -> any UVCConnection
}

protocol UVCConnection {
    /// Control names this camera advertises in its Processing Unit bmControls.
    var supported: Set<String> { get }
    func current(_ control: UVCControl) throws -> Int
    /// Must not go to the wire for a control the catalogue marks `isBoolean`:
    /// UVC does not require a device to answer GET_MIN for one, and some
    /// STALL it. Answer 0...1 from the catalogue instead.
    func range(_ control: UVCControl) throws -> ClosedRange<Int>
    func set(_ control: UVCControl, to value: Int) throws
    func close()
}

extension UVCError: CustomStringConvertible {
    var description: String {
        switch self {
        case let .enumerationFailed(code):
            return "could not enumerate USB devices: IOKit \(code)"
        case let .openFailed(id, code):
            return "could not open camera \(id): IOKit \(code)"
        case let .transferFailed(control, code):
            return "\(control): USB transfer failed: IOKit \(code)"
        case let .shortTransfer(control, expected, moved):
            return "\(control): USB transfer moved \(moved) of \(expected) bytes"
        case let .noProcessingUnit(id):
            return "camera \(id) exposes no UVC processing unit"
        case .deviceGone:
            return "camera disconnected"
        }
    }
}
