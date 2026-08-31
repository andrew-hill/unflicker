import Foundation

enum UVCControlError: Error, Equatable {
    case unknownControl(String)
    case badValue(control: String, text: String)
}

/// A Processing Unit control. Camera Terminal controls (zoom, exposure, focus)
/// are a separate entity with their own encodings and are not handled yet.
struct UVCControl: Hashable, Sendable {
    let name: String
    /// UVC control selector, used as the high byte of wValue.
    let selector: UInt8
    /// Position in the Processing Unit's bmControls bitmap.
    let bit: Int
    /// Bytes in the control transfer's data phase.
    let length: Int
    let signed: Bool
    /// Friendly name to raw value, spelled the way it should be displayed.
    /// Empty when the control is plain numeric.
    let values: [String: Int]
    /// A boolean control. UVC mandates only GET_CUR, SET_CUR, GET_DEF and
    /// GET_INFO for these, so a device may legitimately STALL GET_MIN. The
    /// Dell 413c:d003 does, with 0xe0005000. Their range is 0...1 by
    /// definition and must never be asked for.
    var isBoolean: Bool = false

    func parse(_ text: String) throws -> Int {
        let wanted = text.trimmingCharacters(in: .whitespaces).lowercased()
        if let match = values.first(where: { $0.key.lowercased() == wanted }) {
            return match.value
        }
        if let raw = Int(wanted) { return raw }
        throw UVCControlError.badValue(control: name, text: text)
    }

    func format(_ raw: Int) -> String {
        values.first { $0.value == raw }?.key ?? String(raw)
    }
}

extension UVCControl {
    // Bit positions are the UVC spec's Processing Unit bmControls layout,
    // confirmed against a C925e reporting 0x175b.
    static let all: [UVCControl] = [
        UVCControl(name: "backlight-compensation", selector: 0x01, bit: 8, length: 2, signed: false, values: [:]),
        UVCControl(name: "brightness", selector: 0x02, bit: 0, length: 2, signed: true, values: [:]),
        UVCControl(name: "contrast", selector: 0x03, bit: 1, length: 2, signed: false, values: [:]),
        UVCControl(name: "gain", selector: 0x04, bit: 9, length: 2, signed: false, values: [:]),
        UVCControl(name: "power-line-frequency", selector: 0x05, bit: 10, length: 1, signed: false,
                   values: ["disabled": 0, "50Hz": 1, "60Hz": 2, "auto": 3]),
        UVCControl(name: "hue", selector: 0x06, bit: 2, length: 2, signed: true, values: [:]),
        UVCControl(name: "saturation", selector: 0x07, bit: 3, length: 2, signed: false, values: [:]),
        UVCControl(name: "sharpness", selector: 0x08, bit: 4, length: 2, signed: false, values: [:]),
        UVCControl(name: "gamma", selector: 0x09, bit: 5, length: 2, signed: false, values: [:]),
        UVCControl(name: "white-balance-temperature", selector: 0x0A, bit: 6, length: 2, signed: false, values: [:]),
        UVCControl(name: "white-balance-temperature-auto", selector: 0x0B, bit: 12, length: 1, signed: false,
                   values: ["off": 0, "on": 1], isBoolean: true),
    ]

    static func named(_ name: String) -> UVCControl? {
        all.first { $0.name == name.lowercased() }
    }
}

extension UVCControlError: CustomStringConvertible {
    var description: String {
        switch self {
        case let .unknownControl(name):
            return "unknown control '\(name)'"
        case let .badValue(control, text):
            let named = UVCControl.named(control)?.values.keys.sorted().joined(separator: ", ") ?? ""
            let expected = named.isEmpty ? "a number" : "\(named), or a number"
            return "'\(text)' is not a valid \(control) value (expected \(expected))"
        }
    }
}
