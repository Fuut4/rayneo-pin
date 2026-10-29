#!/usr/bin/env python3
"""Analyzes a RayNeoPin telemetry session: a text summary, anomalies, and report.html with charts.

    python3 tools/analyze_telemetry.py [session folder or exported .zip]

Without an argument it reads the newest session in ~/Library/Logs/RayNeoPin. Standard library only.
The report is written next to the data (report.html) and opened on macOS.
"""

import csv
import glob
import html
import json
import math
import os
import statistics
import subprocess
import sys
import tempfile
import zipfile

LOGS = os.path.expanduser("~/Library/Logs/RayNeoPin")


# ── Loading ───────────────────────────────────────────────────────────────────

def find_session(arg):
    if arg and arg.endswith(".zip"):
        out = tempfile.mkdtemp(prefix="rayneopin-")
        with zipfile.ZipFile(arg) as z:
            z.extractall(out)
        inner = [os.path.join(out, d) for d in os.listdir(out) if d.startswith("session-")]
        return inner[0] if inner else out
    if arg:
        return arg
    sessions = sorted(glob.glob(os.path.join(LOGS, "session-*")))
    if not sessions:
        sys.exit(f"No telemetry sessions in {LOGS}. Turn on Settings › General › Record telemetry.")
    return sessions[-1]


def num(x):
    try:
        v = float(x)
        return v if math.isfinite(v) else None
    except (TypeError, ValueError):
        return None


def load(path):
    if not os.path.exists(path):
        return []
    with open(path, newline="") as f:
        return list(csv.DictReader(f))


def series(rows, key, t0, tkey="t"):
    xs, ys = [], []
    for r in rows:
        t, v = num(r.get(tkey)), num(r.get(key))
        if t is not None and v is not None:
            xs.append((t - t0) / 60)
            ys.append(v)
    return xs, ys


def pct(values, p):
    if not values:
        return None
    v = sorted(values)
    k = (len(v) - 1) * p / 100
    lo, hi = math.floor(k), math.ceil(k)
    return v[lo] + (v[hi] - v[lo]) * (k - lo)


def fmt(x, unit="", d=1):
    return "—" if x is None else f"{x:.{d}f}{unit}"


# ── Charts (inline SVG) ───────────────────────────────────────────────────────

COLORS = ["#2f6fde", "#e0533b", "#2e9d5b", "#c48a00", "#8a52d6", "#0e9aa7", "#d6478f"]


def downsample(xs, ys, buckets=1400):
    """Min/max per bucket, so spikes survive."""
    if len(xs) <= buckets * 2:
        return xs, ys
    out_x, out_y = [], []
    step = len(xs) / buckets
    for b in range(buckets):
        lo, hi = int(b * step), int((b + 1) * step)
        if hi <= lo:
            continue
        seg = range(lo, hi)
        i_min = min(seg, key=lambda i: ys[i])
        i_max = max(seg, key=lambda i: ys[i])
        for i in sorted({i_min, i_max}):
            out_x.append(xs[i])
            out_y.append(ys[i])
    return out_x, out_y


