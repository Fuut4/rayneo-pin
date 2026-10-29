# Architecture

## Glasses protocol

Vendor HID, usage page `0xFF00`, 64-byte reports. Host → glasses `0x66 cmd value`; glasses → host `0x99 type`.
From [verncat/RayNeo-Air-3S-Pro-OpenVR](https://github.com/verncat/RayNeo-Air-3S-Pro-OpenVR), verified on an Air 4 Pro (`1bbb:af50`).

| Cmd | |
|---|---|
| `0x01` / `0x02` | IMU on / off |
| `0x06` / `0x07` | 3840×1080 SBS @60 / 2D |
| `0x20` / `0x21` | 60 / 120 Hz |
| `0x38 0` / `1` | Proximity sensor off / on |

IMU report `0x65`, little-endian:

| Offset | |
|---|---|
| 4 | accel `float[3]`, m/s² |
| 16 | gyro `float[3]`, °/s |
| 28 | temperature, °C |
| 40 | tick `u32`, 100 µs |
| 44 | proximity: ~1200 off-head, 65535 worn |

Frame: x right, y up, z toward the face.

## Pipeline

| Stage | |
|---|---|
| Fusion | Mahony; gravity gated under acceleration. Optional MEKF with bias state. |
| Bias | Table calibration, persisted; [VQF](https://github.com/dlaidig/vqf)-style rest refinement capped at 0.6 °/s; bias-vs-temperature model. |
| AirPods | Clock offset by rate correlation; ear-mount rotation via Wahba (Davenport q-method); per-sample cross-check against the glasses gyro; reference jumps detected by rotation vector. Heading correction ≤ 0.5 °/s, up to 2 °/s on a trusted fit. |
| Smoothing | 1€ filter, 0.1° soft dead zone. |
| Latency | Late latching; prediction to `CAMetalDisplayLink` present time, capped at 3°. |
| Render | Metal; zero-copy IOSurface, dirty-rect uploads; gamma-space bicubic + clamped unsharp; idle frames skipped. |
| Rest | Off-head (proximity) or unplugged: capture, rendering and AirPods motion stop; IMU keeps refining bias. |

## AirPods handoff

`audioaccessoryd` decides which device gets the AirPods, from Now Playing registration and mic activity ([WWDC23 10233](https://developer.apple.com/videos/play/wwdc2023/10233/)). Notification sounds never move them; Control Center's switch and the AACP ownership messages ([LibrePods](https://github.com/librepods-org/librepods)) are private. On recenter or wear, RayNeoPin sets them as output and plays a brief chime registered as Now Playing. Never on its own.
