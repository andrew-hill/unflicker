import Foundation

/// Mistakes in what the user typed, as opposed to anything the camera did.
enum CLIError: Error, Equatable {
    case missingValue(String)
    case badDeviceID(String)
    case unknownFlag(command: String, flag: String)
    case unexpectedArgument(command: String, argument: String)
}

enum CLI {
    static let usage = """
    usage: unflicker <command>

      list                          cameras found, with vendor:product ids
      show [--device ID]            current values of every supported control
      set NAME=VALUE [--device ID]  set one control now
      apply [--dry-run]             read config, apply to all connected cameras
      install                       write and load the LaunchAgent
      uninstall                     unload and remove it
    """

    static func run(_ args: [String]) -> Int32 {
        guard args.count > 1 else {
            fail(usage)
            return 2
        }
        // Before the switch, so no command can forget it. `help` and an
        // unknown command are not in the table and fall straight through.
        do {
            try rejectUnknownArguments(args, command: args[1])
        } catch {
            fail("unflicker: \(error)\n\n\(usage)")
            return 2
        }

        switch args[1] {
        case "help", "-h", "--help":
            print(usage)
            return 0
        case "list":
            return listCameras(IOUSBHostTransport())
        case "show":
            do {
                return showControls(IOUSBHostTransport(), device: try deviceFilter(args))
            } catch {
                fail("unflicker: \(error)")
                return 2
            }
        case "apply":
            return applyConfig(IOUSBHostTransport(),
                               dryRun: args.contains("--dry-run"),
                               fromLaunchd: args.contains("--from-launchd"))
        case "set":
            do {
                // The assignment is the first bare NAME=VALUE. Picking "the
                // first non-flag argument" would swallow --device's value.
                return setControl(IOUSBHostTransport(),
                                  assignment: args.dropFirst(2).first { !$0.hasPrefix("--") && $0.contains("=") },
                                  device: try deviceFilter(args))
            } catch {
                fail("unflicker: \(error)")
                return 2
            }
        case "install":
            return install()
        case "uninstall":
            return uninstall()
        default:
            fail("unflicker: unknown command '\(args[1])'\n\n\(usage)")
            return 2
        }
    }

