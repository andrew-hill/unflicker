import Foundation
import Testing
@testable import UVCCore
@testable import unflicker

private let c925eID = UVCDeviceID(vendor: 0x046d, product: 0x085b)
private let otherID = UVCDeviceID(vendor: 0x1234, product: 0x5678)

@Test func defaultsApplyToEveryCamera() throws {
    let config = try Config.parse("""
    [default]
    power-line-frequency = 50Hz
    """)
    #expect(config.settings(for: c925eID) == ["power-line-frequency": "50Hz"])
    #expect(config.settings(for: otherID) == ["power-line-frequency": "50Hz"])
}

@Test func perDeviceOverridesDefault() throws {
    let config = try Config.parse("""
    [default]
    power-line-frequency = 50Hz
    brightness = 100

    [046d:085b]
    brightness = 128
    """)
    #expect(config.settings(for: c925eID) == ["power-line-frequency": "50Hz", "brightness": "128"])
    #expect(config.settings(for: otherID) == ["power-line-frequency": "50Hz", "brightness": "100"])
}

@Test func commentsAndBlankLinesAreIgnored() throws {
    let config = try Config.parse("""
    # mains is 50 Hz here

    [default]
      power-line-frequency = 50Hz   # trailing comment

    """)
    #expect(config.settings(for: c925eID) == ["power-line-frequency": "50Hz"])
}

@Test func sectionHeadersAreCaseInsensitive() throws {
    let config = try Config.parse("""
    [046D:085B]
    power-line-frequency = 50Hz
    """)
    #expect(config.settings(for: c925eID) == ["power-line-frequency": "50Hz"])
}

@Test func lineWithoutEqualsIsMalformed() {
    #expect(throws: ConfigError.malformedLine(number: 2, text: "power-line-frequency")) {
        try Config.parse("[default]\npower-line-frequency")
    }
}

@Test func sectionThatIsNotDefaultOrVendorProductIsRejected() {
    #expect(throws: ConfigError.badSection(number: 1, text: "logitech")) {
        try Config.parse("[logitech]\nbrightness = 1")
    }
}

// No config file, the fresh-install state, which loads as nil. Its partner
// below covers a file that exists but cannot be read.
@Test func missingFileLoadsAsNil() throws {
    try withConfigFile(nil) { path in
        let loaded = try Config.load(path)
        #expect(loaded == nil)
    }
}

@Test func configPathFollowsXDGWhenSet() {
    #expect(Config.path(xdg: "/tmp/cfg", home: "/Users/x").path == "/tmp/cfg/unflicker/unflicker.conf")
    #expect(Config.path(xdg: nil, home: "/Users/x").path == "/Users/x/.config/unflicker/unflicker.conf")
}

// A file that exists but cannot be read, kept distinct from the missing file
// above: reported as "no config" it would disable the tool silently.
@Test func unreadableFileErrorReadsAsEnglish() throws {
    try withConfigFile(nil) { path in
        try Data([0xff, 0xfe, 0x5b, 0x64]).write(to: path)
        #expect(throws: ConfigError.unreadable("not valid UTF-8 text")) { try Config.load(path) }
    }
}

// `localizedDescription` is localised, so the expected reason has to come from
// Foundation rather than a literal.
@Test func unreadableFileSaysWhyWithoutDumpingAnNSError() throws {
    try withConfigFile("[default]\n") { path in
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path.path)
        var reason = ""
        do {
            _ = try String(contentsOf: path, encoding: .utf8)
            Issue.record("expected the file to be unreadable")
            return
        } catch {
            reason = error.localizedDescription
        }

        do {
            _ = try Config.load(path)
            Issue.record("expected Config.load to throw")
        } catch let error as ConfigError {
            #expect("\(error)" == reason)
            #expect(!"\(error)".contains("NSCocoaErrorDomain"))
        }
    }
}

// MARK: - the starter config `install` writes

