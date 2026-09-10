import Testing
import Foundation
import UVCCore
@testable import AppCore

// Serialized: these cases share a UserDefaults suite, and swift-testing runs
// tests in parallel by default.
@Suite(.serialized) struct GroupSettingsTests {
    let defaults: UserDefaults
    let settings: GroupSettings

    init() {
        defaults = UserDefaults(suiteName: "net.thefrog.unflicker.tests")!
        defaults.removePersistentDomain(forName: "net.thefrog.unflicker.tests")
        settings = GroupSettings(defaults: defaults)
    }

    @Test func unsetReadsNilAndSuppliesNothing() {
        #expect(settings.powerLine == nil)
        #expect(settings.settings(for: UVCDeviceID("413c:d003")!).isEmpty)
    }

    @Test func choiceRoundTripsAndSuppliesTheControl() {
        settings.powerLine = .hz50
        #expect(settings.powerLine == .hz50)
        #expect(settings.settings(for: UVCDeviceID("413c:d003")!)
                == ["power-line-frequency": "50Hz"])
    }

    @Test func garbageInTheSuiteReadsAsUnset() {
        defaults.set("55Hz", forKey: "power-line-frequency")
        #expect(settings.powerLine == nil)
        #expect(settings.settings(for: UVCDeviceID("413c:d003")!).isEmpty)
    }

    @Test func settingNilClearsTheKey() {
        settings.powerLine = .hz50
        settings.powerLine = nil
        #expect(defaults.object(forKey: "power-line-frequency") == nil)
    }

    @Test func storedSpellingIsWhatTheCatalogueParses() throws {
        let control = try #require(UVCControl.named("power-line-frequency"))
        #expect(try control.parse(PowerLineChoice.hz50.rawValue) == 1)
        #expect(try control.parse(PowerLineChoice.hz60.rawValue) == 2)
    }
}
