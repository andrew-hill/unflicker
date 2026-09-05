import Foundation
import UVCCore
import IOKit
import CUSBLegacy

/// The transport the App Sandbox permits. com.apple.security.device.usb opens
/// the legacy IOUSBFamily user client, not IOUSBHost's — the sandboxed app
/// talks through this; the CLI stays on IOUSBHostTransport. Both are
/// permanent: the day IOUSBLib is removed, the CLI still works and the app is
/// what breaks.
struct IOUSBLibTransport: UVCTransport {
    func devices() throws -> [UVCDeviceInfo] {
        try USBEnumeration.cameras()
    }

    func open(_ device: UVCDeviceInfo) throws -> any UVCConnection {
        let service = USBEnumeration.service(withRegistryID: device.registryID)
        guard service != 0 else { throw UVCError.deviceGone }
        defer { IOObjectRelease(service) }
        return try IOUSBLibConnection(service: service, id: device.id)
    }
}

final class IOUSBLibConnection: UVCConnection {
    private let device: UnsafeMutablePointer<UnsafeMutablePointer<IOUSBDeviceInterface>?>
    private let unitID: UInt8
    private let interfaceNumber: UInt8
    private let controlBits: UInt32

    init(service: io_service_t, id: UVCDeviceID) throws {
        var code: IOReturn = kIOReturnSuccess
        guard let dev = CUSBLegacyCreateDeviceInterface(service, &code) else {
            throw UVCError.openFailed(id, IOReturnCode(value: code))
        }
        let opened = dev.pointee!.pointee.USBDeviceOpen(dev)
        guard opened == kIOReturnSuccess else {
            CUSBLegacyDestroyDeviceInterface(dev)
            throw UVCError.openFailed(id, IOReturnCode(value: opened))
        }

        var descriptor: IOUSBConfigurationDescriptorPtr?
        let fetched = dev.pointee!.pointee.GetConfigurationDescriptorPtr(dev, 0, &descriptor)
        guard fetched == kIOReturnSuccess, let descriptor,
              let unit = ConfigurationDescriptor.processingUnit(Self.bytes(of: descriptor)) else {
            _ = dev.pointee!.pointee.USBDeviceClose(dev)
            CUSBLegacyDestroyDeviceInterface(dev)
            throw UVCError.noProcessingUnit(id)
        }

        device = dev
        unitID = unit.id
        interfaceNumber = unit.interface
        controlBits = unit.controls
    }

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
        var payload = [UInt8](repeating: 0, count: control.length)
        let raw = UInt32(bitPattern: Int32(value))
        for byte in 0..<control.length {
            payload[byte] = UInt8((raw >> (8 * UInt32(byte))) & 0xff)
        }
        let moved = try transfer(control, bmRequestType: 0x21, bRequest: 0x01,  // SET_CUR
                                 payload: &payload)
        guard moved == control.length else {
            throw UVCError.shortTransfer(control: control.name, expected: control.length, moved: moved)
        }
    }

    private func read(_ control: UVCControl, bRequest: UInt8) throws -> Int {
        var payload = [UInt8](repeating: 0, count: control.length)
        let moved = try transfer(control, bmRequestType: 0xA1, bRequest: bRequest,
                                 payload: &payload)
        guard moved == control.length else {
            throw UVCError.shortTransfer(control: control.name, expected: control.length, moved: moved)
        }
        var raw: UInt32 = 0
        for (index, byte) in payload.enumerated() { raw |= UInt32(byte) << (8 * UInt32(index)) }
        if control.signed && control.length == 2 {
            return Int(Int16(bitPattern: UInt16(truncatingIfNeeded: raw)))
        }
        return Int(raw)
    }

    /// Returns wLenDone. IOKit reports success on a transfer the device ended
    /// short, so the byte count is part of the result, not a detail.
    private func transfer(_ control: UVCControl, bmRequestType: UInt8, bRequest: UInt8,
                          payload: inout [UInt8]) throws -> Int {
        var request = IOUSBDevRequest(
            bmRequestType: bmRequestType,
            bRequest: bRequest,
            wValue: UInt16(control.selector) << 8,
            wIndex: (UInt16(unitID) << 8) | UInt16(interfaceNumber),
            wLength: UInt16(control.length),
            pData: nil,
            wLenDone: 0)
        let status = payload.withUnsafeMutableBytes { bytes -> IOReturn in
            request.pData = bytes.baseAddress
            return device.pointee!.pointee.DeviceRequest(device, &request)
        }
        guard status == kIOReturnSuccess else {
            throw UVCError.transferFailed(control: control.name, code: IOReturnCode(value: status))
        }
        return Int(request.wLenDone)
    }

    func close() {
        _ = device.pointee!.pointee.USBDeviceClose(device)
        CUSBLegacyDestroyDeviceInterface(device)
    }
}
