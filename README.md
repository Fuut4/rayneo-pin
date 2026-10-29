# RayNeoPin

Head-tracked (3DoF) screen pinning for **RayNeo Air 4 Pro** on macOS: a native menu-bar app over one USB-C cable, with no drivers or dependencies.

[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

## Requirements

- Apple Silicon, macOS 14 or later (tested on 15.7).
- RayNeo Air 4 Pro (`1bbb:af50`). Other RayNeo Air models are untested.
- Xcode Command Line Tools: `xcode-select --install`.
- Optional: AirPods with head tracking (Pro, 3, 4, Max) or Beats Fit Pro.

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/Fuut4/rayneo-pin/main/install.sh | zsh
```

Clones to `~/Library/Application Support/RayNeoPin/src`, builds, installs to `/Applications`, launches. Re-running is a no-op when up to date; `--force` rebuilds.

| | |
|---|---|
| Updates | **Check for Updates…** downloads, builds, installs and relaunches, with progress. |
| Channels | **Release** tracks `main`; **Developer** tracks `develop`. Switch under **Update Channel**. |
| Signing | `build.sh` signs with the first *Apple Development* identity, so Screen Recording access survives updates. Ad-hoc builds lose it on every rebuild. |

**First run:** grant **Screen & System Audio Recording** (the app relaunches itself once granted), hold still for one second, and optionally run **Calibrate Gyro (glasses on a table)…**.

## Display setups

| Setup | macOS displays | Desktop | Refresh |
|---|---|---|---|
| **Glasses Screen** (default) | Mac + glasses | 1920×1080 | 120 Hz |
| **Ultrawide** | Mac + glasses | 3840×1080, glasses in SBS mode | 60 Hz |
| **Virtual Display** | Mac + glasses + virtual | Crisp (1:1 at any zoom), 16:9, 16:10, 21:9, 32:9, 32:10 | 120 Hz |
| **Mirror** | unchanged | any display or window | — |

- The pinned screen is redrawn fixed in space with its own cursor at display rate.
- Virtual Display fences the glasses' own display off from the cursor and moves stray windows out (Accessibility permission). Ultrawide modes are wider than the field of view: turn your head or zoom out.
- **Side screens:** extra 1920×1080 virtual displays left and right of the pinned one.

## Head tracking

| Source | |
|---|---|
| **Glasses + AirPods** (recommended) | Glasses IMU for motion; AirPods heading cancels yaw drift |
| **Glasses Only** | IMU only |
| **AirPods Only** | AirPods attitude, ~25 Hz over Bluetooth, extrapolated to display time |

**AirPods calibration.** Guided once: turn left, then right; look up, then down. Each side fills only as far as both devices agree, so glitches can't fill it. Saved per pair and per earbud; **Recalibrate AirPods** starts over.

**AirPods availability.** If another device holds them, the glasses show *Glasses head tracking only* and tracking continues. They are never taken back automatically. Recentering, putting the glasses on, or **Bring AirPods Back to This Mac** sets them as output and plays a brief chime registered as Now Playing, the signal macOS automatic switching acts on. Requires *Connect to This Mac: Automatically*.

## Controls

| Hotkey | Action |
|---|---|
| ⌃⌥R · double tap | Recenter |
| ⌃⌥T | Pause tracking |
| ⌃⌥Y / P / E | Lock yaw / pitch / roll |
| ⌃⌥I / O / 0 | Zoom in / out / reset |
| ⌃⌥L / K | FOV +1° / −1° |
| ⌃⌥1 / 2 / 3 | Preset: Desk / Sofa / Lying down |
| ⌃⌥F | Smooth Follow |
| ⌃⌥↑ / ↓ | Screen height ±2° |
| ⌃⌥G | Turn-sensitivity calibration (start / finish) |
| ⌃⌥D | Developer overlay |
| ⌘, | Settings |
| ⌃⌥Q | Quit |

## Calibration

| | |
|---|---|
| **Gyro** | Glasses on a table, ~3 s of stillness. The proximity sensor is disabled meanwhile so the IMU keeps streaming. Result persisted; refined at every rest. |
| **Turn sensitivity** | ⌃⌥G, one full turn back to the same point, ⌃⌥G. Rejected if the turn wasn't whole. |
| **FOV** | If the screen slides with your turn, adjust with ⌃⌥L / ⌃⌥K. Default 43° diagonal. |

## Rest

Off-head (proximity sensor: ~1200 off, 65535 worn) or unplugged: capture, rendering and AirPods motion stop; displays stay untouched. Putting the glasses on resumes within a second and centers once the head settles (< 20 °/s for 0.6 s).

## Privacy

Telemetry is **off** until you opt in on first launch: record locally, or record and share. Motion and timing data only, no screen content, keystrokes, window titles or identifiers. Every recorded field, deletion and export are in **Settings › Privacy**. `tools/analyze_telemetry.py` turns a session into an HTML report.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Glasses black, permission notice | Privacy & Security › Screen & System Audio Recording › RayNeoPin |
| Slow sideways drift | Gyro calibration, or Glasses + AirPods |
| Screen swims when turning | FOV (⌃⌥L / ⌃⌥K) or turn-sensitivity calibration |
| AirPods unused | Recenter; check Motion & Fitness access and *Connect to This Mac* |
| Anything else | Issue with a developer-overlay screenshot or an exported telemetry session |

## Technical reference

### Glasses protocol

Vendor HID, usage page `0xFF00`, 64-byte reports. Host → glasses `0x66 cmd value`; glasses → host `0x99 type`. Derived from [verncat/RayNeo-Air-3S-Pro-OpenVR](https://github.com/verncat/RayNeo-Air-3S-Pro-OpenVR); verified on Air 4 Pro.

| Command | Effect |
|---|---|
| `0x01` / `0x02` | IMU on / off |
| `0x06` / `0x07` | 3840×1080 SBS @60 / 2D |
| `0x20` / `0x21` | Panel 60 / 120 Hz |
| `0x38 0` / `0x38 1` | Proximity sensor off / on |
| `0x00` | Device info |

IMU report `0x65`, little-endian. Device frame: x right, y up, z toward the face.

| Offset | Field |
|---|---|
| 4 | Accelerometer, `float[3]`, m/s² |
| 16 | Gyro, `float[3]`, °/s |
| 28 | Temperature, °C |
| 40 | Tick, `u32`, 100 µs |
| 44 | Proximity |

Acks are `0xC8`; byte 8 carries sleep `0x41` / wake `0x42` (not sent by every firmware).

### Pipeline

| Stage | Method |
|---|---|
| Orientation | Mahony complementary filter, gravity gated during acceleration; optional MEKF with bias state |
| Gyro bias | Table calibration, persisted; [VQF](https://github.com/dlaidig/vqf)-style rest refinement (corrections < 0.6 °/s); bias-vs-temperature model |
| AirPods alignment | Clock offset by rate correlation; ear-mount rotation by Wahba (Davenport q-method); per-sample cross-check against the glasses gyro; reference jumps detected by rotation vector |
| Drift correction | Heading offset held to the AirPods at ≤ 0.5 °/s, up to 2 °/s on a trusted fit; held while the AirPods are away |
| Smoothing | 1€ filter, 0.1° soft dead zone |
| Latency | Late latching; prediction to `CAMetalDisplayLink` present time, capped at 3° |
| Rendering | Metal on a dedicated thread; zero-copy IOSurface, dirty-rect uploads; gamma-space bicubic with clamped unsharp; idle frames skipped |

### AirPods handoff

`audioaccessoryd` routes AirPods by Now Playing registration and mic activity ([WWDC23 10233](https://developer.apple.com/videos/play/wwdc2023/10233/)); notification sounds never move them. Control Center's switch and the AACP ownership messages ([LibrePods](https://github.com/librepods-org/librepods)) require private entitlements, so RayNeoPin uses the public signal only, and only on request.

## Development

```bash
git clone https://github.com/Fuut4/rayneo-pin.git && cd rayneo-pin
./build.sh && open RayNeoPin.app
```

| Path | Contents |
|---|---|
| `Sources/IMU.swift` | HID protocol, fusion, bias, wear detection, pose history |
| `Sources/Headphones.swift` | AirPods motion, calibration, handoff, device catalog |
| `Sources/Renderer.swift` | Metal renderer, pose pipeline, developer overlay |
| `Sources/Displays.swift` | Glasses and virtual displays, arrangement, cursor |
| `Sources/Capture.swift` | ScreenCaptureKit capture |
| `Sources/App.swift` | Menu, settings, setups, calibration, updates |
| `Sources/SettingsWindow.swift`, `Overlay.swift` | Settings window, message cards |
| `Sources/Telemetry.swift`, `Privacy.swift` | Telemetry, upload, consent |
| `Sources/RenderLab.swift` | Offscreen text-clarity scoring |
| `tests/main.swift` | Logic tests, run by CI |
| `tools/probe.swift` | Raw HID dump |

| Flag | Output |
|---|---|
| `--imu-test` | Fused orientation and AirPods yaw |
| `--list-headphones` | Paired AirPods, model, head-tracking support |
| `--render-lab [dir]` | Text-clarity scores for every readability option |
| `--settings-snapshot <dir>` | PNGs of every Settings page and card |
| `RAYNEOPIN_DEBUG=1` | Allows screenshots of the glasses window |

CI compiles, runs the logic tests and the render lab on every push; results are published to `refs/lab/results`. Options and lab results: [TESTING.md](TESTING.md). Contributions and reports from other models: [CONTRIBUTING.md](CONTRIBUTING.md).

Open work: magnetometer fusion, a notarized release, support for other RayNeo models.

## Support

[Buy Me a Coffee](https://buymeacoffee.com/fuut4).

## License

[MIT](LICENSE). Not affiliated with RayNeo or TCL.
