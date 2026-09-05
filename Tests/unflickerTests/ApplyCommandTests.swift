import Foundation
import Testing
@testable import UVCCore
@testable import unflicker

private func tempConfig(_ contents: String?) -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("unflicker-tests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("unflicker.conf")
    if let contents { try! contents.write(to: path, atomically: true, encoding: .utf8) }
    return path
}

// No config file is not an error, but `apply` must say so rather than
// printing nothing, which reads as "everything was already correct".
@Test func missingConfigIsSuccessNotAnError() {
    let (info, connection) = c925e()
    let transport = FakeTransport(infos: [info], connections: [info.id: connection])

    let status = CLI.applyOnce(transport, dryRun: false, fromLaunchd: false,
                               configPath: tempConfig(nil))

    #expect(status == 0)
    #expect(connection.writes.isEmpty)
}

// A `try?` here swallows the typo and reports "no config file", silently
// disabling the tool for good.
@Test func malformedConfigIsReportedNotIgnored() {
    let (info, connection) = c925e()
    let transport = FakeTransport(infos: [info], connections: [info.id: connection])

    let status = CLI.applyOnce(transport, dryRun: false, fromLaunchd: false,
                               configPath: tempConfig("[default]\npower-line-frequency\n"))

    #expect(status == 1)
    #expect(connection.writes.isEmpty)
}

@Test func badSectionHeaderIsReported() {
    let (info, connection) = c925e()
    let transport = FakeTransport(infos: [info], connections: [info.id: connection])

    let status = CLI.applyOnce(transport, dryRun: false, fromLaunchd: false,
                               configPath: tempConfig("[logitech]\nbrightness = 1\n"))

    #expect(status == 1)
    #expect(connection.writes.isEmpty)
}

@Test func validConfigAppliesAndSucceeds() {
    let (info, connection) = c925e(powerLineFrequency: 2)
    let transport = FakeTransport(infos: [info], connections: [info.id: connection])

    let status = CLI.applyOnce(transport, dryRun: false, fromLaunchd: false,
                               configPath: tempConfig("[default]\npower-line-frequency = 50Hz\n"))

    #expect(status == 0)
    #expect(connection.writes.map(\.1) == [1])
}

@Test func configErrorsReadAsEnglish() {
    #expect("\(ConfigError.malformedLine(number: 2, text: "power-line-frequency"))"
            == "line 2: cannot parse 'power-line-frequency'")
    #expect("\(ConfigError.badSection(number: 1, text: "logitech"))"
            == "line 1: '[logitech]' is not [default] or a vendor:product id like [046d:085b]")
}

/// Reports devices only after `appearOnCall`, and counts how many times it was
/// asked. Used to prove `apply` enumerates once rather than twice.
private struct CountingTransport: UVCTransport {
    final class Counter: @unchecked Sendable { var calls = 0 }
    let info: UVCDeviceInfo
    let connection: FakeConnection
    let counter = Counter()

    func devices() throws -> [UVCDeviceInfo] {
        counter.calls += 1
        return [info]
    }
    func open(_ device: UVCDeviceInfo) throws -> any UVCConnection { connection }
}

/// Fails enumeration outright, the way a broken IOKit lookup would.
private struct BrokenTransport: UVCTransport {
    func devices() throws -> [UVCDeviceInfo] { throw UVCError.deviceGone }
    func open(_ device: UVCDeviceInfo) throws -> any UVCConnection { throw UVCError.deviceGone }
}

// A config that exists but cannot be read must not be reported as "no config".
// That is the same silent-disable failure the malformed-config test guards.
@Test func unreadableConfigIsReportedNotTreatedAsMissing() throws {
    let (info, connection) = c925e()
    let transport = FakeTransport(infos: [info], connections: [info.id: connection])
    let path = tempConfig("[default]\npower-line-frequency = 50Hz\n")
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path) }

    let status = CLI.applyOnce(transport, dryRun: false, fromLaunchd: false, configPath: path)

    #expect(status == 1)
    #expect(connection.writes.isEmpty)
}

@Test func configThatIsNotUTF8IsReportedNotTreatedAsMissing() throws {
    let (info, connection) = c925e()
    let transport = FakeTransport(infos: [info], connections: [info.id: connection])
    let path = tempConfig(nil)
    try Data([0xff, 0xfe, 0x5b, 0x64]).write(to: path)

    let status = CLI.applyOnce(transport, dryRun: false, fromLaunchd: false, configPath: path)

    #expect(status == 1)
    #expect(connection.writes.isEmpty)
}

// waitForDevices must not swallow this and return []: a broken enumeration
// then looks exactly like "no camera plugged in".
@Test func enumerationFailureIsReportedNotReadAsNoCameras() {
    let status = CLI.applyOnce(BrokenTransport(), dryRun: false, fromLaunchd: false,
                               configPath: tempConfig("[default]\npower-line-frequency = 50Hz\n"))

    #expect(status == 1)
}

// waitForDevices already found the cameras; Apply.run should not go and ask
// the IORegistry a second time.
@Test func applyEnumeratesOnceNotTwice() {
    let (info, connection) = c925e(powerLineFrequency: 2)
    let transport = CountingTransport(info: info, connection: connection)

    _ = CLI.applyOnce(transport, dryRun: false, fromLaunchd: false,
                      configPath: tempConfig("[default]\npower-line-frequency = 50Hz\n"))

    #expect(transport.counter.calls == 1)
}

// MARK: - the states in which `apply` does nothing

private let anyConfig = try! Config.parse("[default]\npower-line-frequency = 50Hz")
private let somePath = URL(fileURLWithPath: "/Users/x/.config/unflicker/unflicker.conf")

