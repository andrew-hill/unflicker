import Foundation
import UVCCore

enum ConfigError: Error, Equatable {
    case malformedLine(number: Int, text: String)
    case badSection(number: Int, text: String)
    /// A well-formed `key = value` that is not under any section header. Almost
    /// always a deleted or mistyped `[default]`. "cannot parse" points at the
    /// wrong line and names the wrong mistake.
    case settingOutsideSection(number: Int, text: String)
    /// The same key twice in one section. There is no right answer, and
    /// last-wins is a guess.
    case duplicateKey(number: Int, key: String, first: Int)
    /// The file is there but could not be read. Carries a reason already fit
    /// for stderr, so the caller never has to render an NSError.
    case unreadable(String)
}

struct Config: Equatable, SettingsSource {
    private(set) var defaults: [String: String] = [:]
    private(set) var perDevice: [UVCDeviceID: [String: String]] = [:]

    /// A file that parsed but asks for nothing. Indistinguishable from a
    /// working config unless `apply` says so out loud.
    var isEmpty: Bool { defaults.isEmpty && perDevice.isEmpty }

    /// Defaults, overlaid with anything set for this specific camera.
    /// Mains frequency is a property of where you live, not of which camera you
    /// own, so most config files only ever have a [default] block.
    func settings(for id: UVCDeviceID) -> [String: String] {
        defaults.merging(perDevice[id] ?? [:]) { _, override in override }
    }

    static func path(xdg: String?, home: String) -> URL {
        let base = xdg.map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: home).appendingPathComponent(".config")
        return base.appendingPathComponent("unflicker/unflicker.conf")
    }

    static var defaultPath: URL {
        path(xdg: ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"],
             home: NSHomeDirectory())
    }

    /// Returns nil when there is no config file. A fresh install does nothing
    /// until it has been configured, and that is not an error.
    ///
    /// Only a genuinely absent file returns nil. A file that exists but cannot
    /// be read (wrong permissions, not UTF-8) throws, because reporting it as
    /// "no config" is how a mistake silently disables the tool forever.
    static func load(_ url: URL) throws -> Config? {
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
                                        && error.code == NSFileReadNoSuchFileError {
            return nil
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
                                        && (error.code == NSFileReadCorruptFileError
                                            || error.code == NSFileReadInapplicableStringEncodingError) {
            // We only ever ask for UTF-8, so both of these mean the same thing
            // to the user, and neither localizedDescription says which encoding.
            throw ConfigError.unreadable("not valid UTF-8 text")
        } catch {
            throw ConfigError.unreadable(error.localizedDescription)
        }
        return try parse(text)
    }

    /// Written by `install` when no config exists. The value is live, not
    /// commented out: every camera measured defaults to 60 Hz, so a 60 Hz
    /// supply produces no banding and nobody there has a reason to install
    /// this. A commented default leaves `install` complete and the camera
    /// unchanged. `install` prints the setting, so it is never applied unseen.
    static let starterTemplate = """
    # unflicker - reapplied to every camera each time one is attached.
    # Values are written the way you would say them, not as raw UVC integers.

    [default]
    # 50Hz for the UK, Europe, most of Asia, Africa and Australia.
    # Change to 60Hz in North America and Japan.
    power-line-frequency = 50Hz

    # Per-camera overrides go in their own section, keyed by vendor:product.
    # Run `unflicker list` for the ids.
    #
    # [046d:085b]
    # brightness = 128
    """

    /// Creates the config, and any missing parent directories, if it is not
    /// already there. Returns whether it wrote one. Never overwrites: someone
    /// re-running `install` after an upgrade must not lose their settings.
    @discardableResult
    static func createIfMissing(at url: URL) throws -> Bool {
        if FileManager.default.fileExists(atPath: url.path) { return false }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try starterTemplate.write(to: url, atomically: true, encoding: .utf8)
        return true
    }

    static func parse(_ text: String) throws -> Config {
        var config = Config()
        var section: UVCDeviceID?
        var inDefault = false
        // Keyed by section, so [default] and a device section may both set the
        // same control. That is the documented override, not a duplicate.
        var seen: [String: [String: Int]] = [:]

        // `.newlines` is a CharacterSet, so it splits CRLF twice and counts
        // the empty half, reporting every error in a CRLF file at line 2N-1.
        // It also splits U+000B, U+000C, U+0085, U+2028 and U+2029, none of
        // which end a line in a config file.
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        for (index, rawLine) in lines.enumerated() {
            let number = index + 1
            var line = rawLine
            if let hash = line.firstIndex(of: "#") { line = String(line[line.startIndex..<hash]) }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("[") && line.hasSuffix("]") {
                let name = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                if name.lowercased() == "default" {
                    inDefault = true
                    section = nil
                } else if let id = UVCDeviceID(name.lowercased()) {
                    inDefault = false
                    section = id
                } else {
                    throw ConfigError.badSection(number: number, text: name)
                }
                continue
            }

            guard let equals = line.firstIndex(of: "=") else {
                throw ConfigError.malformedLine(number: number, text: line)
            }
            guard inDefault || section != nil else {
                throw ConfigError.settingOutsideSection(number: number, text: line)
            }
            let key = String(line[line.startIndex..<equals]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !value.isEmpty else {
                throw ConfigError.malformedLine(number: number, text: line)
            }

            let scope = section?.description ?? "default"
            if let first = seen[scope]?[key] {
                throw ConfigError.duplicateKey(number: number, key: key, first: first)
            }
            seen[scope, default: [:]][key] = number

            if let id = section {
                config.perDevice[id, default: [:]][key] = value
            } else {
                config.defaults[key] = value
            }
        }
        return config
    }
}

extension ConfigError: CustomStringConvertible {
    var description: String {
        switch self {
        case let .malformedLine(number, text):
            return "line \(number): cannot parse '\(text)'"
        case let .badSection(number, text):
            return "line \(number): '[\(text)]' is not [default] or a vendor:product id like [046d:085b]"
        case let .settingOutsideSection(number, text):
            return "line \(number): '\(text)' is not inside a section - add [default] above it"
        case let .duplicateKey(number, key, first):
            return "line \(number): \(key) is already set on line \(first)"
        case let .unreadable(reason):
            return reason
        }
    }
}
