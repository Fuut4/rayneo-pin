//   RayNeoPin.app              menu bar app (eyeglasses icon)
//   RayNeoPin --imu-test       print orientation to the terminal, no rendering
//   RayNeoPin --check-permission  exit 0 if Screen Recording is granted (used for auto-relaunch)

import AppKit
import CoreMotion
import simd

if CommandLine.arguments.contains("--check-permission") {
    exit(CGPreflightScreenCaptureAccess() ? 0 : 1)
} else if CommandLine.arguments.contains("--imu-test") {
    setvbuf(stdout, nil, _IOLBF, 0)
    let imu = IMU(savedBias: Settings().gyroBias)
    imu.start()
    let headphones = Headphones()
    headphones.start()
    print("Reading IMU — keep still ~1 s to calibrate. Ctrl+C to quit.")
    print("AirPods motion available: \(headphones.isAvailable), authorization: \(CMHeadphoneMotionManager.authorizationStatus().rawValue) (0 undetermined, 1 restricted, 2 denied, 3 authorized)")
    var anchor: simd_quatd?
    Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
        let s = imu.snapshot()
        guard s.connected else { print("no glasses"); return }
        guard s.ready else { print("calibrating… \(s.state)"); return }
        if anchor == nil { let yp = s.q.yawPitch; anchor = .yawPitch(yp.yaw, yp.pitch) }
        let rel = anchor!.inverse * s.q
        let yp = rel.yawPitch
        let up = rel.inverse.act(SIMD3(0, 1, 0))
        let b = imu.bias * 180 / .pi
        let airpods = headphones.latestYaw().map { String(format: "%+7.1f°", degrees($0)) } ?? "  —"
        print(String(format: "yaw %+7.1f°  pitch %+6.1f°  roll %+6.1f°   bias %+.3f %+.3f %+.3f °/s  AirPods yaw %@  (%d samples)",
                     degrees(yp.yaw), degrees(yp.pitch), degrees(atan2(up.x, up.y)), b.x, b.y, b.z, airpods, imu.samples))
    }
    RunLoop.main.run()
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
