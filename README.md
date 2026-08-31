# unflicker

Reapplies UVC webcam settings on macOS every time the camera is plugged in, led
by the 50/60 Hz anti-flicker control that macOS exposes nowhere and that cameras
forget on every reconnect.

## Is this you?

✅ **Yes** — an **external USB webcam** bands or ripples under mains lighting,
and the banding comes back every time you reconnect it.

❌ **No** — it's the **built-in camera on a MacBook**. Those aren't USB and
expose no UVC control, so nothing here can reach them, and neither can any
similar tool.

Most likely if you're on a **50 Hz mains supply** — the UK, Europe, most of Asia,
Africa, Australia, most of South America. Cameras ship set to 60 Hz, so they are
wrong there out of the box and wrong again after every reconnect.

## Why your camera forgets

Webcams have a `power-line-frequency` setting that matches exposure to your
mains supply, and they band when it's wrong. macOS gives you no way to change
it, and cameras reset it on every reconnect. unflicker sets it again, on every
attach.

## Install

```sh
brew install andrew-hill/tap/unflicker
```

It builds from source, so you need the Xcode command line tools
(`xcode-select --install`).

To build it yourself instead:

```sh
git clone https://github.com/andrew-hill/unflicker
cd unflicker
swift build -c release
cp .build/release/unflicker /usr/local/bin/
```

Copy it somewhere permanent, as above. `install` records the path of whichever
binary ran it, so installing out of `.build/release` breaks the agent the moment
you clean or move the checkout. Homebrew's symlink is stable, so a brew install
is not affected.

## Set it up

```sh
unflicker install
```

Writes a config and loads the agent:

```
wrote /Users/you/.config/unflicker/unflicker.conf: power-line-frequency = 50Hz
change it to 60Hz if you are in North America or Japan
installed net.thefrog.unflicker for /usr/local/bin/unflicker
```

Replug the camera. That's the setup.

## Check it worked

```sh
unflicker show
```

