// Logic tests on simulated sensor data (run by CI: compiled with every source except main.swift).

import Foundation
import simd

var failures = 0
func check(_ ok: Bool, _ what: String) {
    print((ok ? "PASS " : "FAIL ") + what)
    if !ok { failures += 1 }
}

let deg = Double.pi / 180
let g = SIMD3<Double>(0, 9.81, 0)

/// Feeds `seconds` of 500 Hz samples for a true orientation path; returns the last true orientation.
@discardableResult
func simulate(_ f: inout Fusion, seconds: Double, bias: SIMD3<Double>, temperature: (Double) -> Double = { _ in 30 },
              start: Double = 0, noise: Double = 0, rate: (Double) -> SIMD3<Double>, truth: inout simd_quatd, tick: inout UInt32) -> simd_quatd {
    var t = start
    let dt = 0.002
    while t < start + seconds {
        let w = rate(t)
        let l = simd_length(w) * dt
        if l > 0 { truth = simd_normalize(truth * simd_quatd(angle: l, axis: w / simd_length(w))) }
        var acc = truth.inverse.act(g)
        if noise > 0 { acc += SIMD3(Double.random(in: -noise...noise), Double.random(in: -noise...noise), Double.random(in: -noise...noise)) }
        tick &+= 20
        f.update(acc: acc, gyro: w + bias, temperature: temperature(t), tick: tick)
        t += dt
    }
    return truth
}

func tilt(_ a: simd_quatd, _ b: simd_quatd) -> Double {
    // Angle between the "up" each orientation implies (pitch/roll error, ignoring yaw).
    let ua = a.inverse.act(SIMD3(0, 1, 0)), ub = b.inverse.act(SIMD3(0, 1, 0))
    return acos(max(-1, min(1, simd_dot(ua, ub))))
}

// 1. Rest detection learns a small bias (complementary).
do {
    var f = Fusion(bias: .zero)
    var truth = simd_quatd.identity
    var tick: UInt32 = 0
    let bias = SIMD3(0.1, 0.3, -0.2) * deg
    simulate(&f, seconds: 30, bias: bias, rate: { _ in .zero }, truth: &truth, tick: &tick)
    check(simd_length(f.bias - bias) < 0.03 * deg, String(format: "rest bias learned (error %.3f °/s)", simd_length(f.bias - bias) / deg))
}

// 2. Both filters keep pitch/roll level while turning, with a pitch-axis bias; Kalman also learns it.
for mode in [Fusion.Mode.complementary, .kalman] {
    var f = Fusion(bias: .zero)
    f.setMode(mode)
    var truth = simd_quatd.identity
    var tick: UInt32 = 0
    let bias = SIMD3(0.5, 0, 0) * deg
    let motion: (Double) -> SIMD3<Double> = { t in SIMD3(0.2 * sin(1.3 * t), 0.8 * sin(0.7 * t), 0.1 * cos(0.9 * t)) }
    simulate(&f, seconds: 120, bias: bias, noise: 0.3, rate: motion, truth: &truth, tick: &tick)
    let err = tilt(f.q, truth) / deg
    check(err < 1.5 && err.isFinite, String(format: "%@: tilt error %.2f° after 2 min of motion", mode.rawValue, err))
    if mode == .kalman {
        check(abs(f.bias.x - bias.x) < 0.15 * deg, String(format: "kalman: pitch-axis bias learned while moving (%.3f vs %.3f °/s)", f.bias.x / deg, bias.x / deg))
    }
}

// 3. Strict gravity rejection: a sustained 3 m/s² forward acceleration doesn't tilt the estimate much.
for strict in [false, true] {
    var f = Fusion(bias: .zero)
    f.strictAccel = strict
    var tick: UInt32 = 0
    for i in 0..<2500 { // 5 s still, then 2 s accelerating
        tick &+= 20
        let acc = i < 1500 ? g : g + SIMD3(0, 0, -3)
        f.update(acc: acc, gyro: .zero, temperature: 30, tick: tick)
    }
    print(String(format: "      strict=%@: tilt after 2 s of acceleration %.2f°", strict ? "on" : "off", tilt(f.q, .identity) / deg))
    if strict { check(tilt(f.q, .identity) < 1.0 * deg, "strict gravity rejection holds tilt under 1° while accelerating") }
}

