import Foundation
import IOKit

/// Registry-only camera discovery, shared by both transports: which API talks
/// to the device has no bearing on how its registry entry is found.
enum USBEnumeration {
    static func cameras() throws -> [UVCDeviceInfo] {
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
            guard let info = describe(parent) else { continue }
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

    /// Reopens a device found by `cameras()`. Zero means it was unplugged
    /// between enumeration and now.
    static func service(withRegistryID id: UInt64) -> io_service_t {
        IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(id))
    }
}