def chart(title, lines, events, x_max, unit="", height=190):
    W, H, L, R, T, B = 1100, height, 56, 12, 26, 22
    lines = [(n, *downsample(xs, ys), c) for n, xs, ys, c in lines if xs]
    if not lines:
        return f"<h3>{html.escape(title)}</h3><p class=empty>No data.</p>"
    all_y = [y for _, _, ys, _ in lines for y in ys]
    lo, hi = pct(all_y, 0.5), pct(all_y, 99.5)
    lo, hi = min(lo, min(all_y) if len(all_y) < 50 else lo), max(hi, max(all_y) if len(all_y) < 50 else hi)
    if hi - lo < 1e-9:
        lo, hi = lo - 1, hi + 1
    pad = (hi - lo) * 0.06
    lo, hi = lo - pad, hi + pad

    def X(x): return L + (W - L - R) * (x / max(x_max, 1e-9))
    def Y(y): return T + (H - T - B) * (1 - (min(max(y, lo), hi) - lo) / (hi - lo))

    svg = [f'<svg viewBox="0 0 {W} {H}" class=chart>']
    for k in range(5):
        y = lo + (hi - lo) * k / 4
        svg.append(f'<line x1={L} x2={W - R} y1={Y(y):.1f} y2={Y(y):.1f} class=grid />'
                   f'<text x={L - 6} y={Y(y) + 4:.1f} class=axis text-anchor=end>{y:.3g}</text>')
    for k in range(11):
        x = x_max * k / 10
        svg.append(f'<text x={X(x):.1f} y={H - 6} class=axis text-anchor=middle>{x:.1f}</text>')
    for t, label in events:
        svg.append(f'<line x1={X(t):.1f} x2={X(t):.1f} y1={T} y2={H - B} class=event><title>{html.escape(label)}</title></line>')
    for name, xs, ys, color in lines:
        pts = " ".join(f"{X(x):.1f},{Y(y):.1f}" for x, y in zip(xs, ys))
        svg.append(f'<polyline points="{pts}" fill=none stroke="{color}" stroke-width=1.2><title>{html.escape(name)}</title></polyline>')
    legend = " ".join(f'<span style="color:{c}">■</span> {html.escape(n)}' for n, _, _, c in lines)
    svg.append("</svg>")
    return f"<h3>{html.escape(title)} <small>{html.escape(unit)}</small></h3><div class=legend>{legend}</div>" + "".join(svg)


# ── Analysis ──────────────────────────────────────────────────────────────────