@Test func starterConfigSetsFiftyHertz() throws {
    // Every camera measured ships defaulting to 60 Hz, so nobody on a 60 Hz
    // supply has the banding this tool fixes. The starter file is therefore
    // live, not commented out: `install` produces a working setup in one
    // command, and prints the value so it is never applied unseen.
    let config = try Config.parse(Config.starterTemplate)
    #expect(config.settings(for: c925eID) == ["power-line-frequency": "50Hz"])
}

@Test func createIfMissingWritesTheStarterConfig() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("unflicker-starter-\(UUID().uuidString)")
    let path = dir.appendingPathComponent("unflicker/unflicker.conf")
    defer { try? FileManager.default.removeItem(at: dir) }

    #expect(try Config.createIfMissing(at: path) == true)
    #expect(try String(contentsOf: path, encoding: .utf8) == Config.starterTemplate)
}

@Test func createIfMissingNeverOverwritesAnExistingConfig() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("unflicker-starter-\(UUID().uuidString)")
    let path = dir.appendingPathComponent("unflicker/unflicker.conf")
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: path.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try "[default]\npower-line-frequency = 60Hz\n".write(to: path, atomically: true, encoding: .utf8)

    #expect(try Config.createIfMissing(at: path) == false)
    #expect(try String(contentsOf: path, encoding: .utf8).contains("60Hz"))
}

// MARK: - configs damaged by hand after install

@Test func aSettingOutsideAnySectionSaysSo() {
    // Deleting or typoing the [default] header is the likeliest hand-edit, and
    // "cannot parse" is a lie about a line that parses perfectly well.
    #expect(throws: ConfigError.settingOutsideSection(number: 1, text: "power-line-frequency = 50Hz")) {
        try Config.parse("power-line-frequency = 50Hz")
    }
}

@Test func aDuplicateKeyIsReportedNotSilentlyOverridden() {
    // 50 then 60 has no right answer, and last-wins is the tool guessing.
    #expect(throws: ConfigError.duplicateKey(number: 3, key: "power-line-frequency", first: 2)) {
        try Config.parse("""
        [default]
        power-line-frequency = 50Hz
        power-line-frequency = 60Hz
        """)
    }
}

@Test func theSameKeyInTwoSectionsIsTheDocumentedOverride() throws {
    let config = try Config.parse("""
    [default]
    power-line-frequency = 50Hz

    [046d:085b]
    power-line-frequency = 60Hz
    """)
    #expect(config.settings(for: c925eID) == ["power-line-frequency": "60Hz"])
}

@Test func aConfigWithNoSettingsKnowsItIsEmpty() throws {
    #expect(try Config.parse("[default]").isEmpty)
    #expect(try Config.parse("# all commented out\n").isEmpty)
    #expect(try !Config.parse(Config.starterTemplate).isEmpty)
}

// Splitting on the .newlines CharacterSet cut CRLF twice and counted the empty
// line between the halves, so line N was reported as 2N-1 and the number drifted
// further from the truth the further down the file the mistake was.
@Test func crlfLineEndingsDoNotInflateTheLineNumber() {
    #expect(throws: ConfigError.malformedLine(number: 3, text: "power-line-frequency")) {
        try Config.parse("[default]\r\nbrightness = 100\r\npower-line-frequency\r\n")
    }
}

@Test func crlfLineEndingsParseTheSameAsUnix() throws {
    let crlf = try Config.parse("[default]\r\npower-line-frequency = 50Hz\r\n")
    #expect(crlf == (try Config.parse("[default]\npower-line-frequency = 50Hz\n")))
}

// U+2028 is in CharacterSet.newlines but ends no line in a config file. Split
// on it and the value is cut in half, and the error names a line that is not
// the one the user typed.
@Test func anExoticSeparatorInsideAValueIsNotALineBreak() throws {
    let config = try Config.parse("[default]\nbrightness = 12\u{2028}8\n")
    #expect(config.settings(for: UVCDeviceID(vendor: 0, product: 0))["brightness"] == "12\u{2028}8")
}
