import Foundation
import Testing
@testable import unflicker

// Layouts follow the USB 2.0 configuration/interface descriptors and the UVC
// 1.1 processing unit (table 3-8). wTotalLength is computed unless a test
// claims otherwise on purpose.

private func configuration(claiming claimed: Int? = nil, _ descriptors: [[UInt8]]) -> [UInt8] {
    let body = descriptors.flatMap { $0 }
    let total = claimed ?? body.count + 9
    return [9, 0x02, UInt8(total & 0xff), UInt8(total >> 8), 1, 1, 0, 0x80, 50] + body
}

private func interface(number: UInt8, class klass: UInt8 = 14, subclass: UInt8 = 1) -> [UInt8] {
    [9, 0x04, number, 0, 0, klass, subclass, 0, 0]
}

private func processingUnit(id: UInt8, controlSize: UInt8, controls: [UInt8]) -> [UInt8] {
    let d: [UInt8] = [0, 0x24, 0x05, id, 1, 0, 0, controlSize] + controls + [0]
    return [UInt8(d.count)] + d.dropFirst()
}

private func dellFixture() throws -> [UInt8] {
    let url = try #require(Bundle.module.url(forResource: "dell-413c-d003-config",
                                             withExtension: "bin",
                                             subdirectory: "Fixtures"))
    return [UInt8](try Data(contentsOf: url))
}

// MARK: - The real descriptor

@Test func dellDescriptorParsesToUnitThreeOnInterfaceZero() throws {
    let unit = try #require(ConfigurationDescriptor.processingUnit(try dellFixture()))
    #expect(unit == ConfigurationDescriptor.ProcessingUnit(id: 3, interface: 0,
                                                           controls: 0x0000175B))
}

@Test func dellControlBitsDecodeToTheNineControls() throws {
    let unit = try #require(ConfigurationDescriptor.processingUnit(try dellFixture()))
    let names = UVCControl.all
        .filter { unit.controls & (1 << UInt32($0.bit)) != 0 }
        .map(\.name)
        .sorted()
    #expect(names == ["backlight-compensation", "brightness", "contrast", "gain",
                      "power-line-frequency", "saturation", "sharpness",
                      "white-balance-temperature", "white-balance-temperature-auto"])
}

// MARK: - Malformed descriptors

// A device that reports bLength 0 must not hang the walk.
@Test func zeroBLengthStopsTheWalk() {
    let bytes = configuration([interface(number: 0),
                               [0, 0x00, 0, 0],
                               processingUnit(id: 3, controlSize: 2, controls: [0x5B, 0x17])])
    #expect(ConfigurationDescriptor.processingUnit(bytes) == nil)
}

@Test func bLengthRunningPastTotalLengthStopsTheWalk() {
    let bytes = configuration([interface(number: 0),
                               [200, 0x24, 0x05, 3, 1, 0, 0, 2, 0x5B, 0x17, 0]])
    #expect(ConfigurationDescriptor.processingUnit(bytes) == nil)
}

// wTotalLength beyond the buffer must clamp to the bytes actually supplied,
// not read past them. What is inside the buffer still parses.
@Test func totalLengthBeyondTheBufferIsClamped() throws {
    let bytes = configuration(claiming: 500,
                              [interface(number: 0),
                               processingUnit(id: 3, controlSize: 2, controls: [0x5B, 0x17])])
    let unit = try #require(ConfigurationDescriptor.processingUnit(bytes))
    #expect(unit.controls == 0x175B)
}

// bLength bounds the read; devices get bControlSize wrong. bLength 9 leaves
// room for one bmControls byte no matter what bControlSize claims.
@Test func truncatedProcessingUnitReadsOnlyWithinBLength() throws {
    let bytes = configuration([interface(number: 0),
                               [9, 0x24, 0x05, 3, 1, 0, 0, 4, 0x5B]])
    let unit = try #require(ConfigurationDescriptor.processingUnit(bytes))
    #expect(unit.controls == 0x5B)
}

@Test func zeroControlSizeYieldsNoControls() throws {
    let bytes = configuration([interface(number: 0),
                               processingUnit(id: 3, controlSize: 0, controls: [])])
    let unit = try #require(ConfigurationDescriptor.processingUnit(bytes))
    #expect(unit.controls == 0)
}

@Test func processingUnitBeforeAnyInterfaceIsIgnored() {
    let bytes = configuration([processingUnit(id: 3, controlSize: 2, controls: [0x5B, 0x17])])
    #expect(ConfigurationDescriptor.processingUnit(bytes) == nil)
}

@Test func processingUnitUnderNonVideoControlInterfaceIsIgnored() {
    // VideoStreaming (subclass 2), then a wholly different class: the walk
    // keys on bInterfaceClass 14 with bInterfaceSubClass 1 and nothing else.
    for (klass, subclass) in [(UInt8(14), UInt8(2)), (UInt8(3), UInt8(1))] {
        let bytes = configuration([interface(number: 1, class: klass, subclass: subclass),
                                   processingUnit(id: 3, controlSize: 2, controls: [0x5B, 0x17])])
        #expect(ConfigurationDescriptor.processingUnit(bytes) == nil)
    }
}

@Test func emptyAndOneByteBuffersReturnNil() {
    #expect(ConfigurationDescriptor.processingUnit([]) == nil)
    #expect(ConfigurationDescriptor.processingUnit([0x09]) == nil)
}
