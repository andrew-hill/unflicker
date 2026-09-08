import Foundation
import IOKit
import UVCCore

/// Attach and detach while the window is open. Without one, the list shows
/// whatever it read at launch or at the last activation. Not a timer: avoid
/// polling.
public protocol DeviceWatcher: AnyObject {
    /// `onChange` lands on the main queue. Runs until the watcher is
    /// released, which for the app means until it quits.
    func start(onChange: @escaping @Sendable () -> Void)
}

public final class IOKitDeviceWatcher: DeviceWatcher {
    private var port: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private var onChange: (@Sendable () -> Void)?

    public init() {}

    public func start(onChange: @escaping @Sendable () -> Void) {
        guard port == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.onChange = onChange
        self.port = port
        IONotificationPortSetDispatchQueue(port, .main)
        let watcher = Unmanaged.passUnretained(self).toOpaque()
        for kind in [kIOMatchedNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            guard IOServiceAddMatchingNotification(port, kind, USBEnumeration.cameraMatching(),
                                                   cameraChanged, watcher,
                                                   &iterator) == KERN_SUCCESS else { continue }
            iterators.append(iterator)
            // Arrives loaded with what already matches, and arms only once it
            // has been emptied. Nothing to report: the caller has just read
            // the bus itself.
            empty(iterator)
        }
    }

    deinit {
        iterators.forEach { IOObjectRelease($0) }
        if let port { IONotificationPortDestroy(port) }
    }

    /// One call per burst is not promised, and a camera brings its own hub up
    /// with it. `AppModel.refresh` is idempotent, so the extra reads cost a
    /// `GET_CUR` each and nothing else.
    fileprivate func fired(_ iterator: io_iterator_t) {
        empty(iterator)
        onChange?()
    }

    /// Draining is mandatory: an iterator holding services delivers no further
    /// notifications.
    private func empty(_ iterator: io_iterator_t) {
        var service = IOIteratorNext(iterator)
        while service != 0 {
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
    }
}

private let cameraChanged: IOServiceMatchingCallback = { watcher, iterator in
    guard let watcher else { return }
    Unmanaged<IOKitDeviceWatcher>.fromOpaque(watcher).takeUnretainedValue().fired(iterator)
}
