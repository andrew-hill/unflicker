# Hardware ledger

Developer notes: what real cameras did when unflicker was run against them.
Every number here was read off a device on macOS 26.6.2 / arm64. Nothing is
inferred from the UVC spec or a datasheet. The table is a record of what has been
measured, not a support list; a camera missing from it is untested, not excluded.

| Camera | VID:PID | Form factor | Loses settings on re-enumerate? |
|---|---|---|---|
| Logitech C925e | `046d:085b` | USB webcam, on a dock | Yes — whole Processing Unit *and* Camera Terminal |
| Dell P3424WEB webcam | `413c:d003` | Inside a monitor, on its USB3.2 hub | Yes — `power-line-frequency` |
| Logitech C922 Pro Stream | `046d:085c` | USB webcam, on a dock | Yes — `power-line-frequency` |

## True of all three

- **`power-line-frequency` is `[1..2]`, default `2` (60 Hz).** No "disabled" (0),
  no "auto" (3), despite the UVC spec defining both. unflicker refuses
  out-of-range values rather than clamping.
- **Processing Unit `bmControls` = `0x175b`**, `bControlSize` 2 — bits D0, D1,
  D3, D4, D6, D8, D9, D10, D12. The same nine controls on all three: no hue, no
  gamma.
- **Nothing survives re-enumeration.** Two vendors, two form factors, and none of
  them is the C920, the only entry in the Linux kernel's `uvc_ids[]` flagged for
  losing controls (`UVC_QUIRK_RESTORE_CTRLS_ON_INIT`), every other quirk in that
  table being about streaming.
- **Same `bmControls` does not mean same ranges.** `white-balance-temperature` is
  `[2800..7500]` step 10 on the Dell, `[2000..6500]` step 1 on the C922.

## Reset triggers

| Trigger | Result |
|---|---|
| Re-enumeration — unplug, undock, display link dropping | **Resets, all three.** What unflicker exists to fix. |
| Monitor soft power cycle, mains still connected | **Resets the Dell.** The hub keeps standby power and the camera re-enumerates anyway. |
| Hub handover — monitor's hub switched to another PC and back | **Resets the Dell.** A two-computer desk hits this several times a day. |
| Login / bootstrap | launchd replays matches for already-attached devices, so the same reapply covers it. |
| Sleep / wake | **No reset on the Dell.** Untested on the dock cameras, where it matters more: a camera that never leaves the bus fires no IOKit match, so unflicker never runs. |
| Stream start — an app opening the camera | **No reset on the Dell**, and writes are accepted mid-stream. Untested elsewhere on macOS, but New Teams on Windows does reset it (see the C925e below), and nothing attach-triggered can fix that. |

Only `power-line-frequency` was moved off its default before the Dell and C922
triggers, so whether either resets its *whole* Processing Unit the way the C925e
does is untested.

## Readiness after attach

A camera appears in the IORegistry before it will answer control transfers, so
`Apply.waitForDevices` retries on a 0.25s-to-2s backoff inside a 10s budget.

Cold from unplugged:

- C922, `IOUSBHostDevice` appearing to VideoControl interface published — the
  interval the budget covers — 0.02s.
- Published to `GET_CUR` answering: 0.02s C922, 0.00s Dell. The C922 is
  bus-powered and the Dell is not; no difference.
- Four agent runs across the two, never a `no camera answered` in the log.

The budget cannot be entered early: an `IOUSBHostDevice` exists only once the
camera's controller has booted and answered enumeration, and launchd matches on
`IOUSBHostDevice`.

C925e: `uvc-util` on a 1s retry loop had it unanswerable for ~20s. Not
reproduced against the binary, untested since.

## Logitech C925e — `046d:085b`

Read with `uvc-util` and a scratchpad IOUSBHost probe. The camera left before the
binary was finished, so nothing else was captured: no `bcdDevice`, no serial, no
defaults or step sizes beyond `power-line-frequency`'s.

- `power-line-frequency`: `GET_CUR` 2, `GET_MIN` 1, `GET_MAX` 2, `GET_RES` 1,
  `GET_DEF` 2, `GET_INFO` 3.
