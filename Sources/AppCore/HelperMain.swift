import Foundation
import UVCCore

/// The whole helper, minus process exit, so the launchd contract is testable.
public enum HelperMain {
    /// Always drains before returning: an undrained event means launchd
    /// respawns the job every 10 seconds forever. The caller exits 0
    /// regardless of apply outcome — there is no KeepAlive for launchd to
    /// react to, and a failed apply must not look like a crashing job.
    public static func run(transport: any UVCTransport,
                           settings: GroupSettings?,
                           budget: TimeInterval = 10,
                           drain: (TimeInterval) -> [String] = { EventStream.drain(idle: $0) }) {
        defer {
            let events = drain(2.0)
            Log.agent.notice("drained \(events.count) event(s), exiting")
        }
        guard let settings else {
            Log.general.error("app group suite would not open")
            return
        }
        guard settings.powerLine != nil else {
            // A group container the two products do not actually share reads
            // the same way: the app wrote to its own private suite and this
            // one is empty. Only a value written there and read back here
            // tells the two apart.
            Log.general.notice("not configured yet, nothing to apply")
            return
        }
        do {
            let cameras = try Apply.waitForDevices(transport: transport, budget: budget)
            guard !cameras.isEmpty else {
                Log.general.notice("no UVC cameras found")
                return
            }
            for result in try Apply.run(transport: transport, devices: cameras,
                                        config: settings, dryRun: false) {
                for outcome in result.outcomes {
                    Log.general.notice("\(result.device.description, privacy: .public): \(outcome.line, privacy: .public)")
                }
            }
        } catch {
            Log.general.error("\(String(describing: error), privacy: .public)")
        }
    }
}
