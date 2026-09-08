import Testing
import Foundation
@testable import UVCCore
@testable import AppCore

@MainActor
final class FakeRegistrar: AgentRegistrar {
    var registered = false
    var obstacle: String?
    var failure: Error?
    func register() throws { if let failure { throw failure }; registered = true }
    func unregister() throws { if let failure { throw failure }; registered = false }
}

final class FakeWatcher: DeviceWatcher {
    private var onChange: (@Sendable () -> Void)?
    var watching: Bool { onChange != nil }
    func start(onChange: @escaping @Sendable () -> Void) { self.onChange = onChange }
    /// A camera arrived or left.
    func fire() { onChange?() }
}

private enum TestFailure: Error { case boom }

/// Enumeration that can be made to fail, or to answer with a different set of
/// cameras, which a struct FakeTransport cannot: AppModel holds the transport
/// it was built with.
private final class MutableTransport: UVCTransport {
    var failure: UVCError?
    var inner: FakeTransport

    init(_ inner: FakeTransport) { self.inner = inner }

    func devices() throws -> [UVCDeviceInfo] {
        if let failure { throw failure }
        return try inner.devices()
    }

    func open(_ device: UVCDeviceInfo) throws -> any UVCConnection { try inner.open(device) }
}

private let dellID = UVCDeviceID("413c:d003")!

/// The Dell's shape: `power-line-frequency` current 2, range 0...2.
private func dellCamera(powerLineFrequency: Int = 2,
                        registryID: UInt64 = 7) -> (UVCDeviceInfo, FakeConnection) {
    let info = UVCDeviceInfo(id: dellID, name: "Dell Monitor Webcam", registryID: registryID)
    let conn = FakeConnection(
        supported: ["power-line-frequency"],
        values: ["power-line-frequency": powerLineFrequency],
        ranges: ["power-line-frequency": 0...2]
    )
    return (info, conn)
}

// Serialized: these cases share a UserDefaults suite, and swift-testing runs
// tests in parallel by default.
@MainActor
@Suite(.serialized)
struct AppModelTests {
    let defaults: UserDefaults
    let settings: GroupSettings

    init() {
        defaults = UserDefaults(suiteName: "net.thefrog.unflicker.tests.appmodel")!
        defaults.removePersistentDomain(forName: "net.thefrog.unflicker.tests.appmodel")
        settings = GroupSettings(defaults: defaults)
    }

