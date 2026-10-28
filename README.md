# RayNeoPin

**3DoF spatial screen pinning for RayNeo Air 4 Pro glasses on macOS.**

[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20me%20a%20coffee-fuut4-FFDD00?logo=buymeacoffee&logoColor=black)](https://buymeacoffee.com/fuut4)

RayNeo doesn't ship head tracking for the Air 4 Pro on Mac. The glasses do have an IMU, though, and it speaks plain USB HID. RayNeoPin reads that sensor and gives you an extra monitor that stays fixed in space while you turn your head. You end up with two screens: your Mac's, and a pinned one in the glasses.

> 🤖 **Made by Claude.** This project was written by [Claude](https://claude.com/claude-code) (Anthropic's AI model) in Claude Code, at [@Fuut4](https://github.com/Fuut4)'s request. In one session Claude worked out the HID protocol on real hardware, wrote the sensor fusion and renderer, and verified the result on the glasses. Expect rough edges. Issues and pull requests are very welcome.

## Features

- Native Swift menu-bar app. No dependencies, no drivers, one USB-C cable.
- **Extra virtual monitor** (*RayNeoPin Display*, 1080p, 1080p HiDPI, or 1440p, at 120 Hz) pinned in space. The glasses' own display is fenced off, so the cursor never gets lost there.
- You can also mirror an existing display, or pin **a single window**, instead.
- **120 Hz**: the app switches the glasses' panel to 120 Hz and renders with Metal on the glasses' vsync, with no tearing.
- Mipmapped sRGB sampling keeps text crisp and avoids moiré when the screen is scaled.
- The IMU is read at ~500 Hz and fused with a Mahony-style filter. Motion prediction and late-latched poses cut lag, and motion-adaptive smoothing keeps text still when your head is.
- **Drift control:**
  - the gyro bias is saved between launches;
  - a precise *Calibrate Gyro* runs with the glasses on a table;
  - continuous bias tracking (x-io Fusion style);
  - optional slow auto drift correction toward where you look.
- **AirPods head tracking:** works with AirPods Pro (all), AirPods 3 & 4, AirPods Max and Beats Fit Pro. Under **Head Tracking Source** you choose:
  - *Glasses Only*;
  - *AirPods Only*;
  - *Glasses + AirPods*: the AirPods' heading keeps the glasses' heading from drifting.
- **Switch between AirPods:** pick any paired pair under **AirPods**. The app shows each pair's model and whether it supports head tracking, then connects it and makes it your sound output, because that's what macOS head tracking follows. The axis mapping is learned from your own head movements, so no per-model tables are needed.
- **Steady image:** micro-movements under 0.1° (heartbeat, breathing) are ignored, without the image ever jumping.
- **Crisp resolution:** the virtual monitor changes resolution with the zoom, so one desktop pixel is one glasses pixel and text stays sharp at any size. There's also an adjustable sharpening filter.
- **Per-axis locks:** lock yaw, pitch and roll independently. A locked axis follows your head; the rest stays pinned.
- **Developer mode** (⌃⌥D): live data inside the glasses, and optionally on the Mac. It shows:
  - raw gyro, accelerometer, bias and rest state;
  - AirPods rate, bursts, Bluetooth delay and calibration;
  - every stage of the pose pipeline;
  - display and capture info.
- Smooth zoom, adjustable FOV, recenter.
- Global hotkeys. They use Carbon, so they need no Accessibility permission.

## Requirements

- Apple Silicon Mac, macOS 14 or later. Tested on macOS 15.7 with a MacBook Pro.
- RayNeo Air 4 Pro (USB `1bbb:af50`). Other RayNeo Air models that use the same protocol may work. Reports are welcome.
- Xcode Command Line Tools (`xcode-select --install`) to build.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/Fuut4/rayneo-pin/main/install.sh | zsh
```

The installer clones the source to `~/Library/Application Support/RayNeoPin/src`, builds it, installs `RayNeoPin.app` to `/Applications`, and launches it.

**To update:** choose **Check for Updates…** in the menu-bar icon, or run the same command again. Either way it pulls, rebuilds, reinstalls, and relaunches. It does nothing if you're already up to date; pass `--force` to rebuild anyway.

1. Plug in the glasses. They show up as an extended display named *SmartGlasses*.
2. Launch the app. Allow **Screen & System Audio Recording** for RayNeoPin (System Settings → Privacy & Security). The app opens that pane for you and starts once the permission is on. If it stays black, quit and reopen it.

   > **Keeping the permission across updates:** macOS ties the permission to the code signature. `build.sh` signs with your first *Apple Development* certificate if you have one, and then the permission survives updates. Free Apple ID certificates from Xcode work. Without a certificate the build is ad-hoc signed, and you'll need to re-enable the permission after each update. To pick a specific identity, set `SIGN_ID="…"`.
3. Keep your head still for about 1 second while the gyro calibrates. The screen appears centered where you're looking.
4. For the least drift, put the glasses on a table and choose **Calibrate Gyro (glasses on a table)…** once. The result is saved.
5. Optional: wear your AirPods and allow motion access when macOS asks. Turn your head left and right a couple of times so the app learns how the AirPods line up with the glasses. **Head Tracking Source** then shows *AirPods: active*. To use different AirPods, pick them under **AirPods**.

By default the pinned screen is a new virtual monitor, placed above your Mac's screen in the display arrangement. Move windows onto it as you would with any monitor. To mirror an existing display or pin one window instead, use **Source** in the menu.

### Hotkeys

| Keys | Action |
|---|---|
| ⌃⌥R | Recenter |
| ⌃⌥T | Pause tracking (screen follows the head) |
| ⌃⌥Y / ⌃⌥P / ⌃⌥E | Lock yaw / pitch / roll |
| ⌃⌥I / ⌃⌥O | Zoom in / out |
| ⌃⌥0 | Reset zoom |
| ⌃⌥L / ⌃⌥K | FOV +1° / −1° |
| ⌃⌥Q | Quit |

The hotkeys use letter keys, so they work on any keyboard layout.

If the screen "swims" (slides in the same direction you turn) instead of staying put, tune the FOV with ⌃⌥L / ⌃⌥K. The default is 46° diagonal.

### Build from source (for development)

```bash
git clone https://github.com/Fuut4/rayneo-pin.git
cd rayneo-pin
./build.sh && open RayNeoPin.app
```

### Debugging

```bash
# Print fused orientation to the terminal, no rendering
./RayNeoPin.app/Contents/MacOS/RayNeoPin --imu-test

# Let screenshots see the glasses window (it's hidden from capture by default)
RAYNEOPIN_DEBUG=1 ./RayNeoPin.app/Contents/MacOS/RayNeoPin

# Paired AirPods, their model and head tracking support (* = current sound output)
./RayNeoPin.app/Contents/MacOS/RayNeoPin --list-headphones

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
- Command `0x21` switches the panel to 120 Hz, and `0x20` back to 60 Hz. After `0x21` the display starts advertising 1920×1080 @120 modes, and the app selects one.
- IMU frames have type `0x65`, all values little-endian:
  - accelerometer in m/s² as `float[3]` at offset 4
  - gyro in **deg/s** as `float[3]` at offset 16
  - tick as `uint32` at offset 40, in **100 µs** units
- The device frame is x right, y up, z toward the face.

Protocol knowledge comes from [verncat/RayNeo-Air-3S-Pro-OpenVR](https://github.com/verncat/RayNeo-Air-3S-Pro-OpenVR) (MIT). The units and timing were verified on an Air 4 Pro. Some ports use a `0xAA` magic byte; the Air 4 Pro ignores it.

### Sensor fusion and accuracy

| Problem | What RayNeoPin does | Based on |
|---|---|---|
| Gyro bias | Startup calibration, a precise on-table calibration, and the bias saved between launches. Rest detection compares the gyro with its own low-pass instead of with zero (VQF). On a head, only small corrections (< 0.6 °/s) are accepted, so slow head turns are never absorbed as bias. | [dlaidig/vqf](https://github.com/dlaidig/vqf), [x-io Fusion](https://github.com/xioTechnologies/Fusion) |
| Pitch/roll | Mahony complementary filter toward gravity | Mahony et al. |
| Motion-to-photon latency | Late latching: wait for a drawable, then read the pose. Look-ahead is 10 ms + 0.45 × frame time; the bottom row gets +7 ms more, because the panel scans out top to bottom. | [wheaney/XRLinuxDriver](https://github.com/wheaney/XRLinuxDriver) RayNeo values |
| FOV | 43° diagonal default | XRLinuxDriver RayNeo |
| Micro-movements (heartbeat) | Soft 0.1° dead zone that never jumps, and motion-adaptive smoothing | [OpenTrack Accela](https://github.com/opentrack/opentrack), AirAnchor |
| AirPods sit tilted in the ears | Full 3-D rotation between the AirPods' and the glasses' body frames, solved from paired angular velocities (Wahba's problem, Davenport q-method) | — |
| Bluetooth latency and bursts (~25 Hz, bursts of 2–4, ~30 ms) | Sensor timestamps instead of arrival times. The clock offset is found by correlating rotation speeds, which works whatever the axes. Headings are compared at the instant each sample was measured, against a 5 s pose history of the glasses. | — |
| CMAttitude quaternion convention | Detected by comparing quaternion deltas with the AirPods' own gyro | — |
| Bud swap / reseating | Detected as jumps; the world alignment is redone, and the app falls back to the glasses meanwhile | — |

The AirPods calibration (ear tilt, convention, latency) is saved per pair, so the next session starts calibrated.

### Rendering

A borderless black window covers the glasses display; black renders as transparent on the optics. A `CAMetalLayer` with display sync and two drawables is driven by a display link on its own thread, at 120 Hz.

Each new ScreenCaptureKit frame is copied into a mipmapped sRGB texture. The source pixel buffer is retained until the GPU finishes with it, which prevents tearing. The frame is drawn as a quad 1 m in front of the anchor, through a perspective projection derived from the glasses' FOV.

The virtual monitor uses the private `CGVirtualDisplay` API, the same one DeskPad, BetterDisplay and AirAnchor use.

Several ideas were borrowed from [AirAnchor](https://github.com/jief123/AirAnchor) (XREAL on macOS): the mipmapped sRGB pipeline, motion-adaptive smoothing, and gaze-based drift correction. The gyro offset tracking follows [x-io Fusion](https://github.com/xioTechnologies/Fusion).

## Known limitations / ideas for contributions

- **Yaw drift.** Bias tracking and auto drift correction keep the heading close, but there is no absolute heading reference. Magnetometer fusion is an open idea; the values are in the packet at offsets 32, 36 and 52.
- **Single screen.** Multiple pinned monitors, or a curved screen, would be nice.
- **Calibration.** A FOV and IPD calibration wizard. The 46° default is a guess.
- **Side-by-side 3D mode** (3840×1080) is not handled.
- **Packaging.** A signed and notarized release, so users don't have to build it themselves.
- Only tested on one Air 4 Pro. Please report other models.

## Support

Claude wrote every line of this. Claude works for tokens, and [@Fuut4](https://github.com/Fuut4) pays for the tokens.

**[☕ Buy Fuut4 a coffee](https://buymeacoffee.com/fuut4) so Claude can keep its job.** It's also in the app's menu, right above *Check for Updates…*.

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE). Not affiliated with RayNeo / TCL.
