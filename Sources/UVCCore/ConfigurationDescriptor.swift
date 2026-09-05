/// The one place that parses untrusted device data. It takes plain bytes so
/// the malformed cases can be tested without a camera on the desk.
public enum ConfigurationDescriptor {
    public struct ProcessingUnit: Equatable, Sendable {
        public let id: UInt8
        public let interface: UInt8
        /// The bmControls bitmap, in the UVC spec's Processing Unit layout.
        public let controls: UInt32
    }

    /// Walks a full configuration descriptor for the VideoControl interface's
    /// class-specific PROCESSING_UNIT descriptor. The unit id is per-device
    /// (3 on a C925e), so it is never hardcoded.
    ///
    /// wTotalLength is read from the descriptor but clamped to the buffer:
    /// it is a device-reported field and cannot be allowed to extend the walk
    /// past the bytes actually supplied.
    public static func processingUnit(_ bytes: [UInt8]) -> ProcessingUnit? {
        guard bytes.count >= 4 else { return nil }
        let total = min(Int(bytes[2]) | Int(bytes[3]) << 8, bytes.count)
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
                return ProcessingUnit(id: bytes[offset + 3], interface: interface, controls: controls)
            }
            offset += length
        }
        return nil
    }
}
