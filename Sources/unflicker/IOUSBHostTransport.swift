import Foundation
import UVCCore
import IOKit
import IOUSBHost

struct IOUSBHostTransport: UVCTransport {
    func devices() throws -> [UVCDeviceInfo] {
        try USBEnumeration.cameras()
    }

    func open(_ device: UVCDeviceInfo) throws -> any UVCConnection {
        let service = USBEnumeration.service(withRegistryID: device.registryID)
        guard service != 0 else { throw UVCError.deviceGone }
        defer { IOObjectRelease(service) }
        return try IOUSBHostConnection(service: service, id: device.id)
    }
}

/// Talks to the camera's default control endpoint.
///
/// It has to be the *device*, not the VideoControl interface: macOS's own UVC
/// driver already owns that interface, so IOUSBHostInterface's init fails with
/// kIOReturnInternalError (0xe00002c9, "Failed [super init]"). Opening the
/// device needs no privileges and no entitlement, and leaves video capture
/// working. Init options stay empty for the same reason: DeviceCapture and
/// DeviceSeize both evict the camera's other drivers.
final class IOUSBHostConnection: UVCConnection {
    private let device: IOUSBHostDevice
    private let unitID: UInt8
    private let interfaceNumber: UInt8
    private let controlBits: UInt32

    init(service: io_service_t, id: UVCDeviceID) throws {
        do {
            device = try IOUSBHostDevice(__ioService: service, options: [], queue: nil, interestHandler: nil)
        } catch let error as NSError {
            throw UVCError.openFailed(id, IOReturnCode(value: Int32(truncatingIfNeeded: error.code)))
        }
        guard let descriptor = device.configurationDescriptor,
              let unit = ConfigurationDescriptor.processingUnit(Self.bytes(of: descriptor)) else {
            device.destroy()
            throw UVCError.noProcessingUnit(id)
        }
        unitID = unit.id
        interfaceNumber = unit.interface
        controlBits = unit.controls
    }

    /// IOUSBHost fetched the whole descriptor, so its buffer really is
    /// wTotalLength long; the walk re-checks the field against the copy anyway.
    private static func bytes(
        of configuration: UnsafePointer<IOUSBConfigurationDescriptor>
    ) -> [UInt8] {
        Array(UnsafeRawBufferPointer(start: configuration,
                                     count: Int(UInt16(configuration.pointee.wTotalLength))))
    }

    var supported: Set<String> {
        Set(UVCControl.all.filter { controlBits & (1 << UInt32($0.bit)) != 0 }.map(\.name))
    }

    func current(_ control: UVCControl) throws -> Int {
        try read(control, bRequest: 0x81)    // GET_CUR
    }

    func range(_ control: UVCControl) throws -> ClosedRange<Int> {
        // A boolean has no GET_MIN to ask for; asking anyway is what made the
        // Dell STALL with 0xe0005000 and take `show` down with it.
        if control.isBoolean { return 0...1 }
        let low = try read(control, bRequest: 0x82)   // GET_MIN
        let high = try read(control, bRequest: 0x83)  // GET_MAX
        return low...max(low, high)
    }

    func set(_ control: UVCControl, to value: Int) throws {
        let request = IOUSBDeviceRequest(
            bmRequestType: 0x21,                // host to device, class, interface
            bRequest: 0x01,                     // SET_CUR
            wValue: UInt16(control.selector) << 8,
            wIndex: (UInt16(unitID) << 8) | UInt16(interfaceNumber),
            wLength: UInt16(control.length)
        )
        let payload = NSMutableData(length: control.length)!
        let raw = UInt32(bitPattern: Int32(value))
        let out = payload.mutableBytes.assumingMemoryBound(to: UInt8.self)
        for byte in 0..<control.length {
            out[byte] = UInt8((raw >> (8 * UInt32(byte))) & 0xff)
        }
        var moved = 0
        do {
            try device.__send(request, data: payload, bytesTransferred: &moved, completionTimeout: 2.0)
        } catch let error as NSError {
            throw UVCError.transferFailed(control: control.name,
                                          code: IOReturnCode(value: Int32(truncatingIfNeeded: error.code)))
        }
        guard moved == control.length else {
            throw UVCError.shortTransfer(control: control.name, expected: control.length, moved: moved)
        }
    }

    private func read(_ control: UVCControl, bRequest: UInt8) throws -> Int {
        let request = IOUSBDeviceRequest(
            bmRequestType: 0xA1,                // device to host, class, interface
            bRequest: bRequest,
            wValue: UInt16(control.selector) << 8,
            wIndex: (UInt16(unitID) << 8) | UInt16(interfaceNumber),
            wLength: UInt16(control.length)
        )
        let payload = NSMutableData(length: control.length)!
        var moved = 0
        do {
            try device.__send(request, data: payload, bytesTransferred: &moved, completionTimeout: 2.0)
        } catch let error as NSError {
            throw UVCError.transferFailed(control: control.name,
                                          code: IOReturnCode(value: Int32(truncatingIfNeeded: error.code)))
        }
        guard moved == control.length else {
            throw UVCError.shortTransfer(control: control.name, expected: control.length, moved: moved)
        }
        let bytes = [UInt8](Data(referencing: payload))
        var raw: UInt32 = 0
        for (index, byte) in bytes.enumerated() { raw |= UInt32(byte) << (8 * UInt32(index)) }
        if control.signed && control.length == 2 {
            return Int(Int16(bitPattern: UInt16(truncatingIfNeeded: raw)))
        }
        return Int(raw)
    }

    func close() { device.destroy() }
}
