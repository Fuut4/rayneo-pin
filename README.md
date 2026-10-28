# RayNeoPin

Head-tracked (3DoF) screen pinning for **RayNeo Air 4 Pro** glasses on macOS.

[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20me%20a%20coffee-fuut4-FFDD00?logo=buymeacoffee&logoColor=black)](https://buymeacoffee.com/fuut4)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

RayNeo ships no head tracking for the Air 4 Pro on Mac. RayNeoPin reads the glasses' IMU over USB and keeps the glasses' screen fixed in space while you turn your head. It's a native menu-bar app with no drivers or dependencies, and it runs over a single USB-C cable.

Written by [Claude](https://claude.com/claude-code) (Anthropic) in Claude Code, for [@Fuut4](https://github.com/Fuut4).

## Requirements

- Apple Silicon Mac, macOS 14 or later (tested on 15.7).
- RayNeo Air 4 Pro (USB `1bbb:af50`). Other RayNeo Air models may work; please report results.
- Xcode Command Line Tools (`xcode-select --install`).
- Optional: AirPods with head tracking, as a second sensor.

## Install and update

```bash
curl -fsSL https://raw.githubusercontent.com/Fuut4/rayneo-pin/main/install.sh | zsh
```

This builds the app into `/Applications/RayNeoPin.app` and launches it. To update, use **Check for Updates…** in the menu or run the command again. It does nothing if you're already up to date; pass `--force` to rebuild anyway.

**First run**

1. Allow **Screen & System Audio Recording** for RayNeoPin. The app opens the settings pane and relaunches itself once access is granted.
2. Keep your head still for one second while the gyro calibrates.
3. Optional: run **Calibrate Gyro (glasses on a table)…** once. The glasses can be off your head; see [Calibration](#calibration).

The permission is tied to the code signature. `build.sh` signs with your first *Apple Development* certificate (a free Apple ID certificate from Xcode works), so the permission survives updates. Ad-hoc builds need it granted again after every update.

## Display setups

Choose a setup under **Source**.

| Setup | Displays in macOS | Desktop | Refresh |
|---|---|---|---|
| **Glasses Screen** (default) | Mac + glasses | 1920×1080 (16:9) | 120 Hz |
| **Glasses Screen Ultrawide** | Mac + glasses | 3840×1080 (32:9), using the glasses' 3D mode | 60 Hz |
| **Virtual Display** | Mac + glasses + virtual | 16:9 following the zoom, 16:10, 21:9, 32:9 or 32:10 | 120 Hz |
| **Mirror** a display or window | unchanged | that display or window | — |

- **Glasses Screen:** you work on the glasses' own desktop, placed above the Mac's screen in the display arrangement. RayNeoPin captures it and redraws it fixed in space. The hardware cursor is hidden while it's over the glasses; the pinned image shows the cursor instead.
- **Ultrawide:** switches the glasses to side-by-side mode, so macOS sees one 3840×1080 display. It is rendered once per eye, as a screen twice as wide as your field of view. The glasses only offer 32:9 here.
- **Virtual Display:** a separate virtual monitor; the glasses' own display is kept off-limits to the cursor. Set its size under **Resolution**:
  - *Crisp* (default): desktop pixels map 1:1 to glasses pixels at any zoom.
  - 16:9, 16:10, or ultrawide 21:9 / 32:9 / 32:10 (e.g. 3840×1200), all at 120 Hz. An ultrawide screen is wider than your field of view: turn your head, or zoom out to fit it.
  - *Manual*: pick the mode in **System Settings › Displays › RayNeoPin Display**, where every mode is listed.

  Picking a resolution switches to this setup.

## Head tracking

Choose under **Head Tracking Source**.

| Source | Use |
|---|---|
| **Glasses + AirPods** (recommended) | The glasses' IMU (500 Hz, wired) for motion, and the AirPods' heading to cancel yaw drift |
| **Glasses Only** | No AirPods |
| **AirPods Only** | The AirPods' attitude only. Higher latency (~25 Hz over Bluetooth), extrapolated to the display time |

**AirPods** lists your paired headphones with their model and head-tracking support. Head tracking works on AirPods Pro (all), AirPods 3 and 4, AirPods Max and Beats Fit Pro. Picking one connects it and makes it the sound output, because CoreMotion follows the current output.

The AirPods calibrate automatically. The glasses show a progress bar; turn your head left and right and nod until it fills, which takes about 3 s of movement. A tick marks the start and a chime the end. The result is saved per pair; **Recalibrate AirPods** starts over.

## Controls

| Hotkey | Action |
|---|---|
| ⌃⌥R | Recenter |
| ⌃⌥T | Pause tracking (screen follows the head) |
| ⌃⌥Y / ⌃⌥P / ⌃⌥E | Lock yaw / pitch / roll (that axis follows the head) |
| ⌃⌥I / ⌃⌥O / ⌃⌥0 | Zoom in / out / reset |
| ⌃⌥L / ⌃⌥K | FOV +1° / −1° |
| ⌃⌥D | Developer mode: live sensor and pipeline data in the glasses |
| ⌃⌥Q | Quit |

The menu also has:

- **Steady Image:** ignores movements under 0.1°, such as heartbeat and breathing.
- **Auto Drift Correction:** slowly recenters toward your average gaze. Off by default.
- **Sharpness**, **Glasses at 120 Hz**, and **Also Show Developer Data on the Mac**.

## Calibration

**Gyro (glasses on a table).** The glasses turn their display off when not worn. RayNeoPin disables the proximity sensor for the duration, so the IMU keeps streaming, then restores it.

1. Choose **Calibrate Gyro (glasses on a table)…**. You hear a tick and a progress window appears on the Mac.
2. Put the glasses down and don't touch them. It needs about 3 s of stillness and gives up after 90 s.
3. A chime means done; a low tone means it failed and the previous calibration is kept.

The bias is saved and refined automatically whenever the glasses are at rest.

**FOV.** If the screen slides in the direction you turn instead of staying put, adjust with ⌃⌥L / ⌃⌥K. The default is 43° diagonal.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Glasses show a permission message | Enable RayNeoPin in System Settings › Privacy & Security › Screen & System Audio Recording |
| Screen drifts sideways over time | Run the table calibration, or use Glasses + AirPods |
| Screen swims when turning | Adjust the FOV (⌃⌥L / ⌃⌥K) |
| AirPods unused | Check the menu (*Head Tracking Source*); allow Motion & Fitness; make them the sound output under **AirPods** |
| Anything else | Turn on developer mode (⌃⌥D) and include its data in an issue |

## How it works

### Glasses protocol

The glasses use a vendor HID interface (usage page `0xFF00`) with 64-byte reports. Host→glasses frames start `0x66 cmd value`; glasses→host frames start `0x99 type`.

| Command | Effect |
|---|---|
| `0x01` / `0x02` | IMU on / off |
| `0x06` / `0x07` | 3D side-by-side (3840×1080 @60) / 2D |
| `0x20` / `0x21` | Panel 60 / 120 Hz |
| `0x38 0` / `0x38 1` | Proximity sensor off / on |
| `0x00` | Device info |

IMU frames have type `0x65`, little-endian:

| Offset | Field |
|---|---|
| 4 | accelerometer, `float[3]`, m/s² |
| 16 | gyro, `float[3]`, °/s |
| 28 | temperature, °C |
| 40 | tick, `uint32`, 100 µs |
| 44 | proximity |

Sleep and wake arrive as ack frames (`0xC8`) with `0x41` / `0x42` at byte 8. The device frame is x right, y up, z toward the face. The protocol comes from [verncat/RayNeo-Air-3S-Pro-OpenVR](https://github.com/verncat/RayNeo-Air-3S-Pro-OpenVR), and every value above was verified on an Air 4 Pro.

### Sensor fusion

| Stage | Method |
|---|---|
| Orientation | Mahony complementary filter: gyro integration, gravity correction for pitch/roll |
| Gyro bias | Startup and table calibration, the value saved across launches, and rest-based refinement after [VQF](https://github.com/dlaidig/vqf) (gyro within 2 °/s of its 0.5 s low-pass, accelerometer within 0.5 m/s², ≥1.5 s). Unlike VQF, only corrections under 0.6 °/s are accepted, so slow head turns are not absorbed. |
| Latency | Late latching (pose read after the drawable is acquired). Look-ahead is 10 ms + 0.45 × frame time, plus 7 ms for the bottom row (panel scan-out), as tuned in [XRLinuxDriver](https://github.com/wheaney/XRLinuxDriver) for RayNeo. |
| Micro-movements | 0.1° soft dead zone and motion-adaptive smoothing (cf. [OpenTrack Accela](https://github.com/opentrack/opentrack), [AirAnchor](https://github.com/jief123/AirAnchor)) |
| AirPods ↔ glasses | Clock offset from rotation-speed correlation. Quaternion convention checked against `rotationRate`. Ear-mount rotation solved from paired angular velocities (Wahba's problem, Davenport q-method), plus a world-frame alignment. Headings are compared at each sample's own timestamp against a 5 s glasses pose history. Bud swaps are detected as jumps. |

### Rendering

A borderless window covers the glasses' display (black is transparent on the optics). Metal renders on its own thread, synced to the panel's vsync, with two drawables. Each ScreenCaptureKit frame is copied into a mipmapped sRGB texture; the source buffer is retained until the GPU finishes, which prevents tearing. The texture is drawn as a quad 1 m in front of the anchor, with an unsharp mask. Our own windows are excluded from the capture.

## Development

```bash
git clone https://github.com/Fuut4/rayneo-pin.git && cd rayneo-pin
./build.sh && open RayNeoPin.app
```

| Path | Contents |
|---|---|
| `Sources/IMU.swift` | HID protocol, fusion, bias, pose history |
| `Sources/Headphones.swift` | AirPods motion, calibration, device picker |
| `Sources/Renderer.swift` | Metal renderer, pose pipeline, developer overlay |
| `Sources/Displays.swift` | Glasses display, virtual display, arrangement, cursor |
| `Sources/Capture.swift` | ScreenCaptureKit capture |
| `Sources/App.swift` | Menu, settings, setups, calibration flow |
| `tools/probe.swift` | Raw HID dump |

Command-line flags:

| Flag | Output |
|---|---|
| `--imu-test` | Fused orientation and AirPods yaw in the terminal |
| `--list-headphones` | Paired AirPods, their model and head-tracking support |
| `RAYNEOPIN_DEBUG=1` | Lets screenshots capture the glasses window |

Open work:

- Magnetometer fusion for absolute heading.
- Multiple pinned screens.
- A signed, notarized release.
- Reports from other RayNeo models.

See [CONTRIBUTING.md](CONTRIBUTING.md).

## Support

Claude writes the code; Fuut4 pays for the tokens. [Buy Fuut4 a coffee](https://buymeacoffee.com/fuut4) so Claude keeps its job.

## License

[MIT](LICENSE). Not affiliated with RayNeo or TCL.
