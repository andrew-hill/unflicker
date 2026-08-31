import Foundation
import IOKit
import IOUSBHost

struct IOUSBHostTransport: UVCTransport {
    func devices() throws -> [UVCDeviceInfo] {
        // Match the VideoControl interface so only actual cameras are listed,
        // then walk up to the parent device. See IOUSBHostConnection for why
        // the device, not the interface, is what we end up talking to.
        let match = IOServiceMatching("IOUSBHostInterface") as NSMutableDictionary
        match["bInterfaceClass"] = 14   // USB Video
        match["bInterfaceSubClass"] = 1 // VideoControl

        var iterator: io_iterator_t = 0
        // Not `return []`: a lookup that fails is a fault, and reporting it as
        // an empty bus is indistinguishable from no camera being plugged in.
        let status = IOServiceGetMatchingServices(kIOMainPortDefault, match, &iterator)
        guard status == KERN_SUCCESS else {
            throw UVCError.enumerationFailed(IOReturnCode(value: status))
        }
        defer { IOObjectRelease(iterator) }

        var found: [UVCDeviceInfo] = []
        var seen: Set<UInt64> = []
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iterator) }
            var parent: io_service_t = 0
            guard IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(parent) }
            guard let info = Self.describe(parent) else { continue }
            // RGB and IR are separate video functions under one device (UVC
            // 1.5 2.4), each with its own VideoControl interface, both walking
            // up to this parent.
            guard seen.insert(info.registryID).inserted else { continue }
            found.append(info)
        }
        return found
    }

    static func describe(_ device: io_service_t) -> UVCDeviceInfo? {
        func property(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(device, key as CFString, nil, 0)?.takeRetainedValue()
        }
        guard let vendor = property("idVendor") as? Int,
              let product = property("idProduct") as? Int else { return nil }
        var registryID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(device, &registryID) == KERN_SUCCESS else { return nil }
        return UVCDeviceInfo(
            id: UVCDeviceID(vendor: UInt16(vendor), product: UInt16(product)),
            name: property("USB Product Name") as? String ?? "unknown camera",
            registryID: registryID
        )
    }

    func open(_ device: UVCDeviceInfo) throws -> any UVCConnection {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IORegistryEntryIDMatching(device.registryID))
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
              let unit = Self.processingUnit(descriptor) else {
            device.destroy()
            throw UVCError.noProcessingUnit(id)
        }
        unitID = unit.id
        interfaceNumber = unit.interface
        controlBits = unit.controls
    }

    /// Walks the configuration descriptor for the VideoControl interface's
    /// class-specific PROCESSING_UNIT descriptor. The unit id is per-device
    /// (3 on a C925e), so it is never hardcoded.
    private static func processingUnit(
        _ configuration: UnsafePointer<IOUSBConfigurationDescriptor>
    ) -> (id: UInt8, interface: UInt8, controls: UInt32)? {
        let total = Int(UInt16(configuration.pointee.wTotalLength))
        let bytes = UnsafeRawPointer(configuration).assumingMemoryBound(to: UInt8.self)
        var offset = 0
        var videoControlInterface: UInt8?

        while offset + 1 < total {
            let length = Int(bytes[offset])
            let type = bytes[offset + 1]
            if length < 2 || offset + length > total { break }

            if type == 0x04 {   // INTERFACE
                // A descriptor too short to hold bInterfaceClass still ends
                // the current interface: what follows is not VideoControl's.
                let isVideoControl = length >= 7 && bytes[offset + 5] == 14 && bytes[offset + 6] == 1
                videoControlInterface = isVideoControl ? bytes[offset + 2] : nil
            } else if type == 0x24,                      // CS_INTERFACE
                      length >= 9,
                      let interface = videoControlInterface,
                      bytes[offset + 2] == 0x05 {        // VC_PROCESSING_UNIT
                // bLength is 8 + bControlSize + the trailing fields. Trust
                // bLength when a device reports the two inconsistently.
                let controlSize = Int(bytes[offset + 7])
                var controls: UInt32 = 0
                for byte in 0..<min(controlSize, 4, length - 8) {
                    controls |= UInt32(bytes[offset + 8 + byte]) << (8 * byte)
                }
                return (bytes[offset + 3], interface, controls)
            }
            offset += length
        }
        return nil
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
