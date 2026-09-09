import Foundation
import XPC

// launchd.plist(5): a job using LaunchEvents "promises to use the
// xpc_set_event_stream_handler(3) API to consume events". A job that doesn't
// leaves the event undelivered, and launchd relaunches it every 10 seconds
// forever. A shell script cannot call the API at all, and a spike doing
// exactly that produced a flat 10 s cadence: the polling behaviour this whole
// project exists to avoid.
public enum EventStream {
    /// Installs the handler, then returns the events seen once the stream has
    /// been quiet for `idle` seconds. xpc(3) warns that events can be dropped
    /// if the process exits while the handler is still running, hence waiting
    /// for quiet rather than returning on the first event.
    ///
    /// `cap` bounds the whole wait. Every event rearms the idle timer, so a
    /// device re-enumerating faster than `idle` would keep this process
    /// resident. Exiting early drops nothing: xpc_events(3) says "an event is
    /// consumed when it is delivered to the handler", so the 10-second respawn
    /// loop cannot come back.
    @discardableResult
    public static func drain(idle: TimeInterval, cap: TimeInterval = 30) -> [String] {
        let queue = DispatchQueue(label: "net.thefrog.unflicker.events")
        let quiet = DispatchSemaphore(value: 0)
        let seen = Collector()
        // Touched only in the handler, which `queue` serialises, so no lock,
        // but the compiler cannot see that through xpc's C callback type.
        nonisolated(unsafe) var schedule = DrainSchedule(start: .now(), idle: idle, cap: cap)

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { quiet.signal() }
        timer.schedule(deadline: schedule.first)
        timer.resume()

        xpc_set_event_stream_handler("com.apple.iokit.matching", queue) { event in
            let name = xpc_dictionary_get_string(event, XPC_EVENT_KEY_NAME)
                .map { String(cString: $0) } ?? "(unnamed)"
            seen.add(name)
            Log.agent.notice("event \(name, privacy: .public)")
            let rearmed = schedule.rearm(after: .now())
            if rearmed.announce {
                // Afterwards the log is all there is to tell a drain cut
                // short from a bus that went quiet.
                Log.agent.notice("still arriving after \(Int(cap), privacy: .public)s, exiting anyway")
            }
            timer.schedule(deadline: rearmed.deadline)
        }

        quiet.wait()
        timer.cancel()
        return seen.all
    }
}

/// When the idle timer fires next. Every event pushes it out by another `idle`
/// window, and the cap bounds the whole wait, so a device re-enumerating faster
/// than `idle` cannot keep this process resident. Separate from `drain` because
/// reaching the cap on a real bus means holding the wait open for its full
/// length, which the cap is intended to prevent.
struct DrainSchedule {
    private let start: DispatchTime
    private let idle: TimeInterval
    private let cap: TimeInterval
    private var announced = false

    init(start: DispatchTime, idle: TimeInterval, cap: TimeInterval) {
        self.start = start
        self.idle = idle
        self.cap = cap
    }

    var deadline: DispatchTime { start + cap }

    /// Where the timer is armed before any event arrives.
    var first: DispatchTime { min(start + idle, deadline) }

    /// `announce` is true once only: events still arriving inside the last idle
    /// window would each log the same line.
    mutating func rearm(after now: DispatchTime) -> (deadline: DispatchTime, announce: Bool) {
        let next = now + idle
        guard next > deadline else { return (next, false) }
        defer { announced = true }
        return (deadline, !announced)
    }
}

/// The handler and the timer share one serial queue, so this is only ever
/// touched from a single thread. The compiler cannot see that, and silencing it
/// with a lock is cheaper than arguing.
private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []

    func add(_ name: String) {
        lock.lock()
        defer { lock.unlock() }
        names.append(name)
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return names
    }
}
