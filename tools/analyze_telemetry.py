#!/usr/bin/env python3
"""Summarizes a RayNeoPin telemetry session and suggests tuning values.

    python3 tools/analyze_telemetry.py [~/Library/Logs/RayNeoPin/telemetry-….csv]

Without an argument it reads the newest session. Standard library only.
"""

import csv
import glob
import math
import os
import statistics
import sys

LOGS = os.path.expanduser("~/Library/Logs/RayNeoPin")


def newest():
    files = sorted(glob.glob(os.path.join(LOGS, "telemetry-*.csv")))
    if not files:
        sys.exit(f"No telemetry in {LOGS}. Turn on Settings › General › Record telemetry.")
    return files[-1]


def num(x):
    try:
        v = float(x)
        return v if math.isfinite(v) else None
    except (TypeError, ValueError):
        return None


def pct(values, p):
    if not values:
        return None
    v = sorted(values)
    k = (len(v) - 1) * p / 100
    lo, hi = math.floor(k), math.ceil(k)
    return v[lo] + (v[hi] - v[lo]) * (k - lo)


def fmt(x, unit="", digits=2):
    return "—" if x is None else f"{x:.{digits}f}{unit}"


def load(path):
    state_header = sample_header = None
    states, samples, events, meta = [], [], [], []
    with open(path, newline="") as f:
        for row in csv.reader(f):
            if not row:
                continue
            if row[0].startswith("#"):
                meta.append(",".join(row))
                fields = [c.strip("# ") for c in row]
                if fields[0] == "kind" and len(fields) > 20:
                    state_header = fields
                elif fields[0] == "kind" and "mismatch" in fields:
                    sample_header = fields
                continue
            kind = row[0]
            if kind == "s" and state_header:
                states.append(dict(zip(state_header, row)))
            elif kind == "a" and sample_header:
                samples.append(dict(zip(sample_header, row)))
            elif kind == "e":
                events.append((num(row[1]), ",".join(row[2:]).strip('"')))
    return meta, states, samples, events


def col(rows, key):
    return [v for v in (num(r.get(key)) for r in rows) if v is not None]


