# How RayNeoPin works

## Glasses protocol

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

## Sensor fusion

| Stage | Method |
|---|---|
| Orientation | Mahony complementary filter: gyro integration, gravity correction for pitch/roll, ignored while accelerating. An optional Kalman filter keeps the gyro bias in its state. |
| Temperature | Bias vs. temperature learned from every rest period, corrected as the glasses warm up |
| Gyro bias | Startup and table calibration, the value saved across launches, and rest-based refinement after [VQF](https://github.com/dlaidig/vqf) (gyro within 2 °/s of its 0.5 s low-pass, accelerometer within 0.5 m/s², ≥1.5 s). Unlike VQF, only corrections under 0.6 °/s are accepted, so slow head turns are not absorbed. |
| Latency | Late latching (pose read after the drawable is acquired). Look-ahead is 10 ms + 0.45 × frame time, plus 7 ms for the bottom row (panel scan-out), as tuned in [XRLinuxDriver](https://github.com/wheaney/XRLinuxDriver) for RayNeo. |
| Micro-movements | 1€ filter, 0.1° soft dead zone and motion-adaptive smoothing (cf. [OpenTrack Accela](https://github.com/opentrack/opentrack), [AirAnchor](https://github.com/jief123/AirAnchor)) |
| AirPods ↔ glasses | Clock offset from rotation-speed correlation. Quaternion convention checked against `rotationRate`. Ear-mount rotation solved from paired angular velocities (Wahba's problem, Davenport q-method), plus a world-frame alignment. Headings are compared at each sample's own timestamp against a 5 s glasses pose history. Every sample is cross-checked against the glasses' gyro at the same instant. AirPods turning while the head doesn't (adjusting them, reconnecting, a bud swap) are ignored, and the glasses take over until the two agree again. A persistent disagreement is treated as a reseat, and the ear-mount rotation is relearned. The AirPods heading correction is capped at 0.5 °/s, so it can never make the screen jump. |

## Rest

When the glasses come off your head (their proximity sensor reads about 1200 off the head and 65535 on it), or are unplugged, RayNeoPin rests: no capture, no frames, no AirPods motion (sparing their battery), no caret polling. The glasses' IMU keeps streaming, since it's cheap, refines the gyro bias while they lie still, and carries the proximity readings that wake it up. The displays stay as they are, so no window moves. A card at the top of the Mac's screen says so. Putting the glasses on resumes everything within a second, and once your head settles the screen is centered where you look; if the AirPods aren't available then, a short alert in the glasses says it continues with the glasses only.

## Rendering

A borderless window covers the glasses' display (black is transparent on the optics). Metal renders on its own thread, paced by `CAMetalDisplayLink`, so prediction targets the moment the frame reaches the panel. ScreenCaptureKit frames are used straight from their IOSurface when possible, and otherwise only the changed regions are copied. Text is resampled in gamma space (as macOS draws it) with a bicubic filter and a clamped unsharp mask, which removes the halo that linear-light resizing caused. Frames are skipped while nothing changes. Our own windows are excluded from the capture.

`RayNeoPin --render-lab` renders real text through this pipeline offscreen and scores it against native text; CI runs it on every push. See [TESTING.md](TESTING.md) for the results and every option.