// 4. Temperature model: slope from bins, and the fusion follows warming.
do {
    var m = TemperatureModel()
    for (t, b) in [(30.0, 0.10), (31.0, 0.12), (32.0, 0.14), (33.0, 0.16)] { m.add(temperature: t, bias: SIMD3(0, b, 0) * deg, weight: 5) }
    let s = m.slope ?? .zero
    check(abs(s.y / deg - 0.02) < 0.002, String(format: "temperature slope %.4f °/s/°C (expected 0.0200)", s.y / deg))
    let data = try! JSONEncoder().encode(m)
    let back = try! JSONDecoder().decode(TemperatureModel.self, from: data)
    check(back.slope.map { abs($0.y - s.y) < 1e-12 } == true, "temperature model survives JSON")

    var f = Fusion(bias: SIMD3(0, 0.10, 0) * deg)
    f.temperature = m
    var truth = simd_quatd.identity
    var tick: UInt32 = 0
    // Warm from 30 to 33 °C over 60 s while moving (no rest), true bias following the slope.
    var t0 = 0.0
    while t0 < 60 {
        let temp = 30 + 3 * t0 / 60
        let bias = SIMD3(0, 0.10 + 0.02 * (temp - 30), 0) * deg
        simulate(&f, seconds: 1, bias: bias, temperature: { _ in temp }, start: t0, rate: { t in SIMD3(0, 0.5 * sin(t), 0) }, truth: &truth, tick: &tick)
        t0 += 1
    }
    check(abs(f.bias.y / deg - 0.16) < 0.015, String(format: "bias tracked warming without rest: %.3f °/s (true 0.160)", f.bias.y / deg))
}

// 5. Double tap: two sharp taps detected; a fast but smooth head turn is not.
do {
    var d = TapDetector()
    var hits = 0
    var t = 0.0
    for i in 0..<1000 {
        let tap = i == 250 || i == 400 // at 0.5 s and 0.8 s
        let gyro = tap ? SIMD3(0.6, 0.2, 0) : .zero
        let acc = tap ? g + SIMD3(0, 0, 5) : g
        if d.update(gyro: gyro, acc: acc, time: t) { hits += 1 }
        t += 0.002
    }
    check(hits == 1, "double tap detected once (\(hits))")
    var e = TapDetector()
    var false_ = 0
    t = 0
    for i in 0..<1500 {
        let ramp = min(Double(i) * 0.002 / 0.15, 1) * 4 * sin(Double(i) * 0.002 * 3) // up to 4 rad/s swings
        if e.update(gyro: SIMD3(0, ramp, 0), acc: g + SIMD3(0, 0, 0.5 * sin(Double(i) * 0.01)), time: t) { false_ += 1 }
        t += 0.002
    }
    check(false_ == 0, "no tap from fast smooth head turns")
}

// 6. 1€ filter: converges on a constant, follows a fast turn closely, never NaN.
do {
    var e = OneEuroQuat()
    let target = simd_quatd(angle: 0.3, axis: SIMD3(0, 1, 0))
    var q = simd_quatd.identity
    e.reset(.identity)
    for _ in 0..<240 { q = e.filter(target, dt: 1 / 120) }
    check(shortestAngle(q, target) < 0.001, "1€ converges on a still pose")
    var lagMax = 0.0
    var truth = simd_quatd.identity
    e.reset(truth)
    for i in 0..<120 {
        truth = simd_quatd(angle: 1.5 * Double(i) / 120, axis: SIMD3(0, 1, 0)) // 1.5 rad/s turn
        q = e.filter(truth, dt: 1 / 120)
        if i > 30 { lagMax = max(lagMax, shortestAngle(q, truth)) }
    }
    check(lagMax < 2 * deg && q.vector.x.isFinite, String(format: "1€ lag during a 86 °/s turn: %.2f°", lagMax / deg))
}