def section(title):
    print(f"\n{title}\n" + "─" * len(title))


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else newest()
    meta, states, samples, events = load(path)
    print(f"RayNeoPin telemetry: {os.path.basename(path)}")
    if meta:
        print(meta[0].lstrip("# "))
    if not states:
        sys.exit("No state rows in this file.")
    t = col(states, "t")
    t0, duration = t[0], t[-1] - t[0]
    print(f"Duration {duration / 60:.1f} min, {len(states)} snapshots, {len(samples)} AirPods samples, {len(events)} events")
    suggestions = []

    # ── Glasses ────────────────────────────────────────────────────────────────
    section("Glasses")
    connected = [r for r in states if r.get("glasses_connected") == "1"]
    print(f"Connected {100 * len(connected) / len(states):.0f}% of the time; IMU rate median {fmt(statistics.median(col(states, 'imu_hz')) if col(states, 'imu_hz') else None, ' Hz', 0)}")
    temps = col(states, "temp_c")
    if temps:
        print(f"Temperature {min(temps):.1f} → {max(temps):.1f} °C (warmed {max(temps) - min(temps):.1f} °C)")
    rejected = [r for r in states if r.get("gravity_rejected") == "1"]
    print(f"Gravity rejected (accelerating) {100 * len(rejected) / len(states):.1f}% of the time")
    still = [r for r in states if (num(r.get("still_s")) or 0) > 1.5]
    if still:
        for axis in "xyz":
            g = col(still, f"gyro_{axis}")
            b = col(still, f"bias_{axis}")
            if g and b:
                resid = [gi - bi for gi, bi in zip(g, b)]
                print(f"  at rest, axis {axis}: noise σ {statistics.pstdev(g):.3f} °/s, residual after bias {statistics.mean(resid):+.4f} °/s")
        print(f"  ({len(still)} snapshots at rest, {len(still) * 0.05:.0f} s)")
    for axis in "xyz":
        b = col(states, f"bias_{axis}")
        if len(b) > 2:
            print(f"Bias {axis}: {b[0]:+.4f} → {b[-1]:+.4f} °/s (moved {b[-1] - b[0]:+.4f})")
    speeds = col(states, "speed")
    if speeds:
        print(f"Head speed: median {pct(speeds, 50):.0f} °/s, 99th percentile {pct(speeds, 99):.0f} °/s, peak {max(speeds):.0f} °/s")

    # ── AirPods ────────────────────────────────────────────────────────────────
    section("AirPods")
    with_airpods = [r for r in states if r.get("tracking") in ("both", "airpods")]
    if not with_airpods:
        print("Not used in this session.")
    else:
        receiving = [r for r in with_airpods if r.get("airpods_receiving") == "1"]
        print(f"Data arriving {100 * len(receiving) / len(with_airpods):.0f}% of the time; rate median {fmt(pct(col(receiving, 'airpods_hz'), 50), ' Hz', 0)}")
        delays = col(receiving, "airpods_delay_ms")
        if delays:
            print(f"Delivery delay: median {pct(delays, 50):.0f} ms, 95th {pct(delays, 95):.0f} ms, max {max(delays):.0f} ms")
        lags = col(receiving, "cal_lag_ms")
        if lags:
            print(f"Calibrated sensor delay: {lags[-1]:.0f} ms (range {min(lags):.0f}–{max(lags):.0f})")
        ready_at = next((num(r["t"]) for r in states if r.get("cal_ready") == "1"), None)
        first_rx = next((num(r["t"]) for r in receiving), None)
        if ready_at and first_rx:
            print(f"Calibration finished {ready_at - first_rx:.1f} s after the first AirPods data")
        elif first_rx:
            prog = col(receiving, "cal_progress")
            print(f"Calibration never finished (progress reached {100 * max(prog):.0f}%)" if prog else "Calibration never finished")
            suggestions.append("AirPods calibration didn't finish: check the 'airpods calibration step' events and fit error below.")
        fits = col([r for r in receiving if r.get("cal_ready") == "1"], "cal_fit")
        if fits:
            print(f"Fit error once calibrated: median {100 * pct(fits, 50):.1f}%, worst {100 * max(fits):.1f}%")
        active = [r for r in with_airpods if r.get("airpods_active") == "1"]
        ignored = [r for r in with_airpods if r.get("airpods_ignored") == "1"]
        print(f"Correcting drift {100 * len(active) / len(with_airpods):.0f}% of the time, ignored (disagreeing) {100 * len(ignored) / len(with_airpods):.1f}%")
        corr = [(num(r["t"]), num(r["heading_correction"])) for r in active if num(r.get("heading_correction")) is not None]
        if len(corr) > 20 and corr[-1][0] - corr[0][0] > 60:
            rate = (corr[-1][1] - corr[0][1]) / ((corr[-1][0] - corr[0][0]) / 60)
            print(f"Heading correction: {corr[0][1]:+.2f}° → {corr[-1][1]:+.2f}° ({rate:+.2f}°/min): that is the glasses' yaw drift the AirPods removed")
        learned = [col(states, f"bias_learned_{a}") for a in "xyz"]
        if all(learned) and max(abs(v) for v in learned[1]) > 0:
            print(f"Bias learned from AirPods (yaw axis): {learned[1][-1]:+.4f} °/s")

    if samples:
        mismatch = col(samples, "mismatch")
        sp = col(samples, "speed_glasses")
        moving = [m for m, s in zip(mismatch, sp) if s > 15]
        print(f"Per-sample comparison with the glasses ({len(samples)} samples, {len(moving)} while turning):")
        if moving:
            p50, p90, p99 = pct(moving, 50), pct(moving, 90), pct(moving, 99)
            print(f"  mismatch while turning: median {p50:.1f}, 90th {p90:.1f}, 99th {p99:.1f} °/s")
            ratio = [m / s for m, s in zip(mismatch, sp) if s > 15]
            print(f"  relative to speed: median {100 * pct(ratio, 50):.0f}%, 99th {100 * pct(ratio, 99):.0f}%")
            # The glitch gate allows max(20 °/s, 50 % of speed); suggest from the data.
            suggestions.append(f"Glitch threshold: real disagreement while turning tops out near {p99:.0f} °/s (99th) "
                               f"or {100 * pct(ratio, 99):.0f}% of speed; the app allows max(20 °/s, 50%).")
        arrivals = col(samples, "arrival")
        if len(arrivals) > 2:
            gaps = [b - a for a, b in zip(arrivals, arrivals[1:])]
            bursts = sum(1 for g in gaps if g < 0.003)
            print(f"  delivery: median gap {1000 * pct(gaps, 50):.0f} ms, longest {1000 * max(gaps):.0f} ms, {100 * bursts / len(gaps):.0f}% arrived in bursts")

    # ── Rendering ──────────────────────────────────────────────────────────────
    section("Rendering")
    fps, drawn = col(states, "fps"), col(states, "drawn_fps")
    if fps:
        print(f"Frame ticks median {pct(fps, 50):.0f}/s; actually drawn median {pct(drawn, 50):.0f}/s (idle frames skipped)")
        low = [f for f in fps if f < 100]
        if low and len(low) > 0.05 * len(fps):
            suggestions.append(f"Frame rate below 100 for {100 * len(low) / len(fps):.0f}% of the session: check 120 Hz and the frame pacing setting.")
    pred = col(states, "prediction_ms")
    if pred:
        print(f"Prediction look-ahead median {pct(pred, 50):.1f} ms")
    lock = col(states, "pixel_lock")
    if lock:
        print(f"Pixel lock fully engaged {100 * sum(1 for v in lock if v >= 1) / len(lock):.0f}% of the time")

    # ── Events ─────────────────────────────────────────────────────────────────
    section("Events")
    counts = {}
    for _, m in events:
        key = m.split("(")[0].split(":")[0].strip()
        counts[key] = counts.get(key, 0) + 1
    for k, n in sorted(counts.items(), key=lambda kv: -kv[1]):
        print(f"  {n:4d} × {k}")
    print("  timeline:")
    for when, m in events[:60]:
        print(f"    {((when or t0) - t0) / 60:6.2f} min  {m}")
    if len(events) > 60:
        print(f"    … {len(events) - 60} more")
    jumps = counts.get("airpods reference jumped", 0)
    if jumps > max(3, duration / 120):
        suggestions.append(f"{jumps} AirPods reference jumps: more than Spatial Audio re-centers explain; the jump check may be too sensitive.")

    section("Suggestions")
    for s in suggestions or ["Nothing stands out. Send this report anyway: it sets the baseline."]:
        print(f"• {s}")


if __name__ == "__main__":
    main()
