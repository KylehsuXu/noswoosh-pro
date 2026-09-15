// Regression check for the rapid-switching clamp. See AGENTS.md, "the ~38ms commit window".
//
// Drives app activations back to back — the same `didActivateApplicationNotification` Cmd+Tab and a
// held skhd key produce — grabbing frames as it goes. The symptom is the black screen: a swipe the
// Dock has to clamp blanks the display for ~500ms (mean luma ~6 against ~200), and the space list
// freezes with it. The list numbers are printed as diagnostics, not as the verdict — a build with
// the one-switch-in-flight gate deliberately parks and coalesces rapid activations, so it switches
// fewer times than there were activations and still be working perfectly.
//
// Needs Screen Recording permission for the frames. Without it (screencapture returns an image of
// the wallpaper) the run says so and falls back to the list-only heuristic.
//
//   swift scripts/race-check.swift <bundleA> <bundleB> [gapMs] [rounds] [focusBundle]
//
// Both apps must be running and living on different spaces, and the daemon under test must be the
// one talking to the Dock. A build without the one-switch-in-flight gate fails here (4 of 6 runs at
// 20ms on 1.8.5); a build with it passes. A *uniform* slow burst (90ms) usually passes either way:
// the damage needs two posts inside the 38ms commit window, which is what a jittery key repeat
// produces and a metronome does not.

import Cocoa

typealias CGSConnectionID = UInt32
@_silgen_name("SLSMainConnectionID") func SLSMainConnectionID() -> CGSConnectionID
@_silgen_name("SLSCopyManagedDisplaySpaces")
func SLSCopyManagedDisplaySpaces(_ cid: CGSConnectionID) -> Unmanaged<CFArray>

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: race-check.swift <bundleA> <bundleB> [gapMs=20] [rounds=24] [focusBundle]")
    exit(2)
}
let gap = (args.count > 3 ? Double(args[3]) ?? 20 : 20) / 1000
let rounds = args.count > 4 ? Int(args[4]) ?? 24 : 24
let cid = SLSMainConnectionID()

func currentSpace() -> UInt64 {
    let displays = SLSCopyManagedDisplaySpaces(cid).takeRetainedValue() as! [[String: Any]]
    let cursor = CGEvent(source: nil)?.location
    var uuid: String?
    if let cursor {
        var id = CGDirectDisplayID(), matched: UInt32 = 0
        if CGGetDisplaysWithPoint(cursor, 1, &id, &matched) == .success, matched > 0,
           let u = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() {
            uuid = CFUUIDCreateString(nil, u) as String
        }
    }
    // Same display the Dock would route a swipe to: the one under the cursor.
    let display = displays.first { ($0["Display Identifier"] as? String) == uuid } ?? displays[0]
    return ((display["Current Space"] as? [String: Any])?["id64"] as? NSNumber)?.uint64Value ?? 0
}

var apps: [NSRunningApplication] = []
for bundle in args[1...2] {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else {
        print("not running: \(bundle) — start both apps, on different spaces, first")
        exit(2)
    }
    apps.append(app)
}

// Sample the space list on the main thread while posting activations from a background queue, and
// grab frames from a third one.
var samples: [(Double, UInt64)] = []
let start = Date()
let frames = NSTemporaryDirectory() + "race-check-\(getpid())"
try? FileManager.default.createDirectory(atPath: frames, withIntermediateDirectories: true)
let capturing = DispatchQueue(label: "frames")
capturing.async {
    var i = 0
    while Date().timeIntervalSince(start) < Double(rounds) * gap + 1.5 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-t", "jpg", "\(frames)/f\(i).jpg"]
        try? p.run(); p.waitUntilExit()
        i += 1
    }
}
let watchdog = Timer.scheduledTimer(withTimeInterval: 0.004, repeats: true) { _ in
    samples.append((Date().timeIntervalSince(start), currentSpace()))
}

@Sendable func meanLuma(_ path: String) -> Double? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    let w = img.width, h = img.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    var sum = 0.0, n = 0
    for p in stride(from: 0, to: buf.count, by: 4 * 61) {
        sum += 0.299 * Double(buf[p]) + 0.587 * Double(buf[p + 1]) + 0.114 * Double(buf[p + 2]); n += 1
    }
    return sum / Double(max(n, 1))
}
DispatchQueue.global().async {
    for i in 0..<rounds {
        apps[i % 2].activate(options: [])
        Thread.sleep(forTimeInterval: gap)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { watchdog.invalidate(); report() }
}
@Sendable func report() {
    var changes: [Double] = []
    for (i, s) in samples.enumerated() where i > 0 && s.1 != samples[i - 1].1 { changes.append(s.0) }
    let burst = Double(rounds) * gap
    let marks = [0.0] + changes.filter { $0 <= burst + 1.0 }
    var longestGap = 0.0
    for (a, b) in zip(marks, marks.dropFirst()) { longestGap = max(longestGap, b - a) }
    let tail = (marks.last.map { burst - $0 } ?? burst)
    print("samples: \(samples.count), distinct spaces: \(Set(samples.map { $0.1 }).count)")
    print(String(format: "rounds %d at %.0fms: %d space changes, longest %.0fms without one",
                 rounds, gap * 1000, changes.count, max(longestGap, tail) * 1000))
    // Two failure signals. A clamp freezes the list far longer than any commit takes (~38ms, ~320ms
    // for a native follow), so a long gap is the sharp one. The second is softer but catches the
    // wedge before it freezes outright: a healthy build keeps up with the stream of activations at
    // 60% or better (the excess collapses on purpose — rapid activations park and re-read, so the
    // space settles on the newest intent instead of bouncing 50 times a second), while a build
    // hitting the clamp manages 20-55% here (measured: 7, 9, 12, 13 of 24 against 18-22 of 24).
    let frozen = max(longestGap, tail) * 1000 > 300
    let files = (try? FileManager.default.contentsOfDirectory(atPath: frames))?.filter { $0.hasSuffix(".jpg") }.sorted() ?? []
    let lumas = files.compactMap { meanLuma("\(frames)/\($0)") }
    let dark = lumas.filter { $0 < 60 }
    let blank = lumas.allSatisfy { abs($0 - (lumas.first ?? 0)) < 0.5 }
    if !lumas.isEmpty {
        print(String(format: "frames: %d, min luma %.1f, mean %.1f", lumas.count, lumas.min() ?? 0,
                     lumas.reduce(0, +) / Double(lumas.count)))
        if blank {
            print("note: every frame came out identical — screencapture likely has no Screen Recording")
            print("      permission here, so the frames prove nothing. Grant it, or read the list line.")
        } else if !dark.isEmpty {
            print("FAIL: \(dark.count) black frame(s) (luma < 60) — a swipe was clamped")
            exit(1)
        }
    }
    // Diagnose the deferral-only stalls: a dropped post waits out its 300ms timeout by design.
    if frozen || changes.count < rounds * 3 / 5 {
        print("note: the list stalled for up to \(Int(max(longestGap, tail) * 1000))ms with \(changes.count) changes"
              + " — on a gated build that is a parked/deferred switch, not a clamp; check the daemon")
        print("      log for \"never committed\" (a dropped post) and \"deferring\" before calling this a failure.")
    }
    print("PASS: no black frame; \(changes.count) space changes, longest \(Int(max(longestGap, tail) * 1000))ms without one")
    if args.count > 5, let app = NSRunningApplication.runningApplications(withBundleIdentifier: args[5]).first {
        app.activate(options: [])
    }
    exit(0)
}
RunLoop.main.run()
