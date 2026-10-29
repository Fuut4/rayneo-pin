# User guide

## Updates

**Update channels.** Like Apple's betas, **Update Channel** in the menu (or Settings › About) picks where updates come from: **Release** follows `main`, **Developer** follows `develop`, where new work lands first. Switching updates right away, and switching back works the same way. Your settings carry over.

The Screen Recording permission is tied to the code signature. `build.sh` signs with your first *Apple Development* certificate (a free Apple ID certificate from Xcode works), so the permission survives updates. Ad-hoc builds need it granted again after every update.

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

**When the AirPods aren't available** (another device such as your iPhone has them, they're in their case, or they aren't the sound output), the glasses show a short notice, *Glasses head tracking only*, with the reason, and tracking continues with the glasses. RayNeoPin doesn't take them back on its own: watch something on your iPhone with them and they stay there. To use them for tracking again, recenter (⌃⌥R or a double tap) or put the glasses on, which recenters too: RayNeoPin makes them this Mac's output and plays a short chime as media, registered as Now Playing for its length. That is the signal macOS's own automatic switching acts on (the same as pressing play on the Mac), so the AirPods move here even from an iPhone playing music. A plain notification sound wouldn't: macOS never moves AirPods for those. It needs **Connect to This Mac: Automatically** in the AirPods' Bluetooth settings. **Bring AirPods Back to This Mac** in the menu does the same. A notice says when AirPods tracking resumes. Turn this off under Settings › Head Tracking.

## Calibration

**Gyro (glasses on a table).** The glasses turn their display off when not worn. RayNeoPin disables the proximity sensor for the duration, so the IMU keeps streaming, then restores it.

1. Choose **Calibrate Gyro (glasses on a table)…**. You hear a tick and a progress window appears on the Mac.
2. Put the glasses down and don't touch them. It needs about 3 s of stillness and gives up after 90 s.
3. A chime means done; a low tone means it failed and the previous calibration is kept.

The bias is saved and refined automatically whenever the glasses are at rest.

**Turn sensitivity (⌃⌥G).** Look at something, press ⌃⌥G, turn around once, look at it again and press ⌃⌥G. It refuses if the turn wasn't whole.

**FOV.** If the screen slides in the direction you turn instead of staying put, adjust with ⌃⌥L / ⌃⌥K. The default is 43° diagonal.
