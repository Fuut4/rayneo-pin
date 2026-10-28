# RayNeoPin

**3DoF spatial screen pinning for RayNeo Air 4 Pro glasses on macOS.**

RayNeo doesn't ship head tracking for the Air 4 Pro on Mac. The glasses do have an IMU, though, and it speaks plain USB HID. RayNeoPin reads that sensor and captures a Mac display or a single window. It then draws the capture on the glasses as a virtual screen that stays fixed in space while you turn your head.

> 🤖 **Made by Claude.** This project was written by [Claude](https://claude.com/claude-code) (Anthropic's AI model) in Claude Code, at [@Fuut4](https://github.com/Fuut4)'s request. In one session Claude worked out the HID protocol on real hardware, wrote the sensor fusion and renderer, and verified the result on the glasses. Expect rough edges. Issues and pull requests are very welcome.

## Features

- Native Swift menu-bar app. No dependencies, no drivers, one USB-C cable.
- Reads the IMU at ~500 Hz and fuses it with a Mahony-style filter (gyro plus gravity correction).
- Gyro bias calibration at startup, and slow bias tracking while your head is still.
- 15 ms motion prediction to cut perceived lag.
- Source: any non-glasses display, or **any single window** (ScreenCaptureKit).
- Full 3DoF or yaw-only mode, zoom, adjustable FOV, recenter.
- Global hotkeys. They use Carbon, so they need no Accessibility permission.

## Requirements

- Apple Silicon Mac, macOS 14 or later. Tested on macOS 15.7 with a MacBook Pro.
- RayNeo Air 4 Pro (USB `1bbb:af50`). Other RayNeo Air models that use the same protocol may work. Reports are welcome.
- Xcode Command Line Tools (`xcode-select --install`) to build.

## Build and run

```bash
git clone https://github.com/Fuut4/rayneo-pin.git
cd rayneo-pin
./build.sh
open RayNeoPin.app
```

1. Plug in the glasses. They show up as an extended display named *SmartGlasses*.
2. Launch the app. Allow **Screen & System Audio Recording** when macOS asks (System Settings → Privacy & Security). Ad-hoc builds may need this again after a rebuild.
3. Keep your head still for about 1 second while the gyro calibrates. The screen appears centered where you're looking.

Want an *extra* monitor instead of a mirror? Create a virtual display (for example with BetterDisplay) and pick it under **Fuente** (Source) in the menu.

### Hotkeys

| Keys | Action |
|---|---|
| ⌃⌥R | Recenter |
| ⌃⌥T | Pause tracking (screen follows the head) |
| ⌃⌥Y | Yaw-only mode |
| ⌃⌥ `=` / `-` | Zoom in / out |
| ⌃⌥ `]` / `[` | FOV +1° / −1° |
| ⌃⌥Q | Quit |

If the screen "swims" (slides in the same direction you turn) instead of staying put, tune the FOV with ⌃⌥ `]` / `[`. The default is 46° diagonal.

### Debugging

```bash
# Print fused orientation to the terminal, no rendering
./RayNeoPin.app/Contents/MacOS/RayNeoPin --imu-test

# Let screenshots see the glasses window (it's hidden from capture by default)
RAYNEOPIN_DEBUG=1 ./RayNeoPin.app/Contents/MacOS/RayNeoPin

# Dump raw HID reports
swiftc -O tools/probe.swift -o probe && ./probe 3 --enable
```

## How it works

### HID protocol

The glasses expose a vendor HID interface: usage page `0xFF00`, with 64-byte input and output reports. Every frame follows the same layout:

| Direction | Byte 0 | Byte 1 | Byte 2 | Rest |
|---|---|---|---|---|
| Host → glasses | `0x66` | command | value | payload |
| Glasses → host | `0x99` | type | | data |

- Command `0x01` turns the IMU on and `0x02` turns it off. The app sends `0x01` on connect and on wake (notify `0x42`), and sends `0x02` on quit.
- IMU frames have type `0x65`, all values little-endian:
  - accelerometer in m/s² as `float[3]` at offset 4
  - gyro in **deg/s** as `float[3]` at offset 16
  - tick as `uint32` at offset 40, in **100 µs** units
- The device frame is x right, y up, z toward the face.

Protocol knowledge comes from [verncat/RayNeo-Air-3S-Pro-OpenVR](https://github.com/verncat/RayNeo-Air-3S-Pro-OpenVR) (MIT). The units and timing were verified on an Air 4 Pro. Some ports use a `0xAA` magic byte; the Air 4 Pro ignores it.

### Rendering

A borderless black window covers the glasses display; black renders as transparent on the optics. The capture is drawn on a `CALayer` that gets a perspective transform rotating it around the eye by the inverse head rotation. The focal length comes from the glasses' FOV.

## Known limitations / ideas for contributions

- **Yaw drift.** The heading has no magnetometer correction yet, so it slowly drifts and you recenter with ⌃⌥R. The magnetometer values are in the packet at offsets 32, 36 and 52.
- **Single screen.** Multiple pinned screens, or a curved screen, would be nice.
- **Virtual display.** Creating the virtual display in-app (`CGVirtualDisplay`) would remove the need for BetterDisplay.
- **Calibration.** A FOV and IPD calibration wizard. The 46° default is a guess.
- **Side-by-side 3D mode** (3840×1080) is not handled.
- **Packaging.** A signed and notarized release, so users don't have to build it themselves.
- Only tested on one Air 4 Pro. Please report other models.

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE). Not affiliated with RayNeo / TCL.