    @Test func refreshListsCamerasWithFormattedValues() {
        let (info, connection) = dellCamera(powerLineFrequency: 2)
        let transport = FakeTransport(infos: [info], connections: [info.id: connection])
        let model = AppModel(transport: transport, settings: settings,
                             registrar: FakeRegistrar(), watcher: FakeWatcher())

        model.refresh()

        #expect(model.cameras == [CameraStatus(id: info.registryID, device: dellID,
                                               name: info.name, detail: "60Hz")])
    }

    @Test func cameraWithoutTheControlStillAppears() {
        let info = UVCDeviceInfo(id: dellID, name: "Dell Monitor Webcam", registryID: 7)
        let connection = FakeConnection(supported: [], values: [:], ranges: [:])
        let transport = FakeTransport(infos: [info], connections: [dellID: connection])
        let model = AppModel(transport: transport, settings: settings,
                             registrar: FakeRegistrar(), watcher: FakeWatcher())

        model.refresh()

        #expect(model.cameras.map(\.detail) == ["no anti-flicker control"])
    }

    @Test func cameraThatRefusesToOpenStillAppears() {
        let info = UVCDeviceInfo(id: dellID, name: "Dell Monitor Webcam", registryID: 7)
        let code = IOReturnCode(value: Int32(bitPattern: 0xe00002c9))
        let transport = FakeTransport(infos: [info], connections: [:],
                                      openErrors: [dellID: .openFailed(dellID, code)])
        let model = AppModel(transport: transport, settings: settings,
                             registrar: FakeRegistrar(), watcher: FakeWatcher())

        model.refresh()

        #expect(model.cameras.count == 1)
        #expect(model.cameras[0].detail == UVCError.openFailed(dellID, code).description)
        #expect(model.cameras[0].detail.contains("0xe00002c9"))
    }

    @Test func chooseWritesAndPersists() {
        let (info, connection) = dellCamera(powerLineFrequency: 2)
        let transport = FakeTransport(infos: [info], connections: [info.id: connection])
        let model = AppModel(transport: transport, settings: settings,
                             registrar: FakeRegistrar(), watcher: FakeWatcher())

        model.choose(.hz50)

        #expect(settings.powerLine == .hz50)
        #expect(connection.writes.contains { $0.0 == "power-line-frequency" && $0.1 == 1 })
        #expect(model.choice == .hz50)
        #expect(model.problems.isEmpty)
    }

    @Test func chooseSurfacesFaults() {
        let (info, connection) = dellCamera(powerLineFrequency: 2)
        connection.fail(.transferFailed(control: "power-line-frequency",
                                        code: IOReturnCode(value: Int32(bitPattern: 0xe00002c9))),
                        on: "power-line-frequency", reads: false)
        let transport = FakeTransport(infos: [info], connections: [info.id: connection])
        let model = AppModel(transport: transport, settings: settings,
                             registrar: FakeRegistrar(), watcher: FakeWatcher())

        model.choose(.hz50)

        #expect(!model.problems.isEmpty)
        #expect(model.problems.contains { $0.contains(dellID.description) })
    }

    @Test func transientFaultClearsOnTheNextRefresh() {
        let (info, connection) = dellCamera(powerLineFrequency: 2)
        let transport = MutableTransport(FakeTransport(infos: [info],
                                                       connections: [info.id: connection]))
        let model = AppModel(transport: transport, settings: settings,
                             registrar: FakeRegistrar(), watcher: FakeWatcher())

        transport.failure = .deviceGone
        model.refresh()
        #expect(!model.problems.isEmpty)

        transport.failure = nil
        model.refresh()

        #expect(model.problems.isEmpty)
        #expect(model.cameras.map(\.detail) == ["60Hz"])
    }

    @Test func setReapplyRegistersAndUnregisters() {
        let registrar = FakeRegistrar()
        let model = AppModel(transport: FakeTransport(infos: [], connections: [:]),
                             settings: settings, registrar: registrar,
                             watcher: FakeWatcher())

        model.setReapply(true)
        #expect(registrar.registered)
        #expect(model.reapplyOnAttach)

        model.setReapply(false)
        #expect(!registrar.registered)
        #expect(!model.reapplyOnAttach)
    }

    @Test func throwingRegistrarLandsInProblems() {
        let registrar = FakeRegistrar()
        registrar.failure = TestFailure.boom
        let model = AppModel(transport: FakeTransport(infos: [], connections: [:]),
                             settings: settings, registrar: registrar,
                             watcher: FakeWatcher())

        model.setReapply(true)

        #expect(!model.problems.isEmpty)
        // What launchd actually holds, not what was asked for.
        #expect(model.reapplyOnAttach == registrar.registered)
        #expect(model.reapplyOnAttach == false)
    }

    @Test func unsetChoiceDefaultsToFiftyAndIsStored() {
        let model = AppModel(transport: FakeTransport(infos: [], connections: [:]),
                             settings: settings, registrar: FakeRegistrar(),
                             watcher: FakeWatcher())

        #expect(model.choice == .hz50)
        // Stored, not merely displayed: the helper reads the suite, and an
        // unwritten default reaches it as "not configured yet".
        #expect(settings.powerLine == .hz50)
    }

    @Test func attachRefreshesTheCameraList() async {
        let watcher = FakeWatcher()
        let transport = MutableTransport(FakeTransport(infos: [], connections: [:]))
        let model = AppModel(transport: transport, settings: settings,
                             registrar: FakeRegistrar(), watcher: watcher)
        model.refresh()
        #expect(model.cameras.isEmpty)
        #expect(watcher.watching)

        let (info, connection) = dellCamera(powerLineFrequency: 2)
        transport.inner = FakeTransport(infos: [info], connections: [info.id: connection])
        watcher.fire()
        await Task.yield()

        #expect(model.cameras.map(\.name) == ["Dell Monitor Webcam"])
    }

    @Test func initReadsReality() {
        settings.powerLine = .hz60
        let registrar = FakeRegistrar()
        registrar.registered = true
        let model = AppModel(transport: FakeTransport(infos: [], connections: [:]),
                             settings: settings, registrar: registrar,
                             watcher: FakeWatcher())

        #expect(model.reapplyOnAttach == true)
        #expect(model.choice == .hz60)
    }
}
