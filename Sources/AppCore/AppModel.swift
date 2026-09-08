import Combine
import Foundation
import UVCCore

public struct CameraStatus: Equatable, Sendable, Identifiable {
    public let id: UInt64
    public let device: UVCDeviceID
    public let name: String
    public let detail: String
}

@MainActor
public final class AppModel: ObservableObject {
    @Published public private(set) var cameras: [CameraStatus] = []
    @Published public private(set) var choice: PowerLineChoice
    @Published public private(set) var reapplyOnAttach: Bool
    @Published public private(set) var obstacle: String?
    @Published public private(set) var problems: [String] = []

    private let transport: any UVCTransport
    private let settings: GroupSettings
    private let registrar: any AgentRegistrar
    private let watcher: any DeviceWatcher

    public init(transport: any UVCTransport, settings: GroupSettings,
                registrar: any AgentRegistrar, watcher: any DeviceWatcher) {
        self.transport = transport
        self.settings = settings
        self.registrar = registrar
        self.watcher = watcher
        // A 60Hz supply has no banding to fix, so anyone running this is
        // almost certainly on 50Hz. The CLI's `install` writes the same
        // default into its config for the same reason.
        let stored = settings.powerLine ?? .hz50
        settings.powerLine = stored
        choice = stored
        reapplyOnAttach = registrar.registered
        obstacle = registrar.obstacle
        watcher.start { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Each action rebuilds `problems` from scratch, so a fault that has
    /// stopped happening stops being shown.
    public func refresh() {
        problems = []
        reload()
    }

    public func choose(_ new: PowerLineChoice) {
        settings.powerLine = new
        choice = new
        problems = []
        applyNow()
        // After the write, so the listed values are the ones now on the
        // cameras; keeps the faults applyNow just recorded.
        reload()
    }

    public func setReapply(_ on: Bool) {
        problems = []
        do {
            if on { try registrar.register() } else { try registrar.unregister() }
        } catch {
            problems.append(String(describing: error))
        }
        // What launchd actually holds, not what was asked for.
        reapplyOnAttach = registrar.registered
        obstacle = registrar.obstacle
    }

    private func reload() {
        do {
            cameras = try transport.devices().map(status(of:))
        } catch {
            // An enumeration that fails outright is a real fault; an empty
            // list here would read as "no cameras attached".
            cameras = []
            problems.append(String(describing: error))
        }
    }

    private func status(of info: UVCDeviceInfo) -> CameraStatus {
        let detail: String
        do {
            let connection = try transport.open(info)
            defer { connection.close() }
            if let control = UVCControl.named(GroupSettings.powerLineKey),
               connection.supported.contains(control.name) {
                detail = control.format(try connection.current(control))
            } else {
                detail = "no anti-flicker control"
            }
        } catch {
            detail = String(describing: error)
        }
        return CameraStatus(id: info.registryID, device: info.id,
                            name: info.name, detail: detail)
    }

    /// Write the chosen value to every attached camera, through the same
    /// Apply the helper and the CLI use, so the outcome vocabulary is shared.
    private func applyNow() {
        do {
            let results = try Apply.run(transport: transport, config: settings,
                                        dryRun: false)
            for result in results {
                for outcome in result.outcomes {
                    Log.general.notice("\(result.device.description, privacy: .public): \(outcome.line, privacy: .public)")
                }
            }
            problems += results.flatMap { result in
                result.outcomes.filter(\.isFault)
                    .map { "\(result.device): \($0.line)" }
            }
        } catch {
            problems.append(String(describing: error))
        }
    }
}
