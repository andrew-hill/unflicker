# Manual tests

The checks that need a real USB camera. Run them after touching the USB
transport or the launchd path; the unit tests cover everything else.

Per-camera ranges, defaults and quirks are in [hardware.md](hardware.md).

    swift build -c release

## Read controls

    .build/release/unflicker list
    .build/release/unflicker show

- Camera listed with its `vendor:product` id.
- `power-line-frequency` has range `[1..2]`: no `disabled` (0) or `auto` (3),
  whatever the spec says.
- `show` lists *every* control the camera advertises and exits 0. A camera may
  STALL a control it does not really implement; one stall must not hide the
  rest.

## Set and read back

    .build/release/unflicker set power-line-frequency=50Hz
    .build/release/unflicker show

## Video keeps working while the device is open

Open Photo Booth, take a picture, then run `show` with the camera live. Both
keep working: unflicker opens the USB device, not the VideoControl interface,
so it does not evict the system's UVC driver.

## Reapply on attach

    .build/release/unflicker install
    /usr/bin/log stream --predicate 'subsystem == "unflicker"' --style compact

Absolute path: `log` is a zsh builtin that shadows `/usr/bin/log` and fails
while exiting 0.

- **Idle: the log stays silent.** Lines every 10 s mean the agent isn't draining
  the event stream (see `EventStream.drain`). A defect, not a cosmetic one: it
  pokes the camera on a timer.
- **Replug the camera** (or power-cycle the monitor a built-in webcam lives in).
  Expect *one* run reporting the change, however many devices came up with it:
  launchd coalesces a burst of matches into a single invocation.
- **Trigger it again.** Same result: the camera is back at its default every
  time, so every cycle reports the change rather than `already 50Hz`.

## Nothing written when nothing needs it

With the camera attached and already correct, plug in an unrelated USB device.
Matching is unfiltered, so the agent wakes for that too. Expect `already 50Hz`
and `show` unchanged.

## Triggers that are not a replug

Answered for the Dell, open for the dock cameras; results live in
[hardware.md](hardware.md) under Reset triggers. With `install` done and the log
streaming, trigger one of the cases below and read off:

| Log | Meaning |
|---|---|
| `power-line-frequency 60Hz -> 50Hz` | Camera reset, unflicker caught it. Working. |
| `power-line-frequency already 50Hz` | launchd fired, camera had not reset. Harmless. |
| Nothing, `show` reads 50 Hz | launchd did not fire, nothing lost. Harmless. |
| **Nothing, `show` reads 60 Hz** | **A gap** — the camera resets on a trigger the agent never hears. |

- `show` alone cannot tell those rows apart: 50 Hz afterwards means either
  "never reset" or "reset and fixed". Record which in `hardware.md`.
- `drained N event(s)` measures how much of the bus launchd handed over, not
  whether anything reset. Ten events is a whole monitor hub; `install` produces
  ten with nothing reset at all, and a sleep that disturbed nothing produced
  one. Only the `->` means a value changed.

Triggers to run:

- **Hub handover.** Switch the monitor's USB hub to another computer, wait ten
  seconds, switch back. Time how long the camera takes to answer:
  `Apply.waitForDevices` allows 10 s on the launchd path, the one number in the
  readiness backoff picked rather than measured.
- **Sleep and wake.** Sleep the Mac 30 s, wake it. Repeat with only the display
  asleep. Watch for the bottom row: a camera that never leaves the bus fires no
  IOKit match, so if something reset it anyway nothing reapplies. An
  attach-triggered design cannot close that; it goes in the README's
  Limitations.

## Uninstall

    .build/release/unflicker uninstall

`launchctl print gui/$UID/net.thefrog.unflicker` must report the service not
found, and the plist must be gone from `~/Library/LaunchAgents`.

## Plist contents

    /usr/libexec/PlistBuddy -c Print ~/Library/LaunchAgents/net.thefrog.unflicker.plist

`ProgramArguments[0]` must be the absolute path of the binary that ran
`install`, and still the symlink if that is what it was. Homebrew's
`/opt/homebrew/bin/unflicker` points into a Cellar directory that
`brew upgrade` deletes.
