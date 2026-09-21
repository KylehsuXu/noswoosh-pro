// Regression checks for the app-activation preempt. All three are *timing* measurements, because
// that is what the user sees: an instant switch lands within ~40ms of the activation, macOS's own
// follow rule takes 320ms+ to animate the same switch.
//
//   A. A user activation of an app that lives on another space is preempted. This is the case 1.8.8
//      broke: WeChat keeps a 280x380 chat window on the space you activate it *from*, so the
//      "has a window on the current space" guard stood down and the switch animated again. Needs
//      the app's *largest* window to be on another space while it also has a window on this one.
//   B. The landing activation macOS raises right after a switch of ours is not followed. Drive a
//      switch with the CLI, catch the landing, and activate immediately: our preempt must stand
//      down, or the user's switch is undone 25ms after it landed — the "flash and return".
//   C. A user activation that arrives *shortly after* a switch is still preempted. Same shape as B
//      but ~200ms later, which is what pressing two skhd bindings in a row looks like. 1.8.9's
//      first attempt at the landing guard used a 300ms window and swallowed this one, so macOS
//      animated it — the "still animates when I press quickly" report.
//
// usage: swift scripts/preempt-check.swift [multi-space-bundle-id] [single-space-bundle-id]
//   defaults: com.tencent.xinWeChat, com.mitchellh.ghostty
// The daemon under test must be running and allowed to post events (Accessibility). Needs at least
// two spaces, the first app's windows split across them, and the second app's largest window on one
// of them. B and C refuse to run rather than pass when the layout does not exercise them.

import AppKit
import Foundation

typealias SLSMainConnectionIDFn = @convention(c) () -> UInt32
typealias SLSCopyManagedDisplaySpacesFn = @convention(c) (UInt32) -> Unmanaged<CFArray>
typealias SLSCopySpacesForWindowsFn = @convention(c) (UInt32, Int32, CFArray) -> Unmanaged<CFArray>
let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)!
func sym<T>(_ name: String) -> T { unsafeBitCast(dlsym(sky, name), to: T.self) }
let SLSMainConnectionID: SLSMainConnectionIDFn = sym("SLSMainConnectionID")
let SLSCopyManagedDisplaySpaces: SLSCopyManagedDisplaySpacesFn = sym("SLSCopyManagedDisplaySpaces")
let SLSCopySpacesForWindows: SLSCopySpacesForWindowsFn = sym("SLSCopySpacesForWindows")
let cid = SLSMainConnectionID()

let cli = "/Applications/noswoosh-pro.app/Contents/MacOS/noswoosh-pro"
let multiBundle = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "com.tencent.xinWeChat"
let otherBundle = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "com.mitchellh.ghostty"

func displaySpaces() -> [UInt64] {
    let displays = SLSCopyManagedDisplaySpaces(cid).takeRetainedValue() as? [[String: Any]] ?? []
    for d in displays {
        let ids = (d["Spaces"] as? [[String: Any]] ?? []).compactMap { ($0["id64"] as? NSNumber)?.uint64Value }
        if let cs = d["Current Space"] as? [String: Any], let cur = (cs["id64"] as? NSNumber)?.uint64Value {
            return [cur] + ids.filter { $0 != cur }
        }
    }
    return []
}
func currentSpace() -> UInt64 { displaySpaces().first ?? 0 }

/// (space, area) for every ordinary window of the app.
func windows(of pid: pid_t) -> [(space: UInt64, area: Double)] {
    let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    var out: [(UInt64, Double)] = []
    for w in list {
        guard (w[kCGWindowLayer as String] as? Int) == 0,
              (w[kCGWindowOwnerPID as String] as? Int) == Int(pid),
              let id = w[kCGWindowNumber as String] as? UInt32 else { continue }
        guard let space = (SLSCopySpacesForWindows(cid, 0x7, [id] as CFArray)
            .takeRetainedValue() as? [NSNumber])?.first?.uint64Value else { continue }
        let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
        out.append((space, ((b["Width"] as? Double) ?? 0) * ((b["Height"] as? Double) ?? 0)))
    }
    return out
}
func mainSpace(of pid: pid_t) -> UInt64? { windows(of: pid).max { $0.area < $1.area }?.space }

func app(_ bundleID: String) -> NSRunningApplication? {
    NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleID }
}
func activate(_ bundleID: String) {
    if let a = app(bundleID) { _ = a.activate() } else { _ = NSWorkspace.shared.launchApplication(bundleID) }
}
func runCLI(_ arg: String) { _ = try? Process.run(URL(fileURLWithPath: cli), arguments: [arg]) }
func settle(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }

/// Get onto `space` (one CLI step at a time, both directions tried).
@discardableResult
func ensureOn(_ space: UInt64) -> Bool {
    for _ in 0..<4 {
        if currentSpace() == space { return true }
        let before = currentSpace()
        runCLI("right"); settle(1.0)
        if currentSpace() == before { runCLI("left"); settle(1.0) }
    }
    return currentSpace() == space
}

