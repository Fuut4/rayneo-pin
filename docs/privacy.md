# Privacy

RayNeoPin can record telemetry to find and fix drift and tracking glitches. **It's off by default.** The first launch asks once, with three choices: record and share, record on this Mac only, or don't record. You can change it, or delete every recording, in **Settings › Privacy**, which also lists every recorded column.

- Recorded: glasses and AirPods motion samples, frame timings, calibration progress, events such as recenters, the app and macOS versions, the Mac model, display resolutions, and this app's settings.
- Never recorded: screen contents, window titles, app names, anything you type, file names, your name or account, AirPods names or Bluetooth addresses, display names, location.
- Shared sessions get a random ID per session and go to the project's database with a key that can only add rows. The servers see your IP address as with any web request; it isn't stored with the data.

`tools/analyze_telemetry.py <session folder or zip>` summarizes a recording and writes an HTML report with charts.
