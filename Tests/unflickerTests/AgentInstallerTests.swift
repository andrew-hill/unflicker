import Foundation
import Testing
@testable import UVCCore
@testable import unflicker

// Whole-dictionary equality, so a key that should not be here - a StartInterval,
// a bInterfaceClass filter - fails this as loudly as a changed one does.
@Test func theAgentPlistIsWhatLaunchdIsGiven() {
    let expected: [String: Any] = [
        "Label": "net.thefrog.unflicker",
        "ProgramArguments": ["/opt/homebrew/bin/unflicker", "apply", "--from-launchd"],
        "ProcessType": "Background",
        "LaunchEvents": ["com.apple.iokit.matching": [
            "net.thefrog.unflicker.camera-attach": [
                "IOMatchLaunchStream": true,
                "IOProviderClass": "IOUSBHostDevice",
            ],
        ]],
    ]

    #expect(AgentInstaller.plist(binary: "/opt/homebrew/bin/unflicker") as NSDictionary
            == expected as NSDictionary)
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

    // #require, not `!`: force-unwrapping a failed expectation kills the whole
    // test process with signal 5 and takes the rest of the run's output with it.
    #expect("\(try #require(thrown))".contains("Load failed: 5: Input/output error"))
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

// launchd bootstraps ~/Library/LaunchAgents itself at login, so a plist left
// behind after a failed bootstrap loads next time regardless. Install would
// report failure and half-succeed - the hazard `uninstall` already guards.
@Test func installLeavesNoPlistBehindWhenBootstrapFails() {
    let url = tempPlistURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    #expect(throws: AgentInstallerError.self) {
        try AgentInstaller.install(binary: "/opt/homebrew/bin/unflicker", to: url,
                                   run: { $0.first == "bootstrap" ? (5, "") : (0, "") })
    }
    #expect(FileManager.default.fileExists(atPath: url.path) == false)
}

// Reinstall overwrites the plist before launchctl is asked, so a bootstrap that
// then fails has already destroyed the working one. The agent it boots out
// first is not coming back on its own.
@Test func aFailedReinstallPutsTheWorkingPlistBack() throws {
    let url = tempPlistURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    try AgentInstaller.install(binary: "/usr/local/bin/unflicker", to: url, run: { _ in (0, "") })
    let working = try Data(contentsOf: url)

    #expect(throws: AgentInstallerError.self) {
        try AgentInstaller.install(binary: "/opt/homebrew/bin/unflicker", to: url,
                                   run: { $0.first == "bootstrap" ? (5, "") : (0, "") })
    }
    #expect(try Data(contentsOf: url) == working)
}

// A plist that is there but cannot be read: the overwrite has already happened
// by the time launchctl is asked, so there is nothing to put back and what is
// on disk is the plist bootstrap just refused. Leaving it is what makes it load
// at the next login.
@Test func aFailedReinstallOverAnUnreadablePlistRemovesIt() throws {
    let url = tempPlistURL()
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                               ofItemAtPath: url.deletingLastPathComponent().path)
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
    // Write-only: the write below succeeds, the read back does not.
    try Data("old".utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o200], ofItemAtPath: url.path)

    #expect(throws: AgentInstallerError.self) {
        try AgentInstaller.install(binary: "/opt/homebrew/bin/unflicker", to: url,
                                   run: { $0.first == "bootstrap" ? (5, "") : (0, "") })
    }
    #expect(FileManager.default.fileExists(atPath: url.path) == false)
}