@Test func applySaysSoWhenThereIsNoConfig() {
    let notice = CLI.nothingToDoNotice(config: nil, cameras: nil, at: somePath)
    #expect(notice?.contains(somePath.path) == true)
    #expect(notice?.contains("install") == true)
}

@Test func applySaysSoWhenTheConfigHasNoSettings() throws {
    let empty = try Config.parse("[default]")
    #expect(CLI.nothingToDoNotice(config: empty, cameras: nil, at: somePath)?.contains(somePath.path) == true)
}

@Test func applySaysSoWhenNoCameraIsAttached() {
    #expect(CLI.nothingToDoNotice(config: anyConfig, cameras: 0, at: somePath) == "no UVC cameras found")
}

@Test func applyIsQuietOnlyWhenThereIsWorkToDo() {
    #expect(CLI.nothingToDoNotice(config: anyConfig, cameras: 1, at: somePath) == nil)
    // Not yet enumerated: the camera count must not be mistaken for zero.
    #expect(CLI.nothingToDoNotice(config: anyConfig, cameras: nil, at: somePath) == nil)
}

@Test func aCameraTheConfigDoesNotCoverIsReported() throws {
    let (info, connection) = c925e()
    let transport = FakeTransport(infos: [info], connections: [info.id: connection])
    let config = try Config.parse("[046d:9999]\nbrightness = 128")

    let results = try Apply.run(transport: transport, config: config, dryRun: false)

    #expect(results == [ApplyResult(device: info.id, outcomes: [.noSettings])])
    #expect(connection.writes.isEmpty)
}

// A USB transfer that failed for a reason other than an unplug or a stall.
// `apply` prints "..., stopping" for it, so exiting 0 as well is the one
// combination a script cannot detect.
@Test func aTransferFailureMakesApplyExitNonZero() {
    let (info, connection) = c925e(powerLineFrequency: 2)
    connection.fail(.transferFailed(control: "power-line-frequency",
                                    code: IOReturnCode(value: Int32(bitPattern: 0xe00002c9))))
    let transport = FakeTransport(infos: [info], connections: [info.id: connection])

    let status = CLI.applyOnce(transport, dryRun: false, fromLaunchd: false,
                               configPath: tempConfig("[default]\npower-line-frequency = 50Hz\n"))

    #expect(status == 1)
    #expect(connection.writes.isEmpty)
}

// A control the camera does not have is not the run failing: the config may be
// shared with a machine whose camera does have it.
@Test func anUnsupportedControlLeavesApplySucceeding() {
    let (info, connection) = c925e()
    let transport = FakeTransport(infos: [info], connections: [info.id: connection])

    let status = CLI.applyOnce(transport, dryRun: false, fromLaunchd: false,
                               configPath: tempConfig("[default]\ngamma = 100\n"))

    #expect(status == 0)
    #expect(connection.writes.isEmpty)
}

// The camera the config names did not get its settings reapplied, so the run
// did not do what it was asked, even though the other camera was fine.
@Test func aCameraThatWillNotOpenMakesApplyExitNonZero() {
    let (info, connection) = c925e(powerLineFrequency: 2)
    let dellID = UVCDeviceID(vendor: 0x413c, product: 0xd003)
    let transport = FakeTransport(
        infos: [UVCDeviceInfo(id: dellID, name: "Dell Monitor Webcam", registryID: 2), info],
        connections: [info.id: connection],
        openErrors: [dellID: .openFailed(dellID, IOReturnCode(value: Int32(bitPattern: 0xe00002c9)))])

    let status = CLI.applyOnce(transport, dryRun: false, fromLaunchd: false,
                               configPath: tempConfig("[default]\npower-line-frequency = 50Hz\n"))

    #expect(status == 1)
    // and the camera that did open was still reapplied
    #expect(connection.writes.map(\.1) == [1])
}

// An unknown control name or an out-of-range value is about this camera, and
// the same config is right on the machine whose camera has the control. Text
// that will not parse is wrong everywhere, so exiting 0 lets a typo disable the
// setting on every machine, quietly, forever.
@Test func aValueThatWillNotParseMakesApplyExitNonZero() {
    let (info, connection) = c925e(powerLineFrequency: 2)
    let transport = FakeTransport(infos: [info], connections: [info.id: connection])

    let status = CLI.applyOnce(transport, dryRun: false, fromLaunchd: false,
                               configPath: tempConfig("[default]\npower-line-frequency = 55Hz\n"))

    #expect(status == 1)
    #expect(connection.writes.isEmpty)
}

// The other half of the same split: still tolerated, because the camera on the
// next machine may well have the control.
@Test func anUnknownControlNameLeavesApplySucceeding() {
    let (info, connection) = c925e()
    let transport = FakeTransport(infos: [info], connections: [info.id: connection])

    let status = CLI.applyOnce(transport, dryRun: false, fromLaunchd: false,
                               configPath: tempConfig("[default]\nnot-a-control = 1\n"))

    #expect(status == 0)
    #expect(connection.writes.isEmpty)
}

@Test func aValueOutsideTheDeviceRangeLeavesApplySucceeding() {
    let (info, connection) = c925e(powerLineFrequency: 2)
    let transport = FakeTransport(infos: [info], connections: [info.id: connection])

    // The C925e answers 1...2, so `auto` is a value this camera does not have.
    let status = CLI.applyOnce(transport, dryRun: false, fromLaunchd: false,
                               configPath: tempConfig("[default]\npower-line-frequency = auto\n"))

    #expect(status == 0)
    #expect(connection.writes.isEmpty)
}
