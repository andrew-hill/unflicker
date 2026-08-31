import Foundation

enum AgentInstallerError: Error, Equatable {
    case launchctlFailed([String], status: Int32, output: String)
    case binaryNotFound(String)
}

enum AgentInstaller {
    static let label = "net.thefrog.unflicker"

    static var plistURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// Injected so `install` and `uninstall` can be tested without
    /// bootstrapping a real agent into the session.
    typealias Runner = ([String]) throws -> (status: Int32, output: String)

    /// Fires on any USB device attach, and at login for devices already
    /// attached. Deliberately unfiltered: launchd matches IOProviderClass on
    /// its own, but adding bInterfaceClass makes it match nothing at all, with
    /// no error. Measured 2026-08-28. `apply` enumerates cameras itself and
    /// exits quietly when there is none, so the extra wakeups are cheap.
    static func plist(binary: String) -> [String: Any] {
        let rule: [String: Any] = [
            "IOMatchLaunchStream": true,
            "IOProviderClass": "IOUSBHostDevice",
        ]

        // No RunAtLoad, no StartInterval, no KeepAlive. Event-triggered only.
        return [
            "Label": label,
            "ProgramArguments": [binary, "apply", "--from-launchd"],
            "ProcessType": "Background",
            "LaunchEvents": [
                "com.apple.iokit.matching": ["\(label).camera-attach": rule]
            ],
        ]
    }

    /// The path to write into the plist.
    ///
    /// Not argv[0]: run off PATH that is a bare "unflicker", which launchd
    /// cannot execute. Not `resolvingSymlinksInPath` either. Homebrew's
    /// `/opt/homebrew/bin/unflicker` is a symlink into a versioned Cellar
    /// directory that `brew upgrade` deletes.
    static func binaryPath(argv0: String = CommandLine.arguments[0],
                           executable: URL? = Bundle.main.executableURL) throws -> String {
        let candidate = (executable ?? URL(fileURLWithPath: argv0)).standardizedFileURL
        guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
            throw AgentInstallerError.binaryNotFound(candidate.path)
        }
        return candidate.path
    }

    static func install(binary: String, to url: URL = plistURL,
                        run: Runner = launchctl) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        // Reinstall overwrites and re-bootstraps, so boot out anything already
        // loaded first. On a fresh machine there is nothing to boot out and
        // launchctl says so with a non-zero status; that is the normal case.
        _ = try? run(["bootout", "gui/\(getuid())/\(label)"])

        let data = try PropertyListSerialization.data(
            fromPropertyList: plist(binary: binary), format: .xml, options: 0)
        try data.write(to: url)

        // A bootstrap that fails leaves nothing loaded. Without this check the
        // user finds out at the next replug.
        try check(["bootstrap", "gui/\(getuid())", url.path], run)
        Log.agent.notice("installed \(label, privacy: .public) for \(binary, privacy: .public)")
    }

    static func uninstall(at url: URL = plistURL, run: Runner = launchctl) throws {
        _ = try? run(["bootout", "gui/\(getuid())/\(label)"])
        // A plist left behind brings the agent back at the next login, so a
        // failed removal has to be said out loud. One that was never there is
        // nothing to do.
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        Log.agent.notice("removed \(label, privacy: .public)")
    }

    private static func check(_ arguments: [String], _ run: Runner) throws {
        let result = try run(arguments)
        guard result.status == 0 else {
            throw AgentInstallerError.launchctlFailed(arguments, status: result.status,
                                                      output: result.output)
        }
    }

    /// Captures launchctl's output rather than letting it through. A fresh
    /// install has nothing to boot out, and launchctl announces that on stderr
    /// as "Boot-out failed: 3: No such process", an alarming first line for a
    /// command that worked. Captured, it can be reported on the failures that
    /// do matter instead.
    static func launchctl(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        // Read before waiting: a full pipe buffer deadlocks the wait.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus,
                String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

extension AgentInstallerError: CustomStringConvertible {
    var description: String {
        switch self {
        case let .launchctlFailed(arguments, status, output):
            // launchctl's diagnostic says more than its exit status, so lead
            // with it, then the command for rerunning by hand.
            let said = output.isEmpty ? "" : "\(output) "
            return "launchctl \(arguments[0]) failed (status \(status)): \(said)"
                 + "[launchctl \(arguments.joined(separator: " "))]"
        case let .binaryNotFound(path):
            return "cannot find the running unflicker binary (looked at \(path))"
        }
    }
}
