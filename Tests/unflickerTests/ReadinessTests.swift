import Foundation
import Testing
@testable import UVCCore
@testable import unflicker

/// Reports no devices until `appearOnCall`, so the backoff can be driven
/// without waiting on anything real.
private struct EmptyThenFound: UVCTransport {
    final class Counter: @unchecked Sendable { var calls = 0 }
    let appearOnCall: Int
    let info: UVCDeviceInfo
    let counter = Counter()

    func devices() throws -> [UVCDeviceInfo] {
        counter.calls += 1
        return counter.calls >= appearOnCall ? [info] : []
    }
    func open(_ device: UVCDeviceInfo) throws -> any UVCConnection { throw UVCError.deviceGone }
}

@Test func backoffDoublesAndCapsAtTwoSeconds() throws {
    let (info, _) = c925e()
    let transport = EmptyThenFound(appearOnCall: 6, info: info)
    var slept: [TimeInterval] = []

    let found = try Apply.waitForDevices(transport: transport, budget: 10) { slept.append($0) }

    #expect(found.count == 1)
    #expect(slept == [0.25, 0.5, 1.0, 2.0, 2.0])
}

@Test func givesUpAfterTheBudget() throws {
    let (info, _) = c925e()
    let transport = EmptyThenFound(appearOnCall: .max, info: info)
    var total: TimeInterval = 0

    let found = try Apply.waitForDevices(transport: transport, budget: 10) { total += $0 }

    #expect(found.isEmpty)
    #expect(total <= 10)
}

@Test func returnsImmediatelyWhenTheCameraIsAlreadyThere() throws {
    let (info, _) = c925e()
    let transport = EmptyThenFound(appearOnCall: 1, info: info)
    var slept: [TimeInterval] = []

    let found = try Apply.waitForDevices(transport: transport, budget: 10) { slept.append($0) }

    #expect(found.count == 1)
    #expect(slept.isEmpty)
}

// Interactive `apply` must not sit for ten seconds when no camera is plugged
// in. Only the launchd path, which knows an attach just happened, waits.
@Test func zeroBudgetChecksOnceAndReturns() throws {
    let (info, _) = c925e()
    let transport = EmptyThenFound(appearOnCall: .max, info: info)
    var slept: [TimeInterval] = []

    let found = try Apply.waitForDevices(transport: transport, budget: 0) { slept.append($0) }

    #expect(found.isEmpty)
    #expect(slept.isEmpty)
    #expect(transport.counter.calls == 1)
}
