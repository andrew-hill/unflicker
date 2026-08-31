# Design

Why unflicker is built the way it is, and what the hardware forced. Updated when
the design changes, not kept as a record of any one release.

## Scope

Exists for one control: `power-line-frequency`, the 50/60 Hz anti-flicker
setting. macOS exposes it through no API, no System Settings pane and no
`defaults` key, and cameras forget it on every re-enumeration. Everything else
is secondary.

The problem is persistence, not control setting. uvc-util, uvcc and
CameraController all set controls well; none reapply on attach.

In scope:

- **UVC Processing Unit controls**, from a config file.
- **Reapply on attach and at login.** No other trigger.
- **Terminal as the setup surface**: `list`, `show`, `set`, `install`.

Out of scope:

- **The Camera Terminal** (zoom, pan/tilt, exposure, focus). Own value
  encodings, resets on replug too, not restored yet.
- **Built-in MacBook cameras.** Apple Silicon internals hang off the image
  signal processor, are not USB, and expose no UVC interface.
- **A camera control GUI.** CameraController does that, and is free.
- **Video post-processing deflicker.** Different problem, similar vocabulary.

## Constraints

Measured on hardware; per-camera numbers are in [hardware.md](hardware.md).

- **Controls do not survive re-enumeration.** External and in-monitor cameras
  both, so not a vendor quirk. A C925e resets its entire Processing Unit and
  Camera Terminal. Broader than unplugging: a camera in a monitor re-enumerates
  whenever the display link drops.
- **launchd will not match on `bInterfaceClass`.** Any filter, integer or
  string, matches nothing and reports nothing; `launchctl print` still shows the
  descriptor watching. `IOServiceGetMatchingServices` matches the same property
  fine, so it is launchd's matcher. Hence `IOProviderClass` unfiltered, and no
  "any webcam" descriptor.
- **`LaunchEvents` jobs must drain the XPC event stream.** Undrained events
  count as undelivered and launchd respawns every 10 s. So:
  `xpc_set_event_stream_handler(3)` on `com.apple.iokit.matching`, drain, exit.
- **Never poll.** Attach- and login-triggered, no timer, no resident process.
  The respawn loop above is a defect for exactly that reason.
- **The system's UVC driver owns `IOUSBHostInterface`.** Opening it fails with
  `kIOReturnInternalError` (`0xe00002c9`). unflicker opens `IOUSBHostDevice` on
  the parent: no entitlement needed, video capture keeps working. Init options
  deliberately empty, because `DeviceCapture` and `DeviceSeize` evict the
  camera's other drivers.

## Architecture

- One Swift binary, SwiftPM, no third-party dependencies, system frameworks
  only.
- IOUSBHost, not the deprecated IOUSBLib. Both work; the choice is longevity,
  not necessity.

| Component | Responsibility |
|---|---|
| `UVCTransport` | Protocol at the USB boundary: enumerate, `GET_*`, `SET_CUR` |
| `IOUSBHostTransport` | The real implementation. The only untestable code |
| `UVCControl` | Control catalogue: names, value maps, ranges, which are boolean |
| `Config` | Parse the config; resolve which controls apply to a device |
| `Apply` | Per-control decisions, readiness backoff |
| `EventStream` | Consume the launchd IOKit event stream |
| `AgentInstaller` | Write and bootstrap the LaunchAgent |
| `CLI` | Subcommand dispatch, human-readable output |

`UVCTransport` is the test boundary:

- Above it, everything runs against a fake with no hardware attached: config
  parsing, value mapping, apply decisions, the generated plist.
- Below it, enumeration, real transfers and whether launchd can open a USB
  device at all need hardware, so they live in
  [manual-testing.md](manual-testing.md).

**Boolean controls are answered without a transfer.** UVC mandates only
`GET_CUR`, `SET_CUR`, `GET_DEF` and `GET_INFO` for them, and a device is
entitled to STALL `GET_MIN`; one does, with `kUSBHostReturnPipeStalled`
(`0xe0005000`). The catalogue flags booleans and the transport reports `0...1`
directly, so one stalling control cannot hide every control after it.

## Trigger and lifecycle

- `install` writes and bootstraps
  `~/Library/LaunchAgents/net.thefrog.unflicker.plist`; `uninstall` boots it out
  and removes it. Both idempotent, as is reinstalling over an existing agent.
- Matching dictionary: `IOProviderClass = IOUSBHostDevice`,
  `IOMatchLaunchStream = true`, no property filter.
- The agent runs `unflicker apply`: drain, enumerate, exit. Unfiltered matching
  means it wakes on any USB attach and exits quietly when no camera is there.
- launchd replays matches at bootstrap, which is why reapply-at-login works.
- **Idempotent rather than debounced**, because repeat runs are expected. Reads
  each control before writing and skips any already correct, so a redundant run
  costs one `GET_CUR`. A dock attach enumerates several devices at once; launchd
  coalesces the burst into one invocation.
- **Readiness.** A device is not answerable the instant it appears in the
  IORegistry. On the launchd path `apply` retries with exponential backoff from
  250 ms, doubling, capped at 2 s per interval, abandoned after 10 s total. An
  interactive `apply` checks once, so it does not stall for ten seconds when
  nothing is plugged in.

## Behaviour on error

A background agent must never be noisy or fail loudly.

| Situation | Behaviour |
|---|---|
| No config file | Exit 0, silently |
| Control unsupported by this camera | Log, skip, continue |
| Value outside the device's range | Warn and skip — never clamp |
| Unknown control name | Hard error in `set`, warn and skip in `apply` |
| Device vanishes mid-apply | Exit 0. That is an unplug |
| USB open fails | Log the raw IOKit code, then stop |

- Never clamp: it would substitute a value the user did not ask for.
- `set` errors on an unknown name because the user just typed it; `apply` only
  warns, because a config may be shared across machines with different cameras.
- A control set twice in one section is an error, not last-one-wins.

Logging is `os_log` under subsystem `unflicker`: no file to rotate, and no log
viewer in the tool.

## Distribution

- **Build from source.** macOS would quarantine and Gatekeeper-block a
  downloaded binary without a Developer ID and notarisation; `swift build -c
  release` sidesteps signing entirely.
- **A sandboxed Mac App Store build is a possible later stage**, so the core
  stays easy to lift into an app bundle: the helper would ship inside it and
  register via `SMAppService` rather than dropping a plist, and would need
  `com.apple.security.device.usb`.
