// Probe: dump raw HID input reports from RayNeo glasses (VID 0x1BBB / PID 0xAF50).
// Build: swiftc -O tools/probe.swift -o probe
// Usage: ./probe [seconds] [--enable]
import Foundation
import IOKit.hid

let args = CommandLine.arguments
let seconds = Double(args.dropFirst().first(where: { Double($0) != nil }) ?? "3") ?? 3
let sendEnable = args.contains("--enable")

let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(mgr, [kIOHIDVendorIDKey: 0x1BBB, kIOHIDProductIDKey: 0xAF50,
                                     kIOHIDPrimaryUsagePageKey: 0xFF00] as CFDictionary)
let r = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
print("open:", String(format: "0x%08x", r))
guard let devs = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>, let dev = devs.first else { print("no device"); exit(1) }

var count = 0
let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
IOHIDDeviceRegisterInputReportCallback(dev, buf, 64, { _, _, _, _, _, report, len in
    count += 1
    if count <= 12 || count % 250 == 0 {
        let hex = (0..<len).map { String(format: "%02x", report[$0]) }.joined(separator: " ")
        print("#\(count) len=\(len): \(hex)")
    }
}, nil)
IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

if sendEnable {
    var cmd = [UInt8](repeating: 0, count: 64); cmd[0] = 0x66; cmd[1] = 0x01; cmd[2] = 0x00
    let w = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0, cmd, 64)
    print("enable cmd:", String(format: "0x%08x", w))
}
CFRunLoopRunInMode(.defaultMode, seconds, false)
print("total reports in \(seconds)s: \(count)")
