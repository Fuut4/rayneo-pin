# Test branch: `test/everything`

This branch has every idea from the research pass. Each one has its own switch, so you can turn it on and off and compare. Keep what helps; the rest gets dropped before merging into `main`.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/Fuut4/rayneo-pin/test/everything/install.sh | RAYNEOPIN_BRANCH=test/everything zsh
```

**Check for Updates…** now stays on this branch. To go back to `main`:

```bash
curl -fsSL https://raw.githubusercontent.com/Fuut4/rayneo-pin/main/install.sh | RAYNEOPIN_BRANCH=main zsh
```

Your settings carry over both ways. Everything new lives in four new menus: **Readability**, **Anchoring**, **Drift & Accuracy**, **Latency & CPU**. Developer mode (⌃⌥D) shows most of the new values live.

## New hotkeys

| Hotkey | Action |
|---|---|
| ⌃⌥1 / ⌃⌥2 / ⌃⌥3 | Preset: Desk / Sofa / Lying down |
| ⌃⌥F | Smooth Follow on/off |
| ⌃⌥↑ / ⌃⌥↓ | Raise / lower the screen (2° steps) |
| ⌃⌥G | Start / finish the full-turn sensitivity calibration |
| Double tap on the glasses | Recenter |

## What's in it

On = enabled by default on this branch.

### Readability

| Option | Default | What to look for |
|---|---|---|
| Sharpening Style: **Adaptive (RCAS)** / Unsharp Mask | RCAS | AMD's per-pixel sharpening; it can't draw halos. The old unsharp mask is still there, now clamped to the neighbouring pixels so it can't overshoot. Compare at High sharpness. |
| Sharpen Only When Still | on | Text shouldn't "crawl" while you turn. It sharpens back once you stop. |
| Smart Sampling | on | Bicubic (Catmull-Rom) when the screen is enlarged, 4× rotated-grid sampling when shrunk. Look at small text at zoom 120% and 70%. |
| Pixel Lock When Still | on | Near 100% scale the zoom snaps to exactly 1:1. When you hold still and look at the screen roughly straight on, it eases onto the pixel grid in ¼ s with no resampling, so text should look like a real monitor. Developer mode: `pixel lock 100%`, `1:1 fix ×…`. Best with Virtual Display › Crisp. In Glasses Screen mode it only engages around 120% zoom. Watch for a faint "settle" of the edges when it engages; tell me if it bothers you. |
| Curved Ultrawide Screen | on | 21:9 and wider bend around you, so the edges are as far away and as sharp as the middle. |
| Warmth / Brightness | off / 100% | Night comfort. Software only: I didn't find RayNeo's hardware brightness command. |

### Anchoring

| Option | Default | What to look for |
|---|---|---|
| Presets | — | **Desk**: fixed in space. **Sofa**: Smooth Follow + roll locked. **Lying Down**: Smooth Follow + pitch and roll locked. |
| Smooth Follow + Dead Zone | off, 20° | The screen stays put until you look past the dead zone, then glides back in front of you. Hides drift. |
| Recenter After Looking Away | off | Look more than ~35° away for 10 s and then hold still: it recenters there. |
| Double-Tap to Recenter | on | Two sharp taps on the frame. Thresholds came from Rokid hardware: if it misses taps or fires on its own, send me `taps / peak jerk / peak Δa` from developer mode after tapping. |
| Neck Saver | off | 1.5× means turning 30° shows 45°. |
| Screen Height | 0° | ⌃⌥↑ / ⌃⌥↓. |
| Side Screens | off | Extra 1920×1080 virtual displays left/right of the pinned one, drawn beside it in the glasses. Switches to the Virtual Display setup. Each one is a real macOS display. |

### Drift and accuracy

| Option | Default | What to look for |
|---|---|---|
| Sensor Fusion: Complementary / **Kalman** | Complementary | The Kalman filter keeps the gyro bias as part of its state and rejects shakes statistically. Try it for a while and compare drift. |
| Strict Gravity Rejection | on | Ignores the accelerometer while you accelerate (walking, nodding fast), so pitch/roll don't wobble. Developer mode shows `GRAVITY REJECTED` while it's ignoring it. |
| Temperature Compensation | on | Learns bias vs. temperature from every rest period, and corrects as the glasses warm up. Developer mode: `temp model` shows the slope once it has seen 1.5 °C of range. That takes a few rest periods during warm-up. Saved between sessions. |
| Learn Gyro Bias from AirPods | on | Apple keeps the AirPods' gyro calibrated, so any steady difference is the glasses' bias, on all three axes, even while moving. Developer mode: `bias learn` (residual and total applied). |
| Learn Gyro Sensitivity from AirPods | off | Corrects scale error (it can feel like "swimming" even with the right FOV). Slow, and capped at ±2% per step. |
| Calibrate Turn Sensitivity (⌃⌥G) | — | Look at something, press ⌃⌥G, turn around once, look at it again, press ⌃⌥G. It refuses if the turn wasn't whole. |
| Mac Camera as Drift Reference | off | The Mac's camera tells which way your face points; that never drifts. It learns the direction while you turn, then says "locked on". Developer mode: `CAMERA` line. Works while your face is within ~30° of the camera. The glasses may hide part of your face. |
| Typing Hint | off | While you type, the screen turns very slowly (≤ 0.15 °/s) so the caret sits where your head points. Weak by design, because your eyes move more than your head. Needs Accessibility. |
| Probe Glasses Calibration | — | Sends `0x3E` ("read gyro bias" in RayNeo's SDK enum) and nothing that writes. The raw reply appears as `last ack` in developer mode; send it to me. |

### Latency and CPU

| Option | Default | What to look for |
|---|---|---|
| Smoothing: **1€ Filter** / Classic | 1€ | Less jitter when still, less lag when moving. Developer mode shows the live cutoff in Hz. |
| Predict from the Filtered Pose | on | Extrapolating raw gyro noise amplified jitter in rokid-spatial's tests. |
| Frame Pacing: **Metal Display Link** / Classic | Metal | Prediction targets the real time the frame reaches the panel (`present in … ms` in developer mode), and the app never stalls waiting for a buffer. Switching rebuilds the renderer. |
| Prediction Trim | 0 | If the screen lags when you turn, try +4; if it overshoots or wobbles when you stop, try −4. |
| Skip Frames When Nothing Changes | on | Developer mode: `drawn …/s` falls toward 0 when you and the screen are still. |
| Metal Performance HUD | off | Apple's FPS and GPU-time overlay, in the glasses. |

Also always on:

- The cursor texture is only rebuilt when the cursor's shape changes; it used to be rebuilt every frame.
- The cursor and cursor-fence timers are merged into one, and do nothing without glasses.
- Capture stops while the glasses are asleep (off your head).
- On every Space change the capture filter is re-applied, which fixes the frozen image after a fullscreen app.
- **Open at Login** is in the main menu.

## Test checklist

1. **Text:** compare Sharpening Style, Smart Sampling and Pixel Lock on small text (e.g. a terminal), in Virtual Display › Crisp at 100% zoom.
2. **Turning:** turn your head left and right, then stop. Is the text crawling while you move, and is there wobble or overshoot when you stop? Try the 1€ filter vs. Classic, and Prediction Trim.
3. **Drift:** do 20 minutes of normal use from a cold start with Glasses Only, first with Temperature Compensation off and then on. Note how far the screen drifted. Repeat with Kalman.
4. **AirPods:** with Glasses + AirPods, check that `bias learn` settles, and that the heading correction moves less than before.
5. **Double tap:** tap twice on the temple. Also check it doesn't fire while walking or nodding.
6. **Follow:** on the sofa, use the Sofa preset, look around, and look back.
7. **CPU:** compare Activity Monitor with Skip Frames on and off while reading a static page.
8. **Camera:** a silly one. Turn it on facing the Mac, turn your head a few times, then check whether drift stays at zero.

If something looks wrong, turn on developer mode with **Also Show Developer Data on the Mac** and screenshot that panel.

## Not included

- **Stereo/3D depth:** the optics focus at about 6 m, so stereo depth fights your eyes (vergence-accommodation conflict). rokid-spatial removed it and VITURE doesn't offer it on Mac.
- **Hardware brightness** and the glasses' **write** calibration commands (`0x3C`, `0x3F`): unknown effects on the glasses, so nothing is sent that could write to them.
- **Magnetometer:** unreliable indoors (rokid-spatial measured ~108 µT next to electronics, against the Earth's 25–65 µT).
- Tip from rokid-spatial: with **Displays have separate Spaces** turned off in macOS, a fullscreen app blacks out every other display, including the glasses. Leave it on.
