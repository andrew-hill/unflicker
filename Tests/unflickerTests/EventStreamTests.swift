import Foundation
import Testing
@testable import UVCCore

// A fixed origin rather than DispatchTime.now(), so the arithmetic is the only
// thing under test and nothing here waits.
private let start = DispatchTime(uptimeNanoseconds: 1_000_000_000)

@Test func aQuietBusEndsTheDrainOneIdleWindowIn() {
    let schedule = DrainSchedule(start: start, idle: 2, cap: 30)

    #expect(schedule.first == start + 2.0)
}

// `drain` takes both windows from its caller, so nothing stops an idle window
// longer than the cap being asked for. The cap bounds the whole wait, first arm
// included.
@Test func anIdleWindowLongerThanTheCapStillArmsAtTheCap() {
    let schedule = DrainSchedule(start: start, idle: 45, cap: 30)

    #expect(schedule.first == start + 30.0)
}

@Test func everyEventPushesTheDeadlineOutByAnotherIdleWindow() {
    var schedule = DrainSchedule(start: start, idle: 2, cap: 30)

    #expect(schedule.rearm(after: start + 1.0).deadline == start + 3.0)
    #expect(schedule.rearm(after: start + 5.0).deadline == start + 7.0)
}

// A device re-enumerating faster than the idle window rearms the timer every
// time. Without the cap this process stays resident.
@Test func eventsArrivingFasterThanTheIdleWindowStillStopAtTheCap() {
    var schedule = DrainSchedule(start: start, idle: 2, cap: 30)

    let deadlines = stride(from: 1.0, through: 60.0, by: 1.0)
        .map { schedule.rearm(after: start + $0).deadline }

    #expect(deadlines.allSatisfy { $0 <= start + 30.0 })
    #expect(deadlines.last == start + 30.0)
}

// The log line is the only way to tell a drain cut short from a bus that went
// quiet.
@Test func theCapIsAnnouncedOnceHoweverManyEventsFollowIt() {
    var schedule = DrainSchedule(start: start, idle: 2, cap: 30)

    let announced = stride(from: 1.0, through: 60.0, by: 1.0)
        .filter { schedule.rearm(after: start + $0).announce }

    #expect(announced == [29.0])
}