- Processing Unit is **unit id 3 on VideoControl interface 0** — found by walking
  the configuration descriptor. Never hardcode it; it is per-device.
- Camera Terminal `bmControls` = `0x020a2e`.
- Unplugging the dock reset the whole Processing Unit *and* Camera Terminal:
  brightness, white balance, contrast, zoom, pan/tilt, exposure, focus.
- **New Teams on Windows resets `power-line-frequency` when it selects this
  camera** — first-hand, though on Windows rather than macOS and long before the
  binary existed, so not a measurement. The only remedy was opening LogiTune and
  toggling the setting by hand on every call. Reported by others on the C920 and
  C922. This is the stream-start trigger, and an attach-triggered design cannot
  close it.

## Dell P3424WEB webcam — `413c:d003`

Behind the monitor's internal USB3.2 hub. UVC 1.00, `bcdDevice` `0x0821`,
12-hex-character serial. First camera the binary ran against end to end.

| Control | Range | Step | Default |
|---|---|---|---|
| `backlight-compensation` | `[0..1]` | 1 | 0 |
| `brightness` | `[0..255]` | 1 | 128 |
| `contrast` | `[0..255]` | 1 | 128 |
| `gain` | `[0..255]` | 1 | 0 |
| `power-line-frequency` | `[1..2]` | 1 | **2 (60 Hz)** |
| `saturation` | `[0..255]` | 1 | 128 |
| `sharpness` | `[0..255]` | 1 | 128 |
| `white-balance-temperature` | `[2800..7500]` | **10** | 5000 |
| `white-balance-temperature-auto` | boolean | — | on |

- **`GET_MIN` on `white-balance-temperature-auto` stalls** — `0xe0005000`,
  `kUSBHostReturnPipeStalled`, while `GET_CUR` on the same control works. That
  is correct: UVC mandates only `GET_CUR`, `SET_CUR`, `GET_DEF` and `GET_INFO`
  for a boolean, so a range is something that does not exist. Never probe one.
- **`GET_DEF` on `privacy` returns `true`**, which taken literally means a
  factory default of blanked video. It isn't: the camera works after a replug
  with `privacy` off. A "restore everything to defaults" feature that trusted
  `GET_DEF` would blank this camera.
- Camera Terminal, out of scope for v1: `zoom-abs` `[100..200]` def 100;
  `pan-tilt-abs` `[-144000..144000]` both axes step 3600 def 0; `focus-abs`
  `[1..600]` def 1; `auto-focus` bool def on; `exposure-time-abs` `[3..2047]`
  def 156; `auto-exposure-mode` 8-bit bitmap def 8; `auto-exposure-priority`
  reporting neither range nor default; `privacy` bool, off.

Unit ids not captured.

## Logitech C922 Pro Stream — `046d:085c`

Dock. UVC 1.00, `bcdDevice` `0x0016`, 8-hex-character serial, as the Dell has
too, which matters because config sections are keyed on `vendor:product` alone,
so two identical cameras are indistinguishable to unflicker even though the
hardware could tell them apart.

| Control | Range | Step | Default |
|---|---|---|---|
| `backlight-compensation` | `[0..1]` | 1 | 0 |
| `brightness` | `[0..255]` | 1 | 128 |
| `contrast` | `[0..255]` | 1 | 128 |
| `gain` | `[0..255]` | 1 | 0 |
| `power-line-frequency` | `[1..2]` | 1 | **2 (60 Hz)** |
| `saturation` | `[0..255]` | 1 | 128 |
| `sharpness` | `[0..255]` | 1 | 128 |
| `white-balance-temperature` | `[2000..6500]` | 1 | 4000 |
| `white-balance-temperature-auto` | boolean | — | on |

- Camera Terminal, out of scope for v1: `zoom-abs` `[100..500]` def 100;
  `pan-tilt-abs` `[-36000..36000]` both axes step 3600 def 0;
  `exposure-time-abs` `[3..2047]` def 250; `focus-abs` `[0..250]` **step 5** def
  0; `auto-focus` bool def on; `auto-exposure-mode` 8-bit bitmap def 8;
  `auto-exposure-priority` reporting neither range nor default.