def main():
    folder = find_session(sys.argv[1] if len(sys.argv) > 1 else None)
    info = {}
    if os.path.exists(os.path.join(folder, "session.json")):
        info = json.load(open(os.path.join(folder, "session.json")))
    imu = load(os.path.join(folder, "imu.csv"))
    ap = load(os.path.join(folder, "airpods.csv"))
    frames = load(os.path.join(folder, "frames.csv"))
    state = load(os.path.join(folder, "state.csv"))
    events = load(os.path.join(folder, "events.csv"))
    times = [num(r["t"]) for rows in (imu, frames, state) for r in rows[:1] if num(r.get("t")) is not None]
    if not times:
        sys.exit(f"No data in {folder}")
    t0 = min(times)
    t_end = max(num(rows[-1]["t"]) for rows in (imu, frames, state) if rows)
    minutes = (t_end - t0) / 60
    ev = [((num(e["t"]) - t0) / 60, e["event"] + (f" — {e['details']}" if e.get("details") else "")) for e in events if num(e.get("t"))]

    out = []

    def say(s=""):
        print(s)
        out.append(s)

    say(f"RayNeoPin telemetry: {os.path.basename(folder)}  (build {info.get('revision', '?')}, {info.get('model', '')}, {info.get('macos', '')})")
    say(f"{minutes:.1f} min · {len(imu)} IMU samples · {len(ap)} AirPods samples · {len(frames)} frames · {len(events)} events")
    anomalies = []

    # Glasses IMU
    say("\nGLASSES")
    dts = [num(r["dt_ms"]) for r in imu if num(r.get("dt_ms")) is not None]
    if dts:
        dup = sum(1 for d in dts if d == 0)
        gaps = [(num(r["t"]), d) for r, d in zip(imu, dts) if d and d > 10]
        say(f"  rate {len(imu) / max(minutes * 60, 1e-9):.0f} reports/s, repeated reports {100 * dup / len(dts):.1f}%, gaps >10 ms: {len(gaps)}")
        for t, d in gaps[:10]:
            anomalies.append(((t - t0) / 60, f"IMU gap {d:.0f} ms"))
    temps = [num(r["temp_c"]) for r in imu[::50] if num(r.get("temp_c"))]
    if temps:
        say(f"  temperature {min(temps):.1f} → {max(temps):.1f} °C")
    for axis in "xyz":
        b = [num(r[f"bias_{axis}"]) for r in imu[::100] if num(r.get(f"bias_{axis}")) is not None]
        if len(b) > 1:
            say(f"  bias {axis}: {b[0]:+.4f} → {b[-1]:+.4f} °/s")
    rest = [r for r in imu if (num(r.get("still_s")) or 0) > 1.5]
    if rest:
        for axis in "xyz":
            g = [num(r[f"gyro_{axis}"]) for r in rest if num(r.get(f"gyro_{axis}")) is not None]
            say(f"  at rest axis {axis}: noise σ {statistics.pstdev(g):.3f} °/s over {len(rest) / 500:.0f} s")
    rejected = sum(1 for r in imu if r.get("gravity_rejected") == "1")
    if imu:
        say(f"  gravity rejected {100 * rejected / len(imu):.1f}% of samples")

    # AirPods
    say("\nAIRPODS")
    if not ap:
        say("  no AirPods samples")
    else:
        delays = [num(r["delay_ms"]) for r in ap if num(r.get("delay_ms")) is not None]
        arr = [num(r["arrival"]) for r in ap if num(r.get("arrival")) is not None]
        gaps = [(a, b - a) for a, b in zip(arr, arr[1:]) if b - a > 0.2]
        say(f"  {len(ap) / max(minutes * 60, 1e-9):.0f} samples/s · delay median {fmt(pct(delays, 50), ' ms', 0)}, 95th {fmt(pct(delays, 95), ' ms', 0)} · gaps >200 ms: {len(gaps)}")
        for a, g in gaps[:20]:
            anomalies.append(((a - t0) / 60, f"AirPods gap {1000 * g:.0f} ms"))
        buds = sorted({r.get("bud") for r in ap})
        say(f"  earbuds seen: {', '.join({'0': 'unknown', '1': 'left', '2': 'right'}.get(b, b) for b in buds)}")
        ready = [r for r in ap if r.get("ready") == "1"]
        vm = [num(r["vector_mismatch"]) for r in ready if num(r.get("vector_mismatch")) is not None]
        spd = [num(r["glasses_speed"]) for r in ready if num(r.get("vector_mismatch")) is not None]
        moving = [m for m, s in zip(vm, spd) if s and s > 15]
        if moving:
            say(f"  calibrated, while turning: rate mismatch median {pct(moving, 50):.1f}, 90th {pct(moving, 90):.1f}, 99th {pct(moving, 99):.1f} °/s")
        yawd = [abs(num(r["yaw_vs_glasses"])) for r in ready if num(r.get("yaw_vs_glasses")) is not None]
        if yawd:
            say(f"  AirPods-as-glasses yaw vs glasses: median {pct(yawd, 50):.2f}°, 95th {pct(yawd, 95):.2f}°, max {max(yawd):.2f}°")
        fits = [num(r["fit"]) for r in ready if num(r.get("fit")) is not None]
        lags = [num(r["lag_ms"]) for r in ready if num(r.get("lag_ms")) is not None]
        if fits:
            say(f"  fit {100 * fits[-1]:.1f}% · sensor delay {lags[-1]:.0f} ms (range {min(lags):.0f}–{max(lags):.0f})")
        for prev, cur in zip(ap, ap[1:]):
            for key, label in (("jumps", "AirPods reference jump"), ("gaps", "AirPods data gap"), ("bud_switches", "earbud switch"),
                               ("reseats", "AirPods reseat")):
                if prev.get(key) != cur.get(key):
                    anomalies.append(((num(cur["t"]) - t0) / 60, label))

    # Frames / screen
    say("\nSCREEN & RENDERING")
    if frames:
        dt = [num(r["dt_ms"]) for r in frames if num(r.get("dt_ms"))]
        stalls = [(num(r["t"]), num(r["dt_ms"])) for r in frames if (num(r.get("dt_ms")) or 0) > 25]
        say(f"  frame interval median {fmt(pct(dt, 50), ' ms', 2)}, 99th {fmt(pct(dt, 99), ' ms', 1)}, stalls >25 ms: {len(stalls)}")
        for t, d in stalls[:20]:
            anomalies.append(((t - t0) / 60, f"frame stall {d:.0f} ms"))
        pin = [num(r["present_in_ms"]) for r in frames if num(r.get("present_in_ms")) is not None]
        pred = [num(r["prediction_ms"]) for r in frames if num(r.get("prediction_ms")) is not None]
        say(f"  frame reaches the panel in median {fmt(pct(pin, 50), ' ms')} · prediction median {fmt(pct(pred, 50), ' ms')}")
        drawn = [r for r in frames if r.get("drawn") == "1"]
        say(f"  drawn {100 * len(drawn) / len(frames):.0f}% of frames")
        reasons = {}
        for r in drawn:
            for k in (r.get("draw_reason") or "?").split("+"):
                reasons[k] = reasons.get(k, 0) + 1
        say("  why drawn: " + ", ".join(f"{k} {100 * v / max(len(drawn), 1):.0f}%" for k, v in sorted(reasons.items(), key=lambda kv: -kv[1])))
        work = [num(r["work_ms"]) for r in frames if num(r.get("work_ms")) is not None]
        say(f"  CPU work per frame median {fmt(pct(work, 50), ' ms', 2)}, 99th {fmt(pct(work, 99), ' ms', 2)}")
        # Screen jumps: the view moved >1° in one frame while the head was nearly still.
        prev = None
        for r in frames:
            hy, sp = num(r.get("head_yaw")), num(r.get("speed"))
            if prev is not None and hy is not None and sp is not None and sp < 20 and abs(hy - prev) > 1:
                anomalies.append(((num(r["t"]) - t0) / 60, f"screen jumped {hy - prev:+.1f}° at {sp:.0f} °/s head speed"))
            prev = hy
        # Slow slides: heading correction moving >0.3 °/s for 5 s.
        hc = [(num(r["t"]), num(r["heading_correction"])) for r in frames[::12] if num(r.get("heading_correction")) is not None]
        start = None
        for (ta, a), (tb, b) in zip(hc, hc[1:]):
            fast = tb > ta and abs(b - a) / (tb - ta) > 0.3
            if fast and start is None:
                start = (ta, a)
            elif not fast and start is not None:
                if ta - start[0] > 5:
                    anomalies.append(((start[0] - t0) / 60, f"heading correction slid {a - start[1]:+.1f}° over {ta - start[0]:.0f} s"))
                start = None

    say("\nEVENTS")
    counts = {}
    for _, e in ev:
        k = e.split(" — ")[0]
        counts[k] = counts.get(k, 0) + 1
    for k, n in sorted(counts.items(), key=lambda kv: -kv[1]):
        say(f"  {n:4d} × {k}")

    anomalies.sort()
    say(f"\nANOMALIES ({len(anomalies)})")
    for t, a in anomalies[:80]:
        say(f"  {t:7.2f} min  {a}")
    if len(anomalies) > 80:
        say(f"  … {len(anomalies) - 80} more in report.html")

    # Report
    E = ev + [(t, "⚠ " + a) for t, a in anomalies]
    sections = [
        chart("Heading (yaw)", [("glasses fused", *series(imu[::5], "yaw", t0), COLORS[0]),
                                ("AirPods as glasses", *series(ap, "as_glasses_yaw", t0), COLORS[1]),
                                ("pose used", *series(frames[::2], "pose_yaw", t0), COLORS[2]),
                                ("screen anchor", *series(frames[::2], "anchor_yaw", t0), COLORS[3])], E, minutes, "degrees"),
        chart("Screen position in your view", [("yaw", *series(frames[::2], "head_yaw", t0), COLORS[0]),
                                               ("pitch", *series(frames[::2], "head_pitch", t0), COLORS[1]),
                                               ("roll", *series(frames[::2], "head_roll", t0), COLORS[2])], E, minutes, "degrees"),
        chart("Drift corrections", [("AirPods heading correction", *series(frames[::2], "heading_correction", t0), COLORS[0]),
                                    ("camera correction", *series(frames[::2], "camera_correction", t0), COLORS[1])], E, minutes, "degrees"),
        chart("AirPods vs glasses", [("rate mismatch (calibrated)", *series(ap, "vector_mismatch", t0), COLORS[1]),
                                     ("speed mismatch", *series(ap, "speed_mismatch", t0), COLORS[3]),
                                     ("glasses speed", *series(ap, "glasses_speed", t0), COLORS[0])], E, minutes, "°/s"),
        chart("AirPods yaw difference after calibration", [("AirPods-as-glasses minus glasses", *series(ap, "yaw_vs_glasses", t0), COLORS[4])], E, minutes, "degrees"),
        chart("AirPods timing", [("delivery delay", *series(ap, "delay_ms", t0), COLORS[0]),
                                 ("calibrated sensor delay", *series(ap, "lag_ms", t0), COLORS[1])], E, minutes, "ms"),
        chart("AirPods calibration", [("progress", *series(ap, "progress", t0), COLORS[0]), ("left", *series(ap, "left", t0), COLORS[1]),
                                      ("right", *series(ap, "right", t0), COLORS[2]), ("up", *series(ap, "up", t0), COLORS[3]),
                                      ("down", *series(ap, "down", t0), COLORS[4]), ("fit error", *series(ap, "fit", t0), COLORS[5])], E, minutes, "0…1"),
        chart("Head speed", [("glasses", *series(frames[::2], "speed", t0), COLORS[0])], E, minutes, "°/s"),
        chart("Frame timing", [("frame interval", *series(frames, "dt_ms", t0), COLORS[0]),
                               ("frame reaches panel in", *series(frames, "present_in_ms", t0), COLORS[1]),
                               ("prediction", *series(frames, "prediction_ms", t0), COLORS[2]),
                               ("CPU work", *series(frames, "work_ms", t0), COLORS[3])], E, minutes, "ms"),
        chart("Gyro bias", [(f"bias {a}", *series(imu[::25], f"bias_{a}", t0), COLORS[i]) for i, a in enumerate("xyz")], E, minutes, "°/s"),
        chart("Glasses temperature", [("temperature", *series(imu[::100], "temp_c", t0), COLORS[1])], E, minutes, "°C"),
    ]
    page = f"""<!doctype html><meta charset=utf-8><title>RayNeoPin telemetry</title>
<style>
body{{font:14px -apple-system,system-ui,sans-serif;margin:24px;color:#1d1d1f;background:#fbfbfd}}
h1{{font-size:20px}} h3{{margin:22px 0 2px;font-size:15px}} small{{color:#86868b;font-weight:normal}}
pre{{background:#fff;border:1px solid #e5e5ea;border-radius:10px;padding:14px;overflow:auto;font-size:12px}}
.chart{{width:100%;background:#fff;border:1px solid #e5e5ea;border-radius:10px}}
.grid{{stroke:#eee}} .axis{{font-size:10px;fill:#86868b}} .event{{stroke:#d6478f;stroke-opacity:.35;stroke-dasharray:3 3}}
.legend{{font-size:12px;color:#444;margin:2px 0 4px}} .empty{{color:#86868b}}
@media(prefers-color-scheme:dark){{body{{background:#1c1c1e;color:#f2f2f7}} pre,.chart{{background:#2c2c2e;border-color:#3a3a3c}}
.grid{{stroke:#3a3a3c}} .legend{{color:#ccc}}}}
</style>
<h1>RayNeoPin telemetry — {html.escape(os.path.basename(folder))}</h1>
<p>Time axis in minutes. Dashed pink lines are events and anomalies; hover them for details.</p>
{''.join(sections)}
<h3>Summary</h3><pre>{html.escape(chr(10).join(out))}</pre>
<h3>Session</h3><pre>{html.escape(json.dumps(info, indent=2))}</pre>"""
    report = os.path.join(folder, "report.html")
    with open(report, "w") as f:
        f.write(page)
    print(f"\nReport: {report}")
    if sys.platform == "darwin":
        subprocess.run(["open", report])


if __name__ == "__main__":
    main()
