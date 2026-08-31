import Testing
@testable import unflicker

@Test func unknownSubcommandFails() {
    #expect(CLI.run(["unflicker", "nonsense"]) == 2)
}

@Test func noSubcommandPrintsUsageAndFails() {
    #expect(CLI.run(["unflicker"]) == 2)
}

@Test func helpFlagPrintsUsageAndSucceeds() {
    #expect(CLI.run(["unflicker", "--help"]) == 0)
    #expect(CLI.run(["unflicker", "-h"]) == 0)
    #expect(CLI.run(["unflicker", "help"]) == 0)
}
