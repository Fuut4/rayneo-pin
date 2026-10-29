# RayNeoPin

Head-tracked (3DoF) screen pinning for **RayNeo Air 4 Pro** glasses on macOS.

[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20me%20a%20coffee-fuut4-FFDD00?logo=buymeacoffee&logoColor=black)](https://buymeacoffee.com/fuut4)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

RayNeo ships no head tracking for the Air 4 Pro on Mac. RayNeoPin reads the glasses' IMU over USB and keeps the glasses' screen fixed in space while you turn your head. It's a native menu-bar app with no drivers or dependencies, and it runs over a single USB-C cable.

## Requirements

- Apple Silicon Mac, macOS 14 or later (tested on 15.7).
- RayNeo Air 4 Pro (USB `1bbb:af50`). Other RayNeo Air models may work; please report results.
- Xcode Command Line Tools (`xcode-select --install`).
- Optional: AirPods with head tracking, as a second sensor.

## Install and update

```bash
curl -fsSL https://raw.githubusercontent.com/Fuut4/rayneo-pin/main/install.sh | zsh
```

This builds the app into `/Applications/RayNeoPin.app` and launches it. To update, use **Check for Updates…** in the menu: it shows each step (download, build, install) and restarts into the new version. Running the command again works too; it does nothing if you're already up to date, and `--force` rebuilds anyway.

**First run**

1. Allow **Screen & System Audio Recording** for RayNeoPin. The app opens the settings pane and relaunches itself once access is granted.
2. Keep your head still for one second while the gyro calibrates.
3. Optional: run **Calibrate Gyro (glasses on a table)…** once. The glasses can be off your head; see [Calibration](#calibration).
4. Choose whether to record telemetry. It's off unless you say yes; see [Privacy](#privacy).

The permission is tied to the code signature. `build.sh` signs with your first *Apple Development* certificate (a free Apple ID certificate from Xcode works), so the permission survives updates. Ad-hoc builds need it granted again after every update.

## Menu and Settings

The menu bar menu keeps the everyday actions: Recenter, Presets, Zoom, Display, Head Tracking, and **Settings…** (⌘,). Each item shows its hotkey on the right. Everything else is in the Settings window:

| Page | Contents |
|---|---|
| General | Live status, quick actions, open at login, developer mode |
| Display | Setup, resolution, side screens, zoom, FOV, curved screen, warmth and brightness |
| Text Clarity | Sharpening style and strength, sampling, pixel lock |
| Head Tracking | Sensor source, AirPods and their calibration progress |
| Anchoring | Lock axes, Smooth Follow, recentering, double tap, screen height |
| Accuracy | Sensor fusion, temperature compensation, calibrations, experimental drift references |
| Performance | Smoothing, prediction, frame pacing, idle frame skipping |
| Shortcuts | Every hotkey |
| Privacy | Telemetry choice, recordings, and exactly what is recorded |

## Display setups

Choose a setup under **Display**.

| Setup | Displays in macOS | Desktop | Refresh |
|---|---|---|---|
| **Glasses Screen** (default) | Mac + glasses | 1920×1080 (16:9) | 120 Hz |
| **Glasses Screen Ultrawide** | Mac + glasses | 3840×1080 (32:9), using the glasses' 3D mode | 60 Hz |
| **Virtual Display** | Mac + glasses + virtual | 16:9 following the zoom, 16:10, 21:9, 32:9 or 32:10 | 120 Hz |
| **Mirror** a display or window | unchanged | that display or window | — |

- **Glasses Screen:** you work on the glasses' own desktop, placed above the Mac's screen in the display arrangement. RayNeoPin captures it and redraws it fixed in space. The hardware cursor is hidden while it's over the glasses. RayNeoPin draws its own cursor (current shape, at display rate) on the pinned screen in every setup.
- **Ultrawide:** switches the glasses to side-by-side mode, so macOS sees one 3840×1080 display. It is rendered once per eye, as a screen twice as wide as your field of view. The glasses only offer 32:9 here.
- **Virtual Display:** a separate virtual monitor. The glasses' own display is kept off-limits to the cursor, and any window macOS puts there is moved to the virtual monitor; this needs Accessibility permission. Set its size under **Resolution**:
  - *Crisp* (default): desktop pixels map 1:1 to glasses pixels at any zoom.
  - 16:9, 16:10, or ultrawide 21:9 / 32:9 / 32:10 (e.g. 3840×1200), all at 120 Hz. An ultrawide screen is wider than your field of view: turn your head, or zoom out to fit it.
  - *Manual*: pick the mode in **System Settings › Displays › RayNeoPin Display**, where every mode is listed.

  Picking a resolution switches to this setup.

## Head tracking

Choose under **Head Tracking**.

| Source | Use |
|---|---|
| **Glasses + AirPods** (recommended) | The glasses' IMU (500 Hz, wired) for motion, and the AirPods' heading to cancel yaw drift |
| **Glasses Only** | No AirPods |
| **AirPods Only** | The AirPods' attitude only. Higher latency (~25 Hz over Bluetooth), extrapolated to the display time |

**AirPods** lists your paired headphones with their model and head-tracking support. Head tracking works on AirPods Pro (all), AirPods 3 and 4, AirPods Max and Beats Fit Pro. Picking one connects it and makes it the sound output, because CoreMotion follows the current output.

The AirPods calibrate with a short guided movement, shown in the glasses on a bar that fills outward from the center:

1. Turn your head to the left, then to the right.
2. Look up, then down.

Each side only fills as far as the glasses and the AirPods agree you turned, so a glitch or a bud adjusting in your ear can't fill it. Each finished side plays a sound: left and right come from that ear, up is higher, down is lower. A chime marks the end. The result is saved per pair and per earbud; **Recalibrate AirPods** starts over.

## Controls

| Hotkey | Action |
|---|---|
| ⌃⌥R | Recenter |
| ⌃⌥T | Pause tracking (screen follows the head) |
| ⌃⌥Y / ⌃⌥P / ⌃⌥E | Lock yaw / pitch / roll (that axis follows the head) |
| ⌃⌥I / ⌃⌥O / ⌃⌥0 | Zoom in / out / reset |
| ⌃⌥L / ⌃⌥K | FOV +1° / −1° |
| ⌃⌥1 / ⌃⌥2 / ⌃⌥3 | Preset: Desk (fixed in space) / Sofa (follows you, kept level) / Lying Down |
| ⌃⌥F | Smooth Follow on/off |
| ⌃⌥↑ / ⌃⌥↓ | Raise / lower the screen |
| ⌃⌥G | Start / finish the full-turn sensitivity calibration |
| ⌃⌥D | Developer mode: live sensor and pipeline data in the glasses |
| ⌃⌥Q | Quit |
| Double tap on the glasses | Recenter |

## Calibration

**Gyro (glasses on a table).** The glasses turn their display off when not worn. RayNeoPin disables the proximity sensor for the duration, so the IMU keeps streaming, then restores it.

1. Choose **Calibrate Gyro (glasses on a table)…**. You hear a tick and a progress window appears on the Mac.
2. Put the glasses down and don't touch them. It needs about 3 s of stillness and gives up after 90 s.
3. A chime means done; a low tone means it failed and the previous calibration is kept.

The bias is saved and refined automatically whenever the glasses are at rest.

**Turn sensitivity (⌃⌥G).** Look at something, press ⌃⌥G, turn around once, look at it again and press ⌃⌥G. It refuses if the turn wasn't whole.

**FOV.** If the screen slides in the direction you turn instead of staying put, adjust with ⌃⌥L / ⌃⌥K. The default is 43° diagonal.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Glasses show a permission message | Enable RayNeoPin in System Settings › Privacy & Security › Screen & System Audio Recording |
| Screen drifts sideways over time | Run the table calibration, or use Glasses + AirPods |
| Screen swims when turning | Adjust the FOV (⌃⌥L / ⌃⌥K) |
| AirPods unused | The glasses say why (motion access, sound output, no head tracking). Check **Head Tracking**, allow Motion & Fitness, and make them the sound output under **AirPods** |
| Anything else | Turn on developer mode (⌃⌥D) and include its data in an issue. With telemetry on, **Export Session** (Settings › Privacy) zips the recording for the issue |

## Privacy

RayNeoPin can record telemetry to find and fix drift and tracking glitches. **It's off by default.** The first launch asks once, with three choices: record and share, record on this Mac only, or don't record. You can change it, or delete every recording, in **Settings › Privacy**, which also lists every recorded column.

- Recorded: glasses and AirPods motion samples, frame timings, calibration progress, events such as recenters, the app and macOS versions, the Mac model, display resolutions, and this app's settings.
- Never recorded: screen contents, window titles, app names, anything you type, file names, your name or account, AirPods names or Bluetooth addresses, display names, location.
- Shared sessions get a random ID per session and go to the project's database with a key that can only add rows. The servers see your IP address as with any web request; it isn't stored with the data.

`tools/analyze_telemetry.py <session folder or zip>` summarizes a recording and writes an HTML report with charts.

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
| Orientation | Mahony complementary filter: gyro integration, gravity correction for pitch/roll, ignored while accelerating. An optional Kalman filter keeps the gyro bias in its state. |
| Temperature | Bias vs. temperature learned from every rest period, corrected as the glasses warm up |
| Gyro bias | Startup and table calibration, the value saved across launches, and rest-based refinement after [VQF](https://github.com/dlaidig/vqf) (gyro within 2 °/s of its 0.5 s low-pass, accelerometer within 0.5 m/s², ≥1.5 s). Unlike VQF, only corrections under 0.6 °/s are accepted, so slow head turns are not absorbed. |
| Latency | Late latching (pose read after the drawable is acquired). Look-ahead is 10 ms + 0.45 × frame time, plus 7 ms for the bottom row (panel scan-out), as tuned in [XRLinuxDriver](https://github.com/wheaney/XRLinuxDriver) for RayNeo. |
| Micro-movements | 1€ filter, 0.1° soft dead zone and motion-adaptive smoothing (cf. [OpenTrack Accela](https://github.com/opentrack/opentrack), [AirAnchor](https://github.com/jief123/AirAnchor)) |
| AirPods ↔ glasses | Clock offset from rotation-speed correlation. Quaternion convention checked against `rotationRate`. Ear-mount rotation solved from paired angular velocities (Wahba's problem, Davenport q-method), plus a world-frame alignment. Headings are compared at each sample's own timestamp against a 5 s glasses pose history. Every sample is cross-checked against the glasses' gyro at the same instant. AirPods turning while the head doesn't (adjusting them, reconnecting, a bud swap) are ignored, and the glasses take over until the two agree again. A persistent disagreement is treated as a reseat, and the ear-mount rotation is relearned. The AirPods heading correction is capped at 0.5 °/s, so it can never make the screen jump. |

### Rendering

A borderless window covers the glasses' display (black is transparent on the optics). Metal renders on its own thread, paced by `CAMetalDisplayLink`, so prediction targets the moment the frame reaches the panel. ScreenCaptureKit frames are used straight from their IOSurface when possible, and otherwise only the changed regions are copied. Text is resampled in gamma space (as macOS draws it) with a bicubic filter and a clamped unsharp mask, which removes the halo that linear-light resizing caused. Frames are skipped while nothing changes. Our own windows are excluded from the capture.

`RayNeoPin --render-lab` renders real text through this pipeline offscreen and scores it against native text; CI runs it on every push. See [TESTING.md](TESTING.md) for the results and every option.

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
| `Sources/Overlay.swift` | The SwiftUI message card used in the glasses and on the Mac |
| `Sources/SettingsWindow.swift` | Settings window |
| `Sources/Telemetry.swift`, `Sources/Privacy.swift` | Telemetry recording, upload and consent |
| `Sources/RenderLab.swift` | Offscreen text-clarity scoring |
| `tests/main.swift` | Logic tests (fusion, filters, AirPods calibration), run by CI |
| `tools/analyze_telemetry.py` | Telemetry report |
| `Sources/Displays.swift` | Glasses display, virtual display, arrangement, cursor |
| `Sources/Capture.swift` | ScreenCaptureKit capture |
| `Sources/App.swift` | Menu, settings storage, setups, calibration and update flow |
| `tools/probe.swift` | Raw HID dump |

Command-line flags:

| Flag | Output |
|---|---|
| `--imu-test` | Fused orientation and AirPods yaw in the terminal |
| `--list-headphones` | Paired AirPods, their model and head-tracking support |
| `--render-lab [dir]` | Text-clarity scores and crops for every readability option |
| `--settings-snapshot <dir>` | PNGs of every Settings page and message card |
| `RAYNEOPIN_DEBUG=1` | Lets screenshots capture the glasses window |

Open work:

- Magnetometer fusion for absolute heading.
- A signed, notarized release.
- Reports from other RayNeo models.

See [CONTRIBUTING.md](CONTRIBUTING.md).

## Support

If RayNeoPin is useful to you, you can [buy Fuut4 a coffee](https://buymeacoffee.com/fuut4).

## License

[MIT](LICENSE). Not affiliated with RayNeo or TCL. Built with [Claude Code](https://claude.com/claude-code).
