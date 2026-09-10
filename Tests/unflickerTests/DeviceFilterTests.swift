import Testing
@testable import UVCCore
@testable import unflicker

// Absent means every camera. That is the whole reason a typo must not also
// mean nil: `set --device 413c:dOO3` would write to every camera attached.
@Test func noDeviceFlagMeansEveryCamera() throws {
    #expect(try CLI.deviceFilter(["unflicker", "show"]) == nil)
}

@Test func aDeviceIdIsParsed() throws {
    #expect(try CLI.deviceFilter(["unflicker", "show", "--device", "046d:085b"])
            == UVCDeviceID(vendor: 0x046d, product: 0x085b))
}

@Test func anUnparseableDeviceIdIsRejected() {
    // Capital O for zero: the mistake that has to fail loudly.
    #expect(throws: CLIError.self) {
        try CLI.deviceFilter(["unflicker", "set", "power-line-frequency=60Hz", "--device", "413c:dOO3"])
    }
}

@Test func aTrailingDeviceFlagIsRejected() {
    #expect(throws: CLIError.self) { try CLI.deviceFilter(["unflicker", "show", "--device"]) }
}

// A flag read with `contains` is invisible when it is misspelled. This is the
// dangerous direction: the user asked for nothing to happen and got a write.
@Test func aMisspelledDryRunIsRejectedRatherThanRunForReal() {
    #expect(throws: CLIError.self) {
        try CLI.rejectUnknownArguments(["unflicker", "apply", "--dryrun"], command: "apply")
    }
}

@Test func aMisspelledDeviceFlagIsRejectedRatherThanMeaningEveryCamera() {
    #expect(throws: CLIError.self) {
        try CLI.rejectUnknownArguments(["unflicker", "show", "--devise", "413c:d003"], command: "show")
    }
}

@Test func aCommandThatTakesNoFlagsRejectsThem() {
    #expect(throws: CLIError.self) {
        try CLI.rejectUnknownArguments(["unflicker", "install", "--dry-run"], command: "install")
    }
}

@Test func theFlagsEachCommandDocumentsAreAccepted() throws {
    try CLI.rejectUnknownArguments(["unflicker", "apply", "--dry-run", "--from-launchd"], command: "apply")
    try CLI.rejectUnknownArguments(["unflicker", "show", "--device", "046d:085b"], command: "show")
    try CLI.rejectUnknownArguments(["unflicker", "list"], command: "list")
}

// `--device 046d:085b` is a flag and its value. Reading the value as a flag
// would reject every correct invocation.
@Test func aDeviceIdIsNotMistakenForAFlag() throws {
    try CLI.rejectUnknownArguments(["unflicker", "set", "power-line-frequency=50Hz",
                                "--device", "046d:085b"], command: "set")
}

// An unknown command is rejected by `run`'s default branch, which says so
// better than a flag error would.
@Test func anUnknownCommandIsNotCheckedForFlags() throws {
    try CLI.rejectUnknownArguments(["unflicker", "bogus", "--anything"], command: "bogus")
}

// `set a=1 b=2` silently applied only the first. Same shape as the flags: the
// parser looked for what it wanted and ignored the rest.
@Test func aSecondAssignmentIsRejectedRatherThanDropped() {
    #expect(throws: CLIError.self) {
        try CLI.rejectUnknownArguments(["unflicker", "set", "power-line-frequency=50Hz",
                                        "brightness=128"], command: "set")
    }
}

@Test func setStillTakesItsOneAssignment() throws {
    try CLI.rejectUnknownArguments(["unflicker", "set", "power-line-frequency=50Hz"], command: "set")
}

// `set power-line-frequency 50Hz`, with a space for the `=`. Two positionals,
// so it is caught here rather than reaching setControl's usage line.
@Test func anAssignmentSplitOnASpaceIsRejected() {
    #expect(throws: CLIError.self) {
        try CLI.rejectUnknownArguments(["unflicker", "set", "power-line-frequency", "50Hz"],
                                       command: "set")
    }
}

@Test func aStrayWordAfterACommandIsRejected() {
    #expect(throws: CLIError.self) {
        try CLI.rejectUnknownArguments(["unflicker", "apply", "somejunk"], command: "apply")
    }
}

// `help` and `--version` were the two commands `accepted` did not list, and a
// command missing from that table takes any flag and any number of arguments
// in silence.
@Test func theInformationalCommandsAreCheckedLikeAnyOther() {
    #expect(throws: CLIError.self) {
        try CLI.rejectUnknownArguments(["unflicker", "version", "--junk"], command: "version")
    }
    #expect(throws: CLIError.self) {
        try CLI.rejectUnknownArguments(["unflicker", "help", "list"], command: "help")
    }
}

// `accepted` is what makes a flag or a stray argument an error, and a command
// with no row there takes both in silence. The parser cannot tell that from a
// genuinely unknown command, which falls through the same `else`, so the usage
// text is the check: a command nobody can discover is not the way this happens.
@Test func everyCommandTheUsageDocumentsHasARowInTheAcceptedTable() {
    let documented = CLI.usage
        .split(separator: "\n")
        .filter { $0.hasPrefix("  ") }
        .compactMap { $0.split(separator: " ").first.map(String.init) }
        .map(CLI.canonical)

    #expect(documented.count > 1)
    for command in documented {
        #expect(CLI.accepted[command] != nil, "'\(command)' is in usage but not in CLI.accepted")
    }
}

@Test func theFlagSpellingsFoldOntoTheCommandNames() {
    #expect(CLI.canonical("--help") == "help")
    #expect(CLI.canonical("-h") == "help")
    #expect(CLI.canonical("--version") == "version")
    #expect(CLI.canonical("list") == "list")
}

// Both spellings, since --version reaches the table through canonical() and
// the command name reaches it directly.
@Test func versionIsAcceptedInEitherSpellingAndRejectsExtras() {
    #expect(CLI.run(["unflicker", "--version"]) == 0)
    #expect(CLI.run(["unflicker", "version"]) == 0)
    #expect(CLI.run(["unflicker", "--version", "--junk"]) == 2)
}
