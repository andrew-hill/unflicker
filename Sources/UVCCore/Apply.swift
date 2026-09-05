import Foundation

public enum ApplyOutcome: Equatable {
    case alreadyCorrect(String, Int)
    case changed(String, from: Int, to: Int)
    /// The camera completed `SET_CUR` and `GET_CUR` still disagrees. Observed
    /// on the C925e; see docs/hardware.md. An ACK is not evidence the value
    /// took, so nothing is reported as changed without a read back.
    case notKept(String, wrote: Int, reads: Int)
    case unsupported(String)
    /// The config parsed but has nothing for this camera. Reported rather than
    /// skipped: a camera that produces no output at all reads as "everything
    /// was already correct".
    case noSettings
    /// The camera advertised the control in bmControls and then stalled the
    /// transfer. Skipped, not fatal. See `UVCError.stallCode`.
    case stalled(String, IOReturnCode)
    case outOfRange(String, Int, ClosedRange<Int>)
    case unknownControl(String)
    case badValue(String, String)
    /// A USB transfer that failed for a reason other than an unplug. Carries
    /// the rendered error so the IOKit code survives into the output.
    case failed(String)
    /// Enumerated, then would not open, or in `set` went away before the write
    /// landed. Carries the rendered reason without the device id, which is
    /// already the prefix of every printed line.
    case notOpened(String)
    /// The camera has no processing unit, so it has no controls at all. The
    /// whole-device form of `.unsupported`, and skipped for the same reason.
    case noProcessingUnit
    /// `set` wrote a value. `apply` never produces this: it reports `.changed`
    /// against the value it read first.
    case wrote(String, Int)

    public var line: String {
        switch self {
        case let .alreadyCorrect(name, value):
            return "\(name) already \(UVCControl.named(name)?.format(value) ?? String(value))"
        case let .changed(name, from, to):
            let control = UVCControl.named(name)
            return "\(name) \(control?.format(from) ?? String(from)) -> \(control?.format(to) ?? String(to))"
        case let .notKept(name, wrote, reads):
            let control = UVCControl.named(name)
            return "\(name) accepted \(control?.format(wrote) ?? String(wrote)) but reads \(control?.format(reads) ?? String(reads))"
        case let .unsupported(name):
            return "\(name) not supported by this camera, skipped"
        case .noSettings:
            return "nothing in the config applies to this camera"
        case let .stalled(name, code):
            return "\(name) advertised but not supported by this camera (IOKit \(code)), skipped"
        case let .outOfRange(name, value, range):
            // The user wrote `auto`; the device counts in raw integers. Show
            // both, or the message cannot be matched up with the config line.
            let friendly = UVCControl.named(name)?.format(value) ?? String(value)
            let shown = friendly == String(value) ? friendly : "\(friendly) (\(value))"
            return "\(name) \(shown) outside device range \(range.lowerBound)..\(range.upperBound), skipped"
        case let .unknownControl(name):
            return "\(name) is not a control unflicker knows, skipped"
        case let .badValue(name, text):
            // UVCControlError already lists the accepted spellings. Rebuilding
            // a shorter message here made `apply` and `set` disagree.
            return "\(UVCControlError.badValue(control: name, text: text)), skipped"
        case let .failed(detail):
            return "\(detail), stopping"
        case let .notOpened(reason):
            return "\(reason), skipped"
        case .noProcessingUnit:
            return "exposes no UVC processing unit, skipped"
        case let .wrote(name, value):
            return "\(name) = \(UVCControl.named(name)?.format(value) ?? String(value))"
        }
    }
}

extension ApplyOutcome {
    /// A transfer that failed for a reason other than an unplug or a stall, so
    /// `apply` must exit non-zero. It tolerates every other outcome: a config
    /// is shared between machines, and naming a control this camera does not
    /// have is not the run failing.
    ///
    /// `.badValue` is the exception. An unknown control name or an
    /// out-of-range value is about this camera, and the same config is right on
    /// the machine whose camera has it. Text that will not parse is wrong
    /// everywhere.
    public var isFault: Bool {
        switch self {
        case .failed, .notOpened, .badValue, .notKept: return true
        default: return false
        }
    }

    /// `set` is one request the user typed, so only the write is success. The
    /// outcomes `apply` skips over are exactly the ones `set` cannot.
    public var isWrite: Bool {
        if case .wrote = self { return true }
        return false
    }
}

public struct ApplyResult: Equatable {
    public let device: UVCDeviceID
    public let outcomes: [ApplyOutcome]

    public init(device: UVCDeviceID, outcomes: [ApplyOutcome]) {
        self.device = device
        self.outcomes = outcomes
    }
}

/// What Apply needs from configuration. The CLI's Config conforms; the app's
/// UserDefaults reader will.
public protocol SettingsSource {
    func settings(for id: UVCDeviceID) -> [String: String]
}

public enum Apply {
    public static func run(transport: any UVCTransport, config: any SettingsSource, dryRun: Bool) throws -> [ApplyResult] {
        try run(transport: transport, devices: transport.devices(), config: config, dryRun: dryRun)
    }

