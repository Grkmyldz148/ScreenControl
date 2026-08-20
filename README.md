# ScreenControl

[![CI](https://github.com/Grkmyldz148/ScreenControl/actions/workflows/ci.yml/badge.svg)](https://github.com/Grkmyldz148/ScreenControl/actions/workflows/ci.yml)

A menu bar app that controls **external monitor brightness** on Apple Silicon Macs,
keeps it in sync with the built-in display, and lets you drive both from the
**F1/F2 brightness keys**.

Unlike a plain DDC brightness slider, it can take the external monitor all the way
to **true black** — because DDC brightness `0` does not turn the backlight off.

> Built and verified on a MacBook Air M2 (macOS 26.5) with a ViewSonic VP2768a
> over USB-C. Any Apple Silicon Mac and any monitor that answers DDC/CI should work.

---

## Features

- **Per-display brightness sliders** in a menu bar popover — built-in and external.
- **Linked mode** — `F1`/`F2` change both displays together, using a calibration
  curve so they actually *look* equal.
- **External-only control** — `⌃F1`/`⌃F2` moves the monitor without touching the laptop panel.
- **True black** — below DDC zero, brightness continues via gamma scaling, and at
  the very bottom the backlight is switched off over DDC. USB-C power delivery is
  unaffected (measured).
- **Per-monitor calibration** — mark "these two look equal to me right now" and the
  app interpolates between your anchor points.
- **On-screen HUD** that names the display being changed.
- **Hot-plug and sleep aware** — rediscovers displays, re-applies dimming after wake.
- **Never leaves you in the dark** — three independent recovery paths (see below).
- **Automatic updates** — signed with Sparkle, checked daily, installed in place.
- `--diagnose` mode for troubleshooting.

---

## Requirements

- Apple Silicon Mac (M1 / M2 / M3 / M4). Intel Macs use a different I2C path and are
  not supported.
- macOS 14 or later.
- A monitor connected **directly** (HDMI / DisplayPort / USB-C). DisplayLink docks,
  Sidecar, and AirPlay displays do not carry an I2C channel.
- Xcode command line tools — only if you build from source.

---

## Install

**[⬇︎ Download the latest release](https://github.com/Grkmyldz148/ScreenControl/releases/latest)**
— grab the `.dmg`, open it, drag **ScreenControl** into **Applications**.

The build is signed with a Developer ID and notarized by Apple, so it opens with a
normal double-click — no right-click trick, no Gatekeeper warning.

On first launch the app asks for **Accessibility** permission
(System Settings → Privacy & Security → Accessibility). Without it the sliders still
work, but `F1`/`F2` cannot be intercepted.

### Updates

The app checks for updates once a day through [Sparkle](https://sparkle-project.org)
and installs them in place. Each update is verified twice before it is applied: an
EdDSA signature over the archive, and the app's Developer ID code signature. You can
trigger a check yourself from the gear menu, or turn the automatic check off there.

### Build from source

```bash
git clone https://github.com/Grkmyldz148/ScreenControl.git
cd ScreenControl
./build.sh install
open -a ScreenControl
```

`build.sh` compiles a release binary, assembles the `.app` bundle, embeds and signs
Sparkle, and copies the result to `/Applications`.

It signs with your **Developer ID** certificate if you have one, falling back to
ad-hoc. This matters: macOS ties the Accessibility grant to the code signature, and
an ad-hoc signature changes on every build — so you would have to re-grant the
permission each time. Override with `CODESIGN_IDENTITY="..." ./build.sh install`.

---

## Usage

| Input | Effect |
|---|---|
| `F1` / `F2` | Both displays together when linked; built-in only when not |
| `⌃F1` / `⌃F2` | External monitor only |
| `⇧⌥F1` / `⇧⌥F2` | Quarter steps (matching macOS behaviour) |
| Menu bar icon | Per-display sliders, link toggle, calibration |

Step size is `1/16`, the same as macOS.

The gear menu holds: launch at login, key interception, **dim below zero**,
**backlight off at zero**, HUD, menu bar percentage, and rescan.

When the slider drops under 25% a 🌙 appears on that row (gamma dimming is active);
at exactly zero the row shows a `backlight off` badge.

### Making the two displays match

A MacBook Air M2 panel peaks around 500 nits, a typical IPS monitor around 350, and
their slider→nits curves differ. `50% = 50%` does not look equal.

So instead of guessing, the app learns from you:

1. Turn linked mode on.
2. Set the built-in display wherever you like.
3. Drag the external slider until the two look equal to your eye.
4. Press **"These match now"**.

Repeat at a dark, a middle, and a bright level. The panel draws the resulting curve
live; the dashed line is the linear mapping you started from.

---

## How it works

The two displays are driven through completely different mechanisms, and the whole
app is built around that split.

### 1. External monitor — DDC/CI

Monitors accept commands over the **I2C** line inside the video cable. The protocol
is **DDC/CI**, the command set is **MCCS**: brightness is VCP `0x10`, contrast
`0x12`, power `0xD6`.

On Intel Macs you reached that line through `IOFramebuffer` + `IOI2CInterface`.
**That path does not exist on Apple Silicon.** Display work is handled by a separate
coprocessor (DCP — Display Co-Processor) and the I2C line sits behind `IOAVService`,
an IOKit SPI with no public header:

```
IOAVServiceCreateWithService(allocator, ioService) -> IOAVServiceRef
IOAVServiceWriteI2C(service, chipAddress, offset, buffer, size)
IOAVServiceReadI2C (service, chipAddress, offset, buffer, size)
```

`Sources/ScreenControl/Private/IOAVService.swift` binds these symbols directly with
`@_silgen_name`. Packet layout:

```
write:  [0x51] [0x84] [0x03] [VCP] [valueHi] [valueLo] [checksum]
         ^src   ^len|0x80  ^"Set VCP Feature"

read:   [0x51] [0x82] [0x01] [VCP] [checksum]   →   12-byte reply
         reply[6..7] = max value, reply[8..9] = current value

checksum = 0x6E ^ 0x51 ^ (every other byte)
```

DDC is slow and the bus is shared, so all traffic goes through one serial queue with
a mandatory 50 ms gap between commands. Slider drags are coalesced — only the latest
value is sent — otherwise the bus jams and the monitor stops answering.

### 2. Built-in display — DisplayServices

The internal panel has no DDC, and public AppKit cannot *write* brightness. The app
`dlopen`s `DisplayServices.framework` and uses:

```
DisplayServicesGetBrightness(displayID, &float)      // 0.0 ... 1.0
DisplayServicesSetBrightness(displayID, float)
DisplayServicesBrightnessChanged(displayID, double)  // keeps system state in sync
```

### 3. Matching an IOAVService to a CGDirectDisplayID

There is no direct link between the two. The trick is to match IORegistry paths:

```
AppleCLCD2          .../dispext0@70000000/AppleCLCD2
                       └─ DisplayAttributes → ProductAttributes
                          (LegacyManufacturerID, ProductID, SerialNumber)
                          ⇕ matches ⇕
                          CGDisplayVendorNumber / ModelNumber / SerialNumber

DCPAVServiceProxy   .../dispext0:dcpav-service-epic:0/DCPAVServiceProxy
                       └─ Location = "External"
```

The shared `dispext0` token joins them. After matching, the app performs a probe read
before showing a slider — that is what filters out virtual displays.

### 4. Brightness keys

`F1`/`F2` do not produce ordinary `keyDown` events. They arrive as `NSSystemDefined`
(type 14), subtype 8 — the channel every hardware media key uses. The only way to see
them is a **CGEventTap**, which requires Accessibility permission.

`MediaKeyTap.swift` decodes the event, swallows it, and the app applies its own logic.
Because the event is swallowed, macOS does not draw its own HUD — so the app draws one.

The tap also re-enables itself on `tapDisabledByTimeout`, which the system will
trigger if a callback ever runs long.

### 5. Why DDC zero is not black — three layers of dimming

**DDC brightness `0` does not turn the backlight off, it only sets it to minimum.**
The built-in MacBook panel *does* fully switch off at zero; external monitors have no
such command. So the slider walks through three layers:

```
slider  100% ─────────────────── 25% ────────── 0%
         │   DDC 0x10: 100 → 0    │  DDC at min  │
         │   gamma: untouched      │  gamma: 1→0  │
         │                         │              └─ VCP 0xD6=4: backlight off
```

- **Upper region (100%–25%)** — ordinary DDC brightness.
- **Lower region (25%–0%)** — DDC is already at the bottom, so the display's gamma
  ramp is scaled with `CGSetDisplayTransferByTable` and the image fades to black.
  The reference table is captured **only when dimming starts** — otherwise the app
  would rescale its own scaled table and darken exponentially.
- **Exactly zero** — `VCP 0xD6 = 4` (DPMS Off) actually turns the backlight off.

**Why `0xD6 = 4` and never `5`.** Value `4` leaves the monitor's main board powered:
it keeps answering DDC and keeps delivering USB-C power. This was measured — with the
backlight off, the power source held steady at `20V / 4500mA / 90W`, the active
display count never changed, and windows did not rearrange. Value `5` ("hard off")
cuts the power rails and may need a physical button press to recover. The code never
sends it.

### 6. Not getting stuck in the dark

The worst bug a screen-dimming app can have is leaving the screen dark when it dies.
Three independent guards, each verified:

| Situation | What happens |
|---|---|
| Normal quit | Gamma and backlight restored. The backlight write is **synchronous** — an async write would not reach the wire before the process exits. |
| Crash / `SIGKILL` | CoreGraphics reverts the gamma table on process death, by itself. |
| Launch after a crash | Backlight is turned on unconditionally, and a saved brightness of `0` is raised to the **lowest visible level** instead of being restored. |

That last one is deliberate: otherwise, crashing while blacked out with launch-at-login
enabled would greet you with a pitch-black monitor and no visible explanation.

---

## Troubleshooting

```bash
/Applications/ScreenControl.app/Contents/MacOS/ScreenControl --diagnose
```

Prints the displays found, whether DDC answers, which VCP codes are supported, the
current gamma scaling, the power mode (`1` on, `4` backlight off), and permission state.

**`DDC/CI: no response`:**

- DDC/CI may be disabled in the monitor's own OSD menu (on ViewSonic:
  *Setup Menu → DDC/CI*).
- DisplayLink docks and some cheap USB-C hubs do not pass the I2C line through —
  connect the monitor directly.
- Sidecar and AirPlay displays have no DDC at all.

**Brightness keys do nothing:** check Accessibility permission, and note that
rebuilding with an ad-hoc signature invalidates the existing grant.

**Verbose tracing:**

```bash
defaults write app.pushbrands.screencontrol traceEnabled -bool true
# then: log show --predicate 'process == "ScreenControl"' --last 2m --info --debug
```

---

## Project layout

```
Sources/ScreenControl/
├── Private/IOAVService.swift       IOKit SPI declarations
├── Private/DisplayServices.swift   built-in display brightness
├── DDC/DDC.swift                   DDC/CI protocol, retries, write coalescing
├── Display/DisplayRegistry.swift   display discovery, IOAVService matching
├── Display/SoftwareDimmer.swift    gamma dimming below DDC zero
├── Core/BrightnessCurve.swift      calibration curve
├── Core/BrightnessController.swift sync, hot-plug, persistence
├── Core/Settings.swift             UserDefaults + launch at login
├── Input/MediaKeyTap.swift         F1/F2 interception
├── Update/UpdateController.swift   Sparkle automatic updates
├── UI/ControlPanelView.swift       menu bar panel
├── UI/BrightnessHUD.swift          on-screen indicator
├── AppDelegate.swift               status item, popover
└── Diagnostics.swift               --diagnose
```

**Note:** the source comments are in Turkish; everything else — the user interface,
the identifiers, this README — is in English. The UI strings are plain literals
rather than a `.strings` catalogue, so PRs adding localisation are welcome.

---

## Releasing

Only relevant if you maintain a fork.

```bash
./release.sh 1.1.0 --dry-run   # build + notarize + package, publish nothing
./release.sh 1.1.0             # …and publish to GitHub
```

`release.sh` builds and signs the app, submits it to Apple's notary service, staples
the ticket, packages a `.dmg` and a `.zip`, regenerates `appcast.xml`, creates the
GitHub release with both assets, and pushes the updated appcast. Release notes come
from `Notes/<version>.md` when that file exists.

The ZIP is what Sparkle downloads; the DMG is for humans. `appcast.xml` on `main` is
the update feed — installed copies only see a new version once it is pushed, which is
why publishing the release and pushing the appcast happen in that order.

It needs, one time:

```bash
# Apple notarization credentials
xcrun notarytool store-credentials "ScreenControl" \
  --apple-id "<apple-id>" --team-id "<team-id>" --password "<app-specific-password>"

# Sparkle update-signing key (private key lands in your login keychain)
.build/artifacts/sparkle/Sparkle/bin/generate_keys
```

If you fork this, generate **your own** EdDSA key and put its public half in
`build.sh` (`PUBLIC_ED_KEY`), and point `FEED_URL` at your own repository. Otherwise
your builds will refuse every update you publish.

---

## Caveats

- **Uses private APIs.** `IOAVService` and `DisplayServices` are not documented
  interfaces and may change in any macOS update. This also means the app cannot be
  shipped on the App Store — the same reason MonitorControl, Lunar and BetterDisplay
  are all distributed outside it.
- Gamma dimming shows up in screenshots and screen recordings, because it changes the
  display's output ramp rather than drawing a window on top.
- Only tested against one monitor model so far. DDC implementations vary wildly; if
  yours misbehaves, `--diagnose` output is the place to start.

## Credits

- [MonitorControl](https://github.com/MonitorControl/MonitorControl) — the mature
  open-source app in this space.
- [m1ddc](https://github.com/waydabber/m1ddc) — reference for the Apple Silicon
  `IOAVService` DDC path.

## License

MIT — see [LICENSE](LICENSE).
