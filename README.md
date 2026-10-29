# RayNeoPin

A screen pinned in space for **RayNeo Air 4 Pro** on macOS. Native, menu bar, one USB-C cable.

[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20me%20a%20coffee-fuut4-FFDD00?logo=buymeacoffee&logoColor=black)](https://buymeacoffee.com/fuut4)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/Fuut4/rayneo-pin/main/install.sh | zsh
```

Apple Silicon, macOS 14+, Xcode Command Line Tools (`xcode-select --install`).
Builds from source, installs to `/Applications`, launches. Updates: **Check for Updates…**

On first launch, allow **Screen Recording** and hold still for a second.

## Use

| Keys | |
|---|---|
| ⌃⌥R · double tap | Recenter |
| ⌃⌥I / O / 0 | Zoom in / out / reset |
| ⌃⌥1 / 2 / 3 | Desk · Sofa · Lying down |
| ⌃⌥↑ / ↓ | Screen height |
| ⌃⌥T | Pause tracking |
| ⌃⌥D | Developer overlay |
| ⌘, | Settings |

Taking the glasses off pauses everything. Putting them on resumes and centers where you look.

## Features

- **3DoF at 500 Hz** over USB HID, predicted to photon time.
- **AirPods as a drift reference.** Optional; one guided calibration, saved per pair.
- **Sharp text.** Gamma-correct resampling, bicubic, pixel lock when still.
- **Setups.** Glasses display, 32:9 ultrawide, virtual displays (incl. side screens), mirroring.
- **Rest.** Off-head detection via the proximity sensor: no capture, no rendering.
- **Channels.** Release (`main`) or Developer (`develop`), switchable in the menu.
- **Privacy.** Telemetry is off unless you opt in; every field is listed in Settings › Privacy.

## How it works

IMU over vendor HID → Mahony fusion with rest-based bias refinement → AirPods heading (rate-aligned via Wahba, reference jumps detected) → 1€ filter → Metal, paced by `CAMetalDisplayLink`, zero-copy from ScreenCaptureKit.
Protocol and pipeline: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Troubleshooting

| | |
|---|---|
| Black glasses | Allow RayNeoPin in Privacy & Security › Screen Recording |
| Slow sideways drift | Calibrate Gyro (glasses on a table), or use AirPods |
| Screen swims when turning | FOV: ⌃⌥L / ⌃⌥K |
| AirPods unused | Recenter to bring them back; Connect to This Mac: Automatically |

Anything else: open an issue with a screenshot of the developer overlay.

## Develop

```bash
git clone https://github.com/Fuut4/rayneo-pin.git && cd rayneo-pin && ./build.sh && open RayNeoPin.app
```

No dependencies; `swiftc` only. CI runs logic tests and a text-clarity lab on every push ([TESTING.md](TESTING.md)). Reports from other RayNeo models are welcome: [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE). Not affiliated with RayNeo or TCL.