    /// `devices` is passed in because the caller has usually just waited for
    /// them to appear.
    public static func run(transport: any UVCTransport, devices: [UVCDeviceInfo],
                    config: any SettingsSource, dryRun: Bool) throws -> [ApplyResult] {
        var results: [ApplyResult] = []
        for camera in devices {
            let settings = config.settings(for: camera.id)
            if settings.isEmpty {
                results.append(ApplyResult(device: camera.id, outcomes: [.noSettings]))
                continue
            }

            let connection: any UVCConnection
            do {
                connection = try transport.open(camera)
            } catch UVCError.deviceGone {
                continue        // unplugged between enumerate and open
            } catch {
                // Recorded against this camera, not thrown. Rethrowing cost
                // every camera behind this one its settings, and discarded the
                // results of the ones already done.
                results.append(ApplyResult(device: camera.id, outcomes: [notOpened(error, camera.id)]))
                continue
            }
            defer { connection.close() }
            results.append(ApplyResult(device: camera.id,
                                       outcomes: apply(connection, settings, dryRun: dryRun)))
        }
        return results
    }

    /// Sorted by control name so output and tests are deterministic.
    private static func apply(_ connection: any UVCConnection,
                              _ settings: [String: String],
                              dryRun: Bool) -> [ApplyOutcome] {
        var outcomes: [ApplyOutcome] = []
        for name in settings.keys.sorted() {
            let text = settings[name]!
            guard let control = UVCControl.named(name) else {
                outcomes.append(.unknownControl(name))
                continue
            }
            guard connection.supported.contains(control.name) else {
                outcomes.append(.unsupported(control.name))
                continue
            }
            guard let wanted = try? control.parse(text) else {
                outcomes.append(.badValue(control.name, text))
                continue
            }
            let range: ClosedRange<Int>
            let current: Int
            do {
                range = try connection.range(control)
                current = try connection.current(control)
            } catch UVCError.deviceGone {
                return outcomes             // someone pulled the cable; not an error
            } catch let UVCError.transferFailed(_, code) where code.isStall {
                outcomes.append(.stalled(control.name, code))
                continue
            } catch {
                outcomes.append(reporting(error))
                return outcomes
            }
            guard range.contains(wanted) else {
                outcomes.append(.outOfRange(control.name, wanted, range))
                continue
            }
            if current == wanted {
                outcomes.append(.alreadyCorrect(control.name, current))
                continue
            }
            if !dryRun {
                do {
                    try connection.set(control, to: wanted)
                } catch UVCError.deviceGone {
                    return outcomes
                } catch let UVCError.transferFailed(_, code) where code.isStall {
                    outcomes.append(.stalled(control.name, code))
                    continue
                } catch {
                    outcomes.append(reporting(error))
                    return outcomes
                }
                do {
                    let readBack = try connection.current(control)
                    guard readBack == wanted else {
                        outcomes.append(.notKept(control.name, wrote: wanted, reads: readBack))
                        continue
                    }
                } catch UVCError.deviceGone {
                    return outcomes
                } catch {
                    // Not `.stalled`: this control answered GET_CUR seconds
                    // ago, so a refusal now is not "advertised but absent".
                    outcomes.append(reporting(error))
                    return outcomes
                }
            }
            outcomes.append(.changed(control.name, from: current, to: wanted))
        }
        return outcomes
    }

    /// The device id is the prefix of every printed line, so the reason drops
    /// it rather than saying it twice. Shared with `set`, which reports the
    /// same conditions in the same words.
    public static func notOpened(_ error: any Error, _ id: UVCDeviceID) -> ApplyOutcome {
        Log.usb.error("open \(id.description, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        switch error {
        case UVCError.noProcessingUnit:
            return .noProcessingUnit
        case let UVCError.openFailed(_, code):
            return .notOpened("could not open: IOKit \(code)")
        default:
            return .notOpened("\(error)")
        }
    }

    /// Anything that is not an unplug. The raw IOKit code is the whole
    /// diagnosis if launchd USB access ever breaks (see `IOReturnCode`), so it
    /// goes to the log *and* into the outcome the caller prints.
    public static func reporting(_ error: any Error) -> ApplyOutcome {
        Log.usb.error("\(String(describing: error), privacy: .public)")
        return .failed("\(error)")
    }
}

extension Apply {
    /// A camera appears in the IORegistry before it will answer control
    /// transfers, so poll briefly rather than assuming a fixed settling time.
    /// `sleep` is injected so tests do not actually wait.
    ///
    /// A budget of 0 checks once and returns, which is what an interactive run
    /// wants: there is no attach in flight to wait for.
    public static func waitForDevices(transport: any UVCTransport,
                               budget: TimeInterval,
                               sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) throws -> [UVCDeviceInfo] {
        var interval: TimeInterval = 0.25
        var elapsed: TimeInterval = 0
        while true {
            // Deliberately not `try?`: an enumeration that fails outright is a
            // real fault, and swallowing it here reads as "no camera attached".
            let found = try transport.devices()
            if !found.isEmpty { return found }
            if elapsed + interval > budget {
                if budget > 0 {
                    Log.usb.notice("no camera answered within \(Int(budget), privacy: .public)s, giving up")
                }
                return []
            }
            sleep(interval)
            elapsed += interval
            interval = min(interval * 2, 2.0)
        }
    }
}