It should report `power-line-frequency = 50Hz`. If it doesn't, see
[Troubleshooting](#troubleshooting).

## Commands

| | |
|---|---|
| `unflicker install` | write the config, load the agent |
| `unflicker uninstall` | unload and remove it |
| `unflicker list` | cameras found, with their ids |
| `unflicker show` | current value of every supported control |
| `unflicker set NAME=VALUE` | write the camera now — not saved, lost on replug |
| `unflicker apply --dry-run` | what the agent would change, without touching the device |

# If it's working, you're done

Everything past here is for when it isn't, or for when you want to know why it
works at all.

## Troubleshooting

Every command reads before it writes, so you can check all of this without
guessing. Start with what the camera says about itself:

```sh
unflicker list                        # ids
unflicker show --device 413c:d003     # one camera's values and ranges
```

```
413c:d003  DELL Display 4MP Webcam
  brightness = 128  [0..255]
  power-line-frequency = 50Hz  [1..2]
  white-balance-temperature = 5000  [2800..7500]
```

Only the controls that camera actually offers appear; this one has no `hue` or
`gamma`. The square brackets are its accepted range.

**Is my config right?** `apply --dry-run` reads the config and the camera and
prints what it would change, without writing anything.

```sh
unflicker apply --dry-run
```

**Does this value work on this camera?** `set` writes the camera directly,
bypassing the config, so you can try one before committing to it. Nothing is
saved and the next replug undoes it.

```sh
unflicker set power-line-frequency=60Hz --device 413c:d003
unflicker show --device 413c:d003
```

**Is something else changing my camera?** Set the value, get the camera live in
the app you suspect, then read it back.

```sh
unflicker set power-line-frequency=50Hz
# start the call, so the app has the camera
unflicker show
```

If it reads 60 Hz while the app is using the camera, the app is doing it, not
unflicker, and nothing that runs at attach time can stop it. See
[Limitations](#limitations).

**Did the agent run?** It logs every decision it makes, including deciding to do
nothing.

```sh
/usr/bin/log show --predicate 'subsystem == "unflicker"' --last 1h
```

## What's actually going on

USB webcams band when their exposure isn't quantised to the local mains
frequency. A camera set to 60 Hz on a 50 Hz supply (or the reverse) rolls
horizontal bands under any mains-powered light. `power-line-frequency` is a
standard USB Video Class control present on essentially every USB webcam. It is
not a framerate change: dropping capture to 25 fps does not quantise exposure
and leaves the banding exactly where it was.

macOS exposes it nowhere. No System Settings pane, no `defaults` key, no
AVFoundation API. Linux has `v4l2-ctl`; Windows has the driver property sheet;
macOS users get told to install a third-party app.

And whatever you set does not survive a replug. A reconnect resets the
camera's *entire* processing unit to factory defaults: `power-line-frequency`
back to 60 Hz, along with brightness, white balance, contrast and the rest. The
camera terminal goes too, taking zoom, pan/tilt, exposure and focus. Set it
once and the next reconnect undoes it.

That is the gap unflicker fills. It doesn't set controls better than the tools
listed at the bottom; it makes the setting stick.

## How it works

Linux solves this with a udev rule. macOS has an equivalent mechanism (a
LaunchAgent triggered by `LaunchEvents` → `com.apple.iokit.matching`), but no
published tool uses it for this. That gap is the whole reason the project
exists.

**It never polls.** Nothing runs in the background: no timer, no menu bar item,
no daemon. macOS starts unflicker when a USB device attaches, it checks whether
your camera needs the setting put back, and it quits. The same happens at login,
for anything already plugged in.

The matching rule is deliberately unfiltered. launchd will not match on
`bInterfaceClass`, so there is no way to ask it for "webcams only": the moment
that filter is added it silently matches nothing at all, with no error. unflicker
therefore wakes on any USB attach, enumerates cameras itself, and exits
immediately when there is nothing to do.

It runs `unflicker apply`, which reads each control before writing and skips any
that is already correct, so a repeat run changes nothing.

It talks to the camera by opening `IOUSBHostDevice` on the USB device rather
than the VideoControl interface, because the system's own UVC driver owns that
interface and opening it fails with `kIOReturnInternalError` (`0xe00002c9`).
Opening the device needs no entitlement and leaves video capture working.

macOS would quarantine and Gatekeeper-block a downloaded binary without a
Developer ID and notarisation. Building locally sidesteps signing entirely.

## Configuration

`~/.config/unflicker/unflicker.conf`, or under `$XDG_CONFIG_HOME` if you set it:

```ini
# Applies to every camera unless overridden below.
[default]
power-line-frequency = 50Hz

# Per-camera overrides, keyed by vendor:product.
[046d:085b]
power-line-frequency = 50Hz
brightness = 128
```

Most people will only ever have the first block: mains frequency is a property
of where you live, not of which camera you own. Run `unflicker list` for the ids.

Anything in the table below can go in either block. Values are written the way
you'd say them, not as the raw UVC integers, and a plain number works everywhere:

| Control | Values |
|---|---|
| `power-line-frequency` | `50Hz`, `60Hz` — the spec also defines `disabled` and `auto`, which most cameras refuse |
| `brightness` | a number |
| `contrast` | a number |
| `saturation` | a number |
| `sharpness` | a number |
| `gamma` | a number |
| `gain` | a number |
| `hue` | a number |
| `backlight-compensation` | a number |
| `white-balance-temperature` | a number |
| `white-balance-temperature-auto` | `on`, `off` |

The numeric ranges differ per camera, and a camera need not offer every control.
`unflicker show` prints what yours accepts, with each control's min and max.

Each control may be set once per section. Setting the same one twice in one
block is an error rather than a silent last-one-wins, since there is no way to
tell which was meant.

`install` writes that file with 50 Hz already set, because cameras ship set to
60 Hz. On a 60 Hz supply your camera is already right and you have no banding to
fix, so anyone installing this is almost certainly on 50 Hz. An existing config
is never overwritten.

## Limitations

- Can't touch a built-in MacBook camera — see above.
- **Only fixes mains-frequency banding.** A dimmable LED flickers on its own
  account. Run the dimmer up and down: if the banding tracks it, the lamp is at
  fault and no camera setting helps.
- **Some cameras band anyway**, with the control already reading correctly.
- **Processing Unit controls only** — the eleven listed above. Zoom, pan/tilt,
  exposure and focus live on the Camera Terminal. That resets on replug too, but
  unflicker doesn't restore it yet.
- **Refuses a value your camera won't take** instead of quietly picking a nearby
  one. Most cameras offer 50 Hz and 60 Hz and nothing else, whatever the spec
  allows.
- **Skips controls your camera lacks** and logs them. Not an error.
- **Writes fine while the camera is streaming** — though a camera may refuse, so
  that may not hold everywhere.
- **Can't stop an app that resets the control mid-session.** New Teams on Windows
  forces it back to 60 Hz when it selects the camera — hit here on a C925e, where
  the only fix was reopening LogiTune every time. Also reported on the C920 and
  C922. No attach-triggered tool can help.

## Cameras with this problem

**Assume every USB webcam does this.** The ones below have either been measured
here or reported by others. It is not an exhaustive list, and a camera missing
from it is just a camera nobody has mentioned.

Seen here:

- Logitech C925e (`046d:085b`)
- Logitech C922 Pro Stream (`046d:085c`)
- Dell Display 4MP Webcam, in the P3424WEB monitor (`413c:d003`) — powering the
  monitor off loses the setting, and so does switching its USB hub to another
  computer.

Reported elsewhere, not verified here:

- Poly Studio P5 (`095d:9296`), Studio P15 (`095d:9290`). Poly's own release
  notes list "anti-flicker setting reverts to 60 Hz on Mac after unplug and
  replug" as a known issue.
- Logitech C920 (`046d:082d`), C505e, BCC950
- Dell WB7022 (`413c:c015`), WB3023 (`413c:c03e`), Pro WB5023 (`413c:c022`)
- Dell conferencing monitors with built-in webcams: P2424HEB, P2724DEB,
  U3223QZ, U3234KB, C2422HE, C2722DE, C3422WE
- Jabra PanaCast (`2b93:0003`), PanaCast 20 (`0b0e:3021`), PanaCast 50
- Creative Live! Cam family (`041e`). Creative's own support article names
  fourteen models and points at the same anti-flicker control.
- EMEET SmartCam C960 (`328f:00e2`), C960 4K (`328f:0093`). EMEET's FAQ says the
  setting is switchable only from their Windows app.

Cameras ship set to 60 Hz, and complaints span a lot of makes and models.
Logitech ships an Anti-Flicker toggle for a reason. Measurements for the cameras
seen here are in [docs/hardware.md](docs/hardware.md).

## Other tools

Most people are pointed at Logitech's own software first:
[LogiTune](https://www.logitech.com/software/logitune.html) or G Hub, both of
which have an Anti-Flicker toggle. If you have a Logitech camera and don't mind
it running all the time, that may be all you need.

It is a lot of software for one setting, though: a resident, auto-updating
vendor app that has to keep running to hold a single toggle. And it only reaches
Logitech cameras, so if you use more than one make it can never fix all of them.
It also didn't hold reliably for me, with LogiTune installed and running —
see [Limitations](#limitations).

unflicker takes the opposite approach: there is no service and no daemon. It
registers a command for launchd to run when a device connects, and that command
does its work and exits.

Setting UVC controls directly is well covered, but none of these reapply on
attach:

- [uvc-util](https://github.com/jtfrey/uvc-util) — CLI, MIT, unmaintained, built
  on the deprecated IOUSBLib.
- [uvcc](https://github.com/joelpurra/uvcc) — npm, cross-platform, can export and
  import settings.
- [CameraController](https://github.com/Itaybre/CameraController) — GUI, free,
  actively maintained. Use this one if you want sliders.

Linux has two answers: a udev rule, or
[cameractrls](https://github.com/soyersoyer/cameractrls), which ships a daemon
that reapplies saved presets when a device connects. macOS has the mechanism for
this and, as far as I can find, no tool that uses it.

## Development

```sh
swift build -c release
swift test
```

[docs/design.md](docs/design.md) — what the tool is built out of, and the
constraints behind it.
[docs/manual-testing.md](docs/manual-testing.md) — the checks that need a real
camera, which the unit tests can't cover.
[docs/hardware.md](docs/hardware.md) — measured ranges, defaults and quirks per
camera.

## Licence

MIT.