    static func fail(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    /// What each command accepts: its flags, and how many bare arguments it
    /// takes. Only `set` takes one, the NAME=VALUE assignment.
    static let accepted: [String: (flags: Set<String>, positionals: Int)] = [
        "list": ([], 0),
        "show": (["--device"], 0),
        "set": (["--device"], 1),
        "apply": (["--dry-run", "--from-launchd"], 0),
        "install": ([], 0),
        "uninstall": ([], 0),
    ]

    /// A misspelled flag must never read as its absence: `--dryrun` is a request
    /// for a dry run, and the write it would otherwise perform is the one thing
    /// the user asked not to happen.
    static func rejectUnknownArguments(_ args: [String], command: String) throws {
        guard let (allowed, positionals) = accepted[command] else { return }
        var seen = 0
        var index = 2
        while index < args.count {
            let arg = args[index]
            if arg.hasPrefix("--") {
                guard allowed.contains(arg) else {
                    throw CLIError.unknownFlag(command: command, flag: arg)
                }
                // `--device`'s value is a value, not a flag or a positional.
                // Leaving it to the loop would reject `--device --dry-run`
                // here, and `deviceFilter` gives that the better message.
                if arg == "--device" { index += 1 }
            } else {
                seen += 1
                guard seen <= positionals else {
                    throw CLIError.unexpectedArgument(command: command, argument: arg)
                }
            }
            index += 1
        }
    }

    /// nil means every camera, and that is why nothing else may fall through
    /// to nil. `--device 413c:dOO3` (capital O for zero) once meant "write to
    /// every camera attached", as did a trailing `--device` with no value.
    static func deviceFilter(_ args: [String]) throws -> UVCDeviceID? {
        guard let index = args.firstIndex(of: "--device") else { return nil }
        guard index + 1 < args.count else { throw CLIError.missingValue("--device") }
        guard let id = UVCDeviceID(args[index + 1]) else {
            throw CLIError.badDeviceID(args[index + 1])
        }
        return id
    }

    static func listCameras(_ transport: any UVCTransport) -> Int32 {
        do {
            let cameras = try transport.devices()
            if cameras.isEmpty {
                print("no UVC cameras found")
                return 0
            }
            for camera in cameras { print("\(camera.id)  \(camera.name)") }
            return 0
        } catch {
            fail("unflicker: \(error)")
            return 1
        }
    }

    static func showControls(_ transport: any UVCTransport, device: UVCDeviceID?) -> Int32 {
        do {
            var matched = false
            for camera in try transport.devices() where device == nil || camera.id == device {
                matched = true
                print("\(camera.id)  \(camera.name)")
                let connection = try transport.open(camera)
                defer { connection.close() }
                for line in try controlLines(connection) { print("  \(line)") }
            }
            // An empty bus is not an error. A --device matching nothing is the
            // same condition `set` already exits 1 for.
            if !matched {
                guard let device else {
                    print("no UVC cameras found")
                    return 0
                }
                fail("unflicker: no camera matching \(device)")
                return 1
            }
            return 0
        } catch {
            fail("unflicker: \(error)")
            return 1
        }
    }

    /// One line per control this camera advertises in bmControls. A control it
    /// then stalls is reported and skipped rather than ending the listing:
    /// `show` exists to display the controls that do work, and a camera may
    /// refuse any request it does not really implement. Reported with the same
    /// vocabulary `apply` uses. Anything that is not a stall is a real fault
    /// and still stops the command.
    static func controlLines(_ connection: any UVCConnection) throws -> [String] {
        var lines: [String] = []
        for control in UVCControl.all where connection.supported.contains(control.name) {
            do {
                let value = try connection.current(control)
                let range = try connection.range(control)
                lines.append("\(control.name) = \(control.format(value))  [\(range.lowerBound)..\(range.upperBound)]")
            } catch let UVCError.transferFailed(_, code) where code.isStall {
                lines.append(ApplyOutcome.stalled(control.name, code).line)
            }
        }
        return lines
    }

    static func applyConfig(_ transport: any UVCTransport, dryRun: Bool, fromLaunchd: Bool,
                            configPath: URL = Config.defaultPath) -> Int32 {
        let status = applyOnce(transport, dryRun: dryRun, fromLaunchd: fromLaunchd, configPath: configPath)

        // Always drain, whatever happened above. An early return that skips
        // this leaves the launchd event undelivered and gets us relaunched
        // every 10 seconds. The commonest early return is "no config file",
        // which is the state every fresh install starts in.
        //
        // `status` is deliberately dropped on this path. There is no KeepAlive
        // for launchd to react to, and a failed apply must not be made to look
        // like a crashing job; the reason is already in the log.
        guard fromLaunchd else { return status }
        let events = EventStream.drain(idle: 2.0)
        Log.agent.notice("drained \(events.count) event(s), exiting")
        return 0
    }

    /// The states in which `apply` has nothing to do. nil means there is work.
    ///
    /// Each needs saying out loud: printing nothing and exiting 0 is what a
    /// successful run looks like from outside. `cameras` is nil before the bus
    /// has been enumerated, so it is not mistaken for "none attached".
    static func nothingToDoNotice(config: Config?, cameras: Int?, at url: URL) -> String? {
        guard let config else {
            return "no config at \(url.path) - run `unflicker install` to write one"
        }
        if config.isEmpty { return "\(url.path) has no settings, nothing to apply" }
        if cameras == 0 { return "no UVC cameras found" }
        return nil
    }

    /// .notice, not .debug: this process exits immediately, and .debug/.info
    /// are not persisted for later `log show`. Why nothing happened is the
    /// first thing anyone looks for.
    private static func report(_ notice: String, fromLaunchd: Bool) {
        Log.general.notice("\(notice, privacy: .public)")
        if !fromLaunchd { print(notice) }
    }

    static func applyOnce(_ transport: any UVCTransport, dryRun: Bool, fromLaunchd: Bool,
                          configPath: URL = Config.defaultPath) -> Int32 {
        let config: Config
        do {
            // nil means no file, which is not an error: the config can be
            // deleted at any time. A file that exists but does not parse is a
            // different thing entirely and must be said out loud, or a typo
            // silently disables the tool forever.
            guard let loaded = try Config.load(configPath) else {
                report(nothingToDoNotice(config: nil, cameras: nil, at: configPath)!,
                       fromLaunchd: fromLaunchd)
                return 0
            }
            config = loaded
        } catch {
            Log.general.error("\(configPath.path, privacy: .public): \(String(describing: error), privacy: .public)")
            if !fromLaunchd { fail("unflicker: \(configPath.path): \(error)") }
            return 1
        }

        // Before enumerating: with an empty config there is nothing to wait for.
        if let notice = nothingToDoNotice(config: config, cameras: nil, at: configPath) {
            report(notice, fromLaunchd: fromLaunchd)
            return 0
        }

        do {
            // Only the launchd path waits: it knows an attach just happened and
            // the device may not answer yet. An interactive run with no camera
            // plugged in must not sit here for ten seconds.
            let cameras = try Apply.waitForDevices(transport: transport, budget: fromLaunchd ? 10 : 0)
            if let notice = nothingToDoNotice(config: config, cameras: cameras.count, at: configPath) {
                report(notice, fromLaunchd: fromLaunchd)
                return 0
            }
            // The outcome lines are identical either way, and reading them is
            // what --dry-run is for.
            if dryRun { report("dry run, nothing will be written:", fromLaunchd: fromLaunchd) }
            var faulted = false
            for result in try Apply.run(transport: transport, devices: cameras,
                                        config: config, dryRun: dryRun) {
                for outcome in result.outcomes {
                    Log.general.notice("\(result.device.description, privacy: .public): \(outcome.line, privacy: .public)")
                    if !fromLaunchd { print("\(result.device): \(outcome.line)") }
                    faulted = faulted || outcome.isFault
                }
            }
            // A failed transfer prints ", stopping" and used to exit 0 anyway,
            // which is the one combination a script cannot detect.
            if faulted { return 1 }
        } catch {
            Log.usb.error("apply failed: \(String(describing: error), privacy: .public)")
            if !fromLaunchd { fail("unflicker: \(error)") }
            return 1
        }
        return 0
    }

    /// `install` is the only command most people ever run, so it has to leave
    /// them with a working setup rather than an agent that fires on every
    /// attach and does nothing. Writing the config is part of installing.
    static func configNotice(created: Bool, at url: URL) -> String {
        created
            ? """
              wrote \(url.path): power-line-frequency = 50Hz
              change it to 60Hz if you are in North America or Japan
              """
            : "using the config already at \(url.path)"
    }

    static func install() -> Int32 {
        do {
            let binary = try AgentInstaller.binaryPath()
            let path = Config.defaultPath
            let created = try Config.createIfMissing(at: path)
            try AgentInstaller.install(binary: binary)
            print(configNotice(created: created, at: path))
            print("installed \(AgentInstaller.label) for \(binary)")
            // The absolute path, always: `log` is a zsh builtin that shadows
            // /usr/bin/log and fails while still exiting 0, so the bare form
            // looks like "nothing was logged".
            print("plug the camera in and check: /usr/bin/log show --last 2m --predicate 'subsystem == \"unflicker\"'")
            return 0
        } catch {
            fail("unflicker: install failed: \(error)")
            return 1
        }
    }

    static func uninstall() -> Int32 {
        do {
            try AgentInstaller.uninstall()
            print("removed \(AgentInstaller.label)")
            return 0
        } catch {
            fail("unflicker: uninstall failed: \(error)")
            return 1
        }
    }

    static func setControl(_ transport: any UVCTransport, assignment: String?, device: UVCDeviceID?) -> Int32 {
        guard let assignment, let equals = assignment.firstIndex(of: "=") else {
            fail("usage: unflicker set NAME=VALUE [--device ID]")
            return 2
        }
        let name = String(assignment[assignment.startIndex..<equals])
        let text = String(assignment[assignment.index(after: equals)...])

        // The user typed this, so an unknown name is a hard error here. Unlike
        // in apply, where the config may be shared with a machine that has
        // different cameras.
        guard let control = UVCControl.named(name) else {
            fail("unflicker: \(UVCControlError.unknownControl(name))")
            return 1
        }
        do {
            let results = try setOnce(transport, control: control,
                                      value: try control.parse(text), device: device)
            guard !results.isEmpty else {
                fail("unflicker: no matching camera")
                return 1
            }
            var wrote = true
            for result in results {
                for outcome in result.outcomes {
                    print("\(result.device): \(outcome.line)")
                    wrote = wrote && outcome.isWrite
                }
            }
            // Unsupported or out of range is `apply` skipping a line of a
            // shared config. Here it is the request the user typed not
            // happening, and must not be reported as success.
            return wrote ? 0 : 1
        } catch {
            fail("unflicker: \(error)")
            return 1
        }
    }

    /// One result per camera the device filter matched, reported with the same
    /// vocabulary `apply` uses so the two commands cannot drift apart. An empty
    /// array is the only thing that means "no matching camera": saying that
    /// after reporting on a camera that did match is a contradiction.
    static func setOnce(_ transport: any UVCTransport, control: UVCControl,
                        value: Int, device: UVCDeviceID?) throws -> [ApplyResult] {
        var results: [ApplyResult] = []
        for camera in try transport.devices() where device == nil || camera.id == device {
            let connection: any UVCConnection
            do {
                connection = try transport.open(camera)
            } catch {
                // Recorded, not thrown, for the reason `Apply.run` gives: a
                // throw discarded the writes already made to the cameras
                // before this one.
                results.append(ApplyResult(device: camera.id,
                                           outcomes: [Apply.notOpened(error, camera.id)]))
                continue
            }
            defer { connection.close() }

            let outcome: ApplyOutcome
            if !connection.supported.contains(control.name) {
                outcome = .unsupported(control.name)
            } else {
                do {
                    let range = try connection.range(control)
                    if range.contains(value) {
                        try connection.set(control, to: value)
                        outcome = .wrote(control.name, value)
                    } else {
                        outcome = .outOfRange(control.name, value, range)
                    }
                } catch UVCError.deviceGone {
                    // Reported rather than skipped. `apply` can drop a camera
                    // that vanishes, but here an empty array is what says no
                    // camera matched, and this one was here a moment ago.
                    outcome = Apply.notOpened(UVCError.deviceGone, camera.id)
                } catch let UVCError.transferFailed(_, code) where code.isStall {
                    outcome = .stalled(control.name, code)
                } catch {
                    outcome = Apply.reporting(error)
                }
            }
            results.append(ApplyResult(device: camera.id, outcomes: [outcome]))
        }
        return results
    }
}

extension CLIError: CustomStringConvertible {
    var description: String {
        switch self {
        case let .missingValue(flag):
            return "\(flag) needs a value"
        case let .badDeviceID(text):
            // Same shape as ConfigError.badSection: a vendor:product id is
            // spelled the same way in the config and on the command line.
            return "'\(text)' is not a vendor:product id like 046d:085b"
        case let .unknownFlag(command, flag):
            return "\(command) does not take \(flag)"
        case let .unexpectedArgument(command, argument):
            return "\(command) does not take '\(argument)'"
        }
    }
}
