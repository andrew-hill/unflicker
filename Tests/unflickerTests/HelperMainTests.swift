import Testing
import Foundation
@testable import UVCCore
@testable import AppCore

private let dell = UVCDeviceInfo(id: UVCDeviceID("413c:d003")!,
                                 name: "Dell Display 4MP Webcam", registryID: 1)

// Serialized: these cases share a UserDefaults suite, and swift-testing runs
// tests in parallel by default.
@Suite(.serialized) struct HelperMainTests {
    final class Recorder {
        var sequence: [String] = []
    }

    func drain(into recorder: Recorder) -> (TimeInterval) -> [String] {
        { _ in recorder.sequence.append("drain"); return [] }
    }

    @Test func unconfiguredDrainsWithoutTouchingTheBus() {
        let recorder = Recorder()
        let defaults = UserDefaults(suiteName: "net.thefrog.unflicker.helper-tests")!
        defaults.removePersistentDomain(forName: "net.thefrog.unflicker.helper-tests")
        let connection = FakeConnection(supported: ["power-line-frequency"],
                                        values: ["power-line-frequency": 2],
                                        ranges: ["power-line-frequency": 0...2])
        let transport = FakeTransport(
            infos: [dell], connections: [dell.id: connection])
        HelperMain.run(transport: transport,
                       settings: GroupSettings(defaults: defaults),
                       budget: 0, drain: drain(into: recorder))
        #expect(connection.writes.isEmpty)
        #expect(recorder.sequence == ["drain"])
    }

    @Test func configuredAppliesThenDrains() {
        let recorder = Recorder()
        let defaults = UserDefaults(suiteName: "net.thefrog.unflicker.helper-tests")!
        defaults.removePersistentDomain(forName: "net.thefrog.unflicker.helper-tests")
        let settings = GroupSettings(defaults: defaults)
        settings.powerLine = .hz50
        let connection = FakeConnection(supported: ["power-line-frequency"],
                                        values: ["power-line-frequency": 2],
                                        ranges: ["power-line-frequency": 0...2])
        let transport = FakeTransport(
            infos: [dell], connections: [dell.id: connection])
        HelperMain.run(transport: transport, settings: settings,
                       budget: 0, drain: { _ in
                           // The drain must come after the apply: the write is
                           // already recorded when it runs, or it ran too early.
                           recorder.sequence.append(connection.writes.isEmpty
                                                    ? "drain-before-apply" : "drain")
                           return []
                       })
        #expect(connection.writes.map { $0.0 } == ["power-line-frequency"])
        #expect(connection.writes.map { $0.1 } == [1])
        #expect(recorder.sequence == ["drain"])
    }

    @Test func missingSuiteStillDrains() {
        let recorder = Recorder()
        let connection = FakeConnection(supported: ["power-line-frequency"],
                                        values: ["power-line-frequency": 2],
                                        ranges: ["power-line-frequency": 0...2])
        let transport = FakeTransport(
            infos: [dell], connections: [dell.id: connection])
        HelperMain.run(transport: transport, settings: nil,
                       budget: 0, drain: drain(into: recorder))
        #expect(connection.writes.isEmpty)
        #expect(recorder.sequence == ["drain"])
    }

    @Test func enumerationFailureStillDrains() {
        struct BrokenTransport: UVCTransport {
            func devices() throws -> [UVCDeviceInfo] {
                throw UVCError.enumerationFailed(IOReturnCode(value: -1))
            }
            func open(_ device: UVCDeviceInfo) throws -> any UVCConnection {
                throw UVCError.deviceGone
            }
        }
        let recorder = Recorder()
        let defaults = UserDefaults(suiteName: "net.thefrog.unflicker.helper-tests")!
        defaults.removePersistentDomain(forName: "net.thefrog.unflicker.helper-tests")
        let settings = GroupSettings(defaults: defaults)
        settings.powerLine = .hz60
        HelperMain.run(transport: BrokenTransport(), settings: settings,
                       budget: 0, drain: drain(into: recorder))
        #expect(recorder.sequence == ["drain"])
    }
}