- Carries `UVC_QUIRK_INVALID_DEVICE_SOF` in `uvc_ids[]` on master, absent in
  v6.6 — a streaming-timestamp workaround, nothing to do with controls.

## Reported affected elsewhere

Not measured here. These are the citations behind the README's second camera
list.

- **Poly Studio P5** `095d:9296` — Poly Lens Desktop 5.1.0 release notes, Known
  Issues: anti-flicker reverts to 60 Hz on Mac after unplug and replug.
  Vendor-admitted, on macOS, and exactly the failure unflicker exists for.
  https://info.lens.poly.com/lens-dt-rn/2026/05/21/version-5.1.0
- **Dell conferencing monitors** — P3424WEB, P2424HEB, P2724DEB, U3223QZ,
  U3234KB, C2422HE, C2722DE, C3422WE; only `413c:d003` known. One Dell KB covers
  all eight: "If the power frequency is 50 Hz, then select 50 Hz".
  https://www.dell.com/support/kbdoc/en-us/000227355/
- **Dell UltraSharp WB7022** `413c:c015` — Dell KB, "Video Feed Can Flicker Under
  Artificial Light". https://www.dell.com/support/kbdoc/en-us/000189134/
- **Dell WB3023** `413c:c03e` — product manual: "adjust the Anti Flicker
  setting… Toggle between 50Hz and 60Hz."
- **Jabra PanaCast** `2b93:0003` — third-party Q&A, not Jabra: set Line frequency
  to 50 Hz in Jabra Direct. Weakest of the set.
- **Creative Live! Cam family** — Sync `041e:406c`, Chat HD `041e:4088`, Sync HD
  `041e:4095`, Socialize HD 1080 `041e:4087`, Sync 4K `041e:40a4`. Creative KB
  111448 names fourteen models, all fixed by switching "PowerLine Frequency (Anti
  Flicker)". The live page is JS-only, so this is the archived copy.
  http://web.archive.org/web/20170918223531/http://support.creative.com:80/kb/ShowArticle.aspx?sid=111448
- **EMEET SmartCam C960 4K, C960** `328f:0093`, `328f:00e2` — vendor FAQs: 50 Hz
  and 60 Hz settings, switchable only from EMEET's Windows app.
  https://emeet.com/pages/c960-4k-faq
- **Logitech C920** `046d:082d` — the one entry in the Linux kernel's `uvc_ids[]`
  carrying `UVC_QUIRK_RESTORE_CTRLS_ON_INIT`: the driver re-uploads cached
  control values after init because the device "forgets that it is in manual
  mode". Also the camera in the Windows New Teams reports.
- **Logitech C505e and BCC950** — published model-specific udev rules force
  `power_line_frequency` at connect. Source not recorded.
- **Razer Kiyo** — a widely linked writeup, though the rule it publishes matches
  every UVC camera rather than the Kiyo specifically. Source not recorded.
- **Jabra PanaCast 20** `0b0e:3021` —
- **Jabra PanaCast 50, PanaCast 40 VBS** — ids unknown.
- **Poly Studio P15** `095d:9290` —
- **Dell Pro WB5023** `413c:c022` —
- **Plexgear 720p** `0c45:6301` —

Two reports where setting the control did **not** stop the flicker: an Aukey
PC-LM1E (`1bcf:0001`) on 50 Hz mains already reading 1,
https://unix.stackexchange.com/questions/627442/, and an unspecified Aukey 1080p,
https://askubuntu.com/questions/1314624/. Not evidence against the control, but
against 50 Hz as a universal cure.

## Reading a camera

`unflicker show` prints ranges but not defaults or step sizes. For those, and for
the descriptors:

    uvc-util -I 0 --show-control='*'     # every control, with defaults and steps
    ioreg -c IOUSBHostDevice -r -l       # bcdDevice, serial number

Capture them while the camera is in front of you. The C925e section above is what
an entry looks like when you don't.
