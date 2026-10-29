# Development

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