/// Milliseconds until the current space becomes `target` (nil = never within `limit`).
func msUntilSpace(_ target: UInt64, limit: Double) -> Double? {
    let t0 = Date()
    while Date().timeIntervalSince(t0) < limit {
        if currentSpace() == target { return Date().timeIntervalSince(t0) * 1000 }
        usleep(2000)
    }
    return nil
}

/// Post a CLI step and return as soon as the space moves, so a caller can act *inside* the landing
/// window. Returns (from, to); `to` == `from` means the step did not move us.
func stepCatchingLanding() -> (from: UInt64, to: UInt64) {
    let from = currentSpace()
    runCLI("right")
    var moved: UInt64 = from
    let t0 = Date()
    while Date().timeIntervalSince(t0) < 1.5 {
        if currentSpace() != from { moved = currentSpace(); break }
        usleep(2000)
    }
    if moved == from {
        runCLI("left")
        let t1 = Date()
        while Date().timeIntervalSince(t1) < 1.5 {
            if currentSpace() != from { moved = currentSpace(); break }
            usleep(2000)
        }
    }
    return (from, moved)
}

var failures = 0
func report(_ name: String, _ ok: Bool, _ detail: String) {
    print("\(ok ? "PASS" : "FAIL")  \(name): \(detail)")
    if !ok { failures += 1 }
}

guard displaySpaces().count >= 2 else { print("SKIP  needs at least two spaces"); exit(2) }
guard let multi = app(multiBundle) else { print("SKIP  \(multiBundle) is not running"); exit(2) }
guard let other = app(otherBundle) else { print("SKIP  \(otherBundle) is not running"); exit(2) }
guard let multiMain = mainSpace(of: multi.processIdentifier) else {
    print("SKIP  \(multiBundle) has no window on any space"); exit(2)
}
let otherMain = mainSpace(of: other.processIdentifier)

// ---- A: a user activation of a multi-space app is preempted ---------------------------------
if currentSpace() == multiMain {
    runCLI("left"); settle(1.0)
    if currentSpace() == multiMain { runCLI("right"); settle(1.0) }
}
let startA = currentSpace()
guard startA != multiMain, windows(of: multi.processIdentifier).contains(where: { $0.space == startA }) else {
    print("SKIP  layout does not exercise A: need \(multiBundle) with a window on the current space \(startA) and its largest window on another one (now \(multiMain))")
    exit(2)
}
activate(multiBundle)
let movedA = msUntilSpace(multiMain, limit: 1.5)
report("A user activation is preempted",
       movedA != nil && movedA! < 150,
       "space \(startA) -> \(multiMain) in \(movedA.map { "\(Int($0))ms" } ?? ">1500ms") (instant < 150ms; macOS's own drag is 320ms+)")

// ---- B / C: the landing window, from both sides ---------------------------------------------
guard let otherMain else { print("SKIP  \(otherBundle) has no window on any space"); exit(2) }
// We need to *leave* the other app's main-window space, then activate it: that is the shape of both
// a landing activation (immediately) and a user's next hotkey press (later).
ensureOn(otherMain)
let awayFrom = currentSpace()

func activateAfterSwitch(delayAfterLanding: Double) -> (from: UInt64, to: UInt64, msBack: Double?) {
    let (from, to) = stepCatchingLanding()
    guard to != from else { return (from, to, nil) }
    if delayAfterLanding > 0 { settle(delayAfterLanding) }
    activate(otherBundle)
    return (from, to, msUntilSpace(from, limit: 1.5))
}

// B: activate 40ms after the landing is visible — inside the ~26-80ms echo window, but past the
// commit, so the park path cannot mask a preempt that should not have fired.
ensureOn(otherMain)
let b = activateAfterSwitch(delayAfterLanding: 0.04)
report("B landing activation is not followed",
       b.from == otherMain && b.to != b.from && (b.msBack == nil || b.msBack! > 300),
       "space \(b.from) -> \(b.to), then back to \(b.from) in \(b.msBack.map { "\(Int($0))ms" } ?? ">1500ms") (our post would be < 150ms; macOS's own drag 320ms+ is not ours)")
settle(0.8)

// C: the same activation ~200ms after the landing — the user pressing the next hotkey.
ensureOn(otherMain)
let c = activateAfterSwitch(delayAfterLanding: 0.2)
report("C a later activation is still preempted",
       c.from == otherMain && c.to != c.from && c.msBack != nil && c.msBack! < 150,
       "space \(c.from) -> \(c.to), then back to \(c.from) in \(c.msBack.map { "\(Int($0))ms" } ?? ">1500ms") (a 300ms landing window swallowed this in 1.8.9's first attempt)")

// Leave the user where we found them.
if currentSpace() != awayFrom { runCLI("left"); settle(0.8) }
print(failures == 0 ? "OK" : "\(failures) check(s) failed")
exit(failures == 0 ? 0 : 1)
