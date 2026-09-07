import Foundation
import UVCCore

/// The two values the app offers. `disabled` and `auto` exist in the UVC
/// catalogue but not in the UI: someone who wants them has the CLI, and a
/// one-setting utility offering "disabled" is a support thread waiting to
/// happen.
public enum PowerLineChoice: String, CaseIterable, Sendable {
    case hz50 = "50Hz"
    case hz60 = "60Hz"
}

/// The one setting, in the App Group suite so the app (writer) and the helper
/// (reader) see the same value from different containers.
public struct GroupSettings {
    public static let suiteName = "group.net.thefrog.unflicker"
    /// Doubles as the UVC control name; the stored string is the control's
    /// display spelling, so `settings(for:)` needs no translation table.
    public static let powerLineKey = "power-line-frequency"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) { self.defaults = defaults }

    /// nil only for the caller's own bundle identifier or a global domain,
    /// neither of which `suiteName` is. Entitlements are not consulted: a
    /// build without `application-groups` gets a working object backed by a
    /// private suite, and app and helper then read different containers
    /// without either of them failing.
    public static func standard() -> GroupSettings? {
        UserDefaults(suiteName: suiteName).map(GroupSettings.init)
    }

    /// nil = never configured. A stored string that is not a choice also
    /// reads as unset: the app is the only writer, this is not user-typed
    /// input, and "no selection" in the UI is the recovery.
    public var powerLine: PowerLineChoice? {
        get { defaults.string(forKey: Self.powerLineKey).flatMap(PowerLineChoice.init(rawValue:)) }
        nonmutating set {
            if let newValue {
                defaults.set(newValue.rawValue, forKey: Self.powerLineKey)
            } else {
                defaults.removeObject(forKey: Self.powerLineKey)
            }
        }
    }
}

extension GroupSettings: SettingsSource {
    /// The same choice for every camera. Apply already reports unsupported
    /// and stalled per camera, so no per-device shaping happens here.
    public func settings(for id: UVCDeviceID) -> [String: String] {
        guard let choice = powerLine else { return [:] }
        return [Self.powerLineKey: choice.rawValue]
    }
}