// 7. AirPods calibration: tilted in the ears, 60 ms Bluetooth delay, noisy. Must finish within
//    seconds of head movement (not sit at 95%) and then match the glasses.
do {
    var history = PoseHistory(capacity: 2600)
    var cal = AirPodsCalibration()
    let X = simd_quatd(angle: 0.5, axis: simd_normalize(SIMD3(1, 0.3, 0.2))) // glasses → AirPods body
    let W = simd_quatd(angle: 1.2, axis: SIMD3(0, 1, 0)) // AirPods world → glasses world
    let lagTrue = 0.06
    var qg = simd_quatd.identity
    var t = 0.0
    var pending: [Headphones.Sample] = []
    var readyAt: Double?
    let motion: (Double) -> SIMD3<Double> = { t in SIMD3(0.9 * sin(2.1 * t), 1.6 * sin(1.3 * t + 0.4), 0.3 * sin(1.7 * t)) }
    var nextAirPods = 0.0
    var lastProgress = 0.0, progressDropped = false
    while t < 40, readyAt == nil {
        let w = motion(t)
        qg = simd_normalize(qg.extrapolated(w, 0.002))
        history.append(PoseSample(time: t, q: qg, omega: w))
        if t >= nextAirPods {
            nextAirPods += 0.04 // 25 Hz
            let noise = SIMD3(Double.random(in: -0.03...0.03), Double.random(in: -0.03...0.03), Double.random(in: -0.03...0.03))
            let bodyToWorld = W.inverse * qg * X.inverse
            // 1 in 8 samples is a glitch (a bud shifting in the ear, a Bluetooth hiccup).
            let glitch = Int.random(in: 0..<8) == 0 ? SIMD3(Double.random(in: -3...3), Double.random(in: -3...3), 0) : .zero
            pending.append(Headphones.Sample(q: bodyToWorld, rate: X.act(w) + noise + glitch, angles: .zero, time: t - lagTrue, arrival: t))
        }
        if pending.count >= 3 { // Bluetooth delivers in bursts
            let h = history
            cal.ingest(pending, glasses: { h.pose(at: $0) })
            pending.removeAll()
            if cal.progress < lastProgress { progressDropped = true }
            lastProgress = cal.progress
            if cal.ready { readyAt = t }
        }
        t += 0.002
    }
    check(readyAt.map { $0 < 12 } == true, String(format: "AirPods calibration, 1 in 8 samples glitched, finished after %.1f s of movement (lag %.0f ms, fit %.0f%%, glitches skipped %d)",
                                                    readyAt ?? -1, cal.lag * 1000, cal.fitError * 100, cal.glitches))
    check(!progressDropped, "AirPods progress bar never went backwards")
    // macOS re-centers AirPods yaw when Spatial Audio starts: a 10° jump of their world frame.
    if readyAt != nil {
        let W2 = simd_quatd(angle: 10 * deg, axis: SIMD3(0, 1, 0)) * W
        var t2 = t
        var history2 = history
        var q2 = qg
        let jumpsBefore = cal.jumps
        while t2 < t + 2 {
            let w = motion(t2)
            q2 = simd_normalize(q2.extrapolated(w, 0.002))
            history2.append(PoseSample(time: t2, q: q2, omega: w))
            if t2 >= nextAirPods {
                nextAirPods += 0.04
                let h = history2
                cal.ingest([Headphones.Sample(q: (t2 > t + 1 ? W2 : W).inverse * q2 * X.inverse, rate: X.act(w), angles: .zero,
                                              time: t2 - lagTrue, arrival: t2)], glasses: { h.pose(at: $0) })
            }
            t2 += 0.002
        }
        let s2 = Headphones.Sample(q: W2.inverse * q2 * X.inverse, rate: .zero, angles: .zero, time: t2, arrival: t2)
        let err2 = cal.pose(s2).map { shortestAngle($0, q2) } ?? .pi
        check(cal.jumps > jumpsBefore && err2 < 2 * deg,
              String(format: "AirPods 10° re-center (Spatial Audio) detected and absorbed: error %.2f°", err2 / deg))
    }
    if readyAt != nil {
        let s = Headphones.Sample(q: W.inverse * qg * X.inverse, rate: .zero, angles: .zero, time: t, arrival: t)
        let err = cal.pose(s).map { shortestAngle($0, qg) } ?? .pi
        check(err < 2 * deg, String(format: "AirPods pose matches the glasses within %.2f°", err / deg))
    }
}

print(failures == 0 ? "All tests passed" : "\(failures) test(s) failed")
exit(failures == 0 ? 0 : 1)
