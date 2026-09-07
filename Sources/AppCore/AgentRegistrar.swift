import Foundation
import ServiceManagement

/// What the model needs from SMAppService, cut so tests can fake it.
/// MainActor because `AppModel` is, and Swift 6 will not let a MainActor type
/// conform to a nonisolated protocol.
@MainActor
public protocol AgentRegistrar {
    var registered: Bool { get }
    /// Human-readable obstacle to registration, nil when there is none.
    var obstacle: String? { get }
    func register() throws
    func unregister() throws
}

public struct ServiceRegistrar: AgentRegistrar {
    /// Also the helper's launchd label and its file name in
    /// Contents/Library/LaunchAgents.
    public static let plistName = "net.thefrog.unflicker.agent.plist"
    private let service = SMAppService.agent(plistName: Self.plistName)

    public init() {}

    public var registered: Bool { service.status == .enabled }

    public var obstacle: String? {
        switch service.status {
        case .requiresApproval:
            return "approve unflicker in System Settings > General > Login Items"
        case .notFound:
            return "the helper's launchd plist is missing from the app bundle"
        default:
            return nil
        }
    }

    public func register() throws { try service.register() }
    public func unregister() throws { try service.unregister() }
}
