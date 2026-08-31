import Foundation
import Testing
@testable import unflicker

private func plist() -> [String: Any] {
    AgentInstaller.plist(binary: "/opt/homebrew/bin/unflicker")
}

@Test func runsApplyFromLaunchd() {
    #expect(plist()["ProgramArguments"] as? [String]
            == ["/opt/homebrew/bin/unflicker", "apply", "--from-launchd"])
}

@Test func usesTheAgreedLabel() {
    #expect(plist()["Label"] as? String == "net.thefrog.unflicker")
}

// The whole point of the project is that nothing pokes the camera on a timer.
@Test func neverPolls() {
    let generated = plist()
    #expect(generated["RunAtLoad"] == nil)
    #expect(generated["StartInterval"] == nil)
    #expect(generated["KeepAlive"] == nil)
    #expect(generated["StartCalendarInterval"] == nil)
}

// Matching is on the device with no property filter. Measured 2026-08-28:
// launchd matches IOProviderClass on its own, but silently matches nothing as
// soon as a bInterfaceClass filter is added, integer or string.
@Test func matchesAnyUSBDevice() throws {
    let events = plist()["LaunchEvents"] as? [String: Any]
    let iokit = events?["com.apple.iokit.matching"] as? [String: Any]
    let rule = iokit?["net.thefrog.unflicker.camera-attach"] as? [String: Any]
    #expect(rule?["IOProviderClass"] as? String == "IOUSBHostDevice")
    #expect(rule?["IOMatchLaunchStream"] as? Bool == true)
}

// A filter here would match nothing at all, which fails silently. Guard it.
@Test func carriesNoPropertyFilter() throws {
    let events = plist()["LaunchEvents"] as? [String: Any]
    let iokit = events?["com.apple.iokit.matching"] as? [String: Any]
    let rule = iokit?["net.thefrog.unflicker.camera-attach"] as? [String: Any]
    #expect(rule?["bInterfaceClass"] == nil)
    #expect(rule?["idVendor"] == nil)
    #expect(rule?["idProduct"] == nil)
}

@Test func serialisesToARealPlist() throws {
    let data = try PropertyListSerialization.data(fromPropertyList: plist(), format: .xml, options: 0)
    let round = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    #expect(round?["Label"] as? String == "net.thefrog.unflicker")
}

@Test func installsIntoLaunchAgents() {
    #expect(AgentInstaller.plistURL.path.hasSuffix("Library/LaunchAgents/net.thefrog.unflicker.plist"))
}

// MARK: - install, with launchctl faked out
//
// Discarding launchctl's exit status means a bootstrap that failed still
// prints "installed" and exits 0. The user believes the camera is looked after
// and finds out otherwise on the next replug. `run` is injected so this can be
// tested without bootstrapping a real agent into the session.

private func tempPlistURL() -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("unflicker-tests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("net.thefrog.unflicker.plist")
}

@Test func installWritesThePlistThenBootstrapsIt() throws {
    let url = tempPlistURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    var commands: [[String]] = []

    try AgentInstaller.install(binary: "/opt/homebrew/bin/unflicker", to: url,
                               run: { commands.append($0); return (0, "") })

    #expect(commands == [["bootout", "gui/\(getuid())/net.thefrog.unflicker"],
                         ["bootstrap", "gui/\(getuid())", url.path]])
    let written = try PropertyListSerialization.propertyList(
        from: try Data(contentsOf: url), format: nil) as? [String: Any]
    #expect(written?["Label"] as? String == "net.thefrog.unflicker")
}

@Test func installFailsLoudlyWhenBootstrapDoes() {
    let url = tempPlistURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    #expect(throws: AgentInstallerError.self) {
        try AgentInstaller.install(binary: "/opt/homebrew/bin/unflicker", to: url,
                                   run: { $0.first == "bootstrap" ? (5, "") : (0, "") })
    }
}

// On a fresh machine there is nothing loaded to boot out, and launchctl says so
// with a non-zero status. That is the normal case, not a failure.
@Test func installIgnoresBootoutFailingWithNothingLoaded() throws {
    let url = tempPlistURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    try AgentInstaller.install(binary: "/opt/homebrew/bin/unflicker", to: url,
                               run: { $0.first == "bootout" ? (3, "") : (0, "") })
}

@Test func uninstallBootsItOutAndRemovesThePlist() throws {
    let url = tempPlistURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try AgentInstaller.install(binary: "/opt/homebrew/bin/unflicker", to: url, run: { _ in (0, "") })

    try AgentInstaller.uninstall(at: url, run: { _ in (0, "") })

    #expect(!FileManager.default.fileExists(atPath: url.path))
}

// Uninstalling something that was never installed is a no-op, not an error.
@Test func uninstallOnAMachineWithNoAgentIsNotAnError() throws {
    try AgentInstaller.uninstall(at: tempPlistURL(), run: { _ in (3, "") })
}

// MARK: - which binary goes into the plist

// argv[0] is whatever the calling shell chose to pass. Run off PATH it is a
// bare "unflicker", and a plist naming that is one launchd cannot run.
@Test func prefersTheOSReportedExecutableOverArgv0() throws {
    #expect(try AgentInstaller.binaryPath(argv0: "unflicker",
                                          executable: URL(fileURLWithPath: "/bin/launchctl"))
            == "/bin/launchctl")
}

// Homebrew's /opt/homebrew/bin/unflicker is a symlink into a versioned Cellar
// directory. Resolving it would pin the agent to a path `brew upgrade` deletes,
// so the symlink is the path that has to go in the plist.
@Test func keepsASymlinkRatherThanPinningToItsTarget() throws {
    let link = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("unflicker-link-\(UUID().uuidString)")
    try FileManager.default.createSymbolicLink(at: link,
                                               withDestinationURL: URL(fileURLWithPath: "/bin/launchctl"))
    defer { try? FileManager.default.removeItem(at: link) }

    #expect(try AgentInstaller.binaryPath(argv0: "unflicker", executable: link) == link.path)
}

// Refusing beats writing a plist that silently never runs.
@Test func refusesWhenNeitherNamesAnExecutable() {
    #expect(throws: AgentInstallerError.self) {
        try AgentInstaller.binaryPath(argv0: "unflicker", executable: nil)
    }
}

@Test func installerErrorsReadAsEnglish() {
    let failed = AgentInstallerError.launchctlFailed(["bootstrap", "gui/501", "/x.plist"],
                                                     status: 5, output: "Load failed: 5")
    #expect("\(failed)" == "launchctl bootstrap failed (status 5): Load failed: 5 "
                         + "[launchctl bootstrap gui/501 /x.plist]")
    #expect("\(AgentInstallerError.binaryNotFound("/nope/unflicker"))"
            == "cannot find the running unflicker binary (looked at /nope/unflicker)")
}

// A fresh install has nothing to boot out, and launchctl says so on stderr:
// "Boot-out failed: 3: No such process". We ignore that status deliberately, so
// printing it as the first thing a new user sees is just alarming noise. Since
// the output has to be captured to be silenced, it may as well be reported -
// launchctl's own diagnostics say far more than its exit status does.
@Test func launchctlCapturesItsOutputRatherThanPrintingIt() throws {
    let result = try AgentInstaller.launchctl(["definitely-not-a-subcommand"])

    #expect(result.status != 0)
    #expect(!result.output.isEmpty)
}

@Test func installReportsLaunchctlsOwnDiagnostic() throws {
    let url = tempPlistURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let thrown = #expect(throws: AgentInstallerError.self) {
        try AgentInstaller.install(binary: "/opt/homebrew/bin/unflicker", to: url,
                                   run: { $0.first == "bootstrap"
                                          ? (5, "Load failed: 5: Input/output error")
                                          : (0, "") })
    }

    #expect("\(thrown!)".contains("Load failed: 5: Input/output error"))
}

// MARK: - what `install` says about the config it found or wrote

private let configPath = URL(fileURLWithPath: "/Users/x/.config/unflicker/unflicker.conf")

@Test func installNamesTheSettingItWroteSoItIsNeverAppliedUnseen() {
    let message = CLI.configNotice(created: true, at: configPath)
    #expect(message.contains(configPath.path))
    #expect(message.contains("power-line-frequency = 50Hz"))
    #expect(message.contains("60Hz"))     // the correction for 60 Hz regions
}

@Test func installLeavesAnExistingConfigAloneAndSaysSo() {
    let message = CLI.configNotice(created: false, at: configPath)
    #expect(message.contains(configPath.path))
    // Must not claim to have written anything: the user's own settings stand.
    #expect(!message.lowercased().contains("wrote"))
}
