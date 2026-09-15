import Cocoa
import Carbon.HIToolbox
import ApplicationServices

// noswoosh-pro — instant macOS space switching, forked from mmathys/noswoosh.
//
// Upstream switches spaces instantly (Ctrl+arrow, 3-finger swipe). This fork adds one
// thing: activating an app whose window lives on another space — Cmd+Tab, a Dock icon
// click, any `open -b` hotkey — arrives instantly too, by preempting that space before
// the app orders its window in. See the app-activation preempt section below.
//
// noswoosh — instant macOS space switching (verified on macOS 26 and 27, Apple Silicon).
//
//   noswoosh            daemon: Ctrl+Left/Right OR a 3-finger swipe switch
//                       spaces instantly (no animation)
//   noswoosh setup      one-time system config (see below), needs no sudo
//   noswoosh teardown   undo the system config
//   noswoosh left       switch one space left and exit
//   noswoosh right      switch one space right and exit
//   noswoosh list       print current space / count
//   noswoosh version    print version
//
// How it works: switching is a synthetic Dock-swipe gesture (technique from
// jurplel/InstantSpaceSwitcher, MIT) with near-zero progress and high velocity —
// it runs through the Dock's own pipeline (state stays consistent: the Dock is
// the sole authoritative owner of the Spaces model) but the animation has no
// distance to travel, so it is instant. Two input sources feed one switch core:
// a Ctrl+arrow hotkey, and an event tap that intercepts real 3-finger
// horizontal swipes and replaces them with the instant switch. Posting events
// requires Accessibility permission.
//
// Requires macOS 26.6+ on the 26 line: 26.0–26.5 has a WindowServer bug that
// drops the destination space's compositing surfaces on zero-travel switches
// (blank landings). No instant workaround exists from outside the Dock; the
// full investigation and every attempted mitigation are in GitHub issue #1.
//
// macOS 27 (Tahoe's successor) added validation: synthetic Dock swipes must
// carry a serialized raw IOHID queue payload in CGEvent field 4205, and each
// DockControl event must be paired with a companion gesture event. Without this
// the Dock silently ignores the event. The macOS 27 payload layout is
// reverse-engineered from joshuarli/iss (ISC). Everything 27-specific is gated
// behind `needsAugmentation`, so the verified macOS 26 path is untouched.
//
// `noswoosh setup` configures one thing: the system's animated Ctrl+arrow
// shortcuts (symbolic hotkeys 79/81) must be disabled or they consume the key
// combo first. Setup disables them live via SkyLight (defaults alone doesn't
// affect the running session) AND persists them in com.apple.symbolichotkeys
// for future logins. (For migration it also clears the legacy
// com.apple.dock workspaces-auto-swoosh override older versions set — see the
// yank guard below and the setup case for why we no longer touch it.)
//
// Build: swiftc noswoosh.swift -O -o noswoosh \
//          -F /System/Library/PrivateFrameworks -framework SkyLight

let noswooshVersion = "1.8.6"

// MARK: - Setup / teardown (system configuration, all user-level)

func runTool(_ path: String, _ arguments: [String]) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    } catch {
        return false
    }
}

// hotkey 79 = "move left a space" (ctrl+left, key code 123),
// hotkey 81 = "move right a space" (ctrl+right, key code 124)
func setCtrlArrowShortcuts(enabled: Bool) {
    // Live (WindowServer) state — resolved via dlsym; writing defaults alone
    // does not affect the running login session.
    typealias SetHotKeyFn = @convention(c) (Int32, Bool) -> Int32
    if let skylight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
       let sym = dlsym(skylight, "SLSSetSymbolicHotKeyEnabled") {
        let setEnabled = unsafeBitCast(sym, to: SetHotKeyFn.self)
        _ = setEnabled(79, enabled)
        _ = setEnabled(81, enabled)
    }
    // Persisted state for future logins.
    for (hotKey, keyCode) in [(79, 123), (81, 124)] {
        let entry = "{enabled = \(enabled ? 1 : 0); value = { parameters = (65535, \(keyCode), 8650752); type = standard; };}"
        _ = runTool("/usr/bin/defaults", ["write", "com.apple.symbolichotkeys",
                                          "AppleSymbolicHotKeys", "-dict-add",
                                          String(hotKey), entry])
    }
}

// MARK: - Private SkyLight reads (space bookkeeping only)

typealias CGSConnectionID = UInt32

@_silgen_name("SLSMainConnectionID")
func SLSMainConnectionID() -> CGSConnectionID

@_silgen_name("SLSCopyManagedDisplaySpaces")
func SLSCopyManagedDisplaySpaces(_ cid: CGSConnectionID) -> Unmanaged<CFArray>

@_silgen_name("SLSGetActiveSpace")
func SLSGetActiveSpace(_ cid: CGSConnectionID) -> UInt64

// Returns the union of spaces the given windows live on (mask 0x7 = all).
@_silgen_name("SLSCopySpacesForWindows")
func SLSCopySpacesForWindows(_ cid: CGSConnectionID, _ mask: Int32,
                             _ windows: CFArray) -> Unmanaged<CFArray>

@_silgen_name("SLSSpaceSetFrontPSN")
func SLSSpaceSetFrontPSN(_ cid: CGSConnectionID, _ sid: UInt64,
                         _ psn: ProcessSerialNumber) -> Int32

let cid = SLSMainConnectionID()

struct SpaceInfo {
    let ids: [UInt64]
    let currentIndex: Int
    // "Display Identifier" of the display this list belongs to, so a prediction
    // made on one display is never applied to another's list.
    let display: String?
}

// UUID string of the display under the mouse cursor, in the same form as the
// "Display Identifier" values in SLSCopyManagedDisplaySpaces. A CGEvent's
// location is already in global CG coordinates, so this needs no flip from
// Cocoa's bottom-left origin.
func cursorDisplayUUID() -> String? {
    guard let location = CGEvent(source: nil)?.location else { return nil }
    var displayID = CGDirectDisplayID()
    var matched: UInt32 = 0
    guard CGGetDisplaysWithPoint(location, 1, &displayID, &matched) == .success,
          matched > 0,
          let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue()
    else { return nil }
    return CFUUIDCreateString(nil, uuid) as String
}

// Space list for the display the switch will actually land on, plus that
// display's current index in it. The list includes fullscreen spaces, which the
// swipe traverses too.
//
// The Dock routes a Dock-swipe to the display under the *mouse cursor*, not the
// one holding keyboard focus — native Ctrl+arrow routes the same way, so merely
// hovering a display makes it the target. SLSGetActiveSpace tracks keyboard
// focus instead, so clamping against it guards the wrong list whenever cursor
// and focus sit on different displays: it either deadens a legal keypress or
// lets through a swipe that rubber-bands. See issue #3.
func spaceInfo() -> SpaceInfo? {
    let displays = SLSCopyManagedDisplaySpaces(cid).takeRetainedValue() as! [[String: Any]]

    func info(_ display: [String: Any], current: UInt64) -> SpaceInfo? {
        guard let spaces = display["Spaces"] as? [[String: Any]] else { return nil }
        let ids = spaces.compactMap { ($0["id64"] as? NSNumber)?.uint64Value }
        guard let idx = ids.firstIndex(of: current) else { return nil }
        return SpaceInfo(ids: ids, currentIndex: idx,
                         display: display["Display Identifier"] as? String)
    }

    // Multi-display: ask the cursor's display for its own current space. Each
    // display dict already carries one, so this costs no extra private call.
    if displays.count > 1, let uuid = cursorDisplayUUID(),
       let display = displays.first(where: { ($0["Display Identifier"] as? String) == uuid }),
       let current = (display["Current Space"] as? [String: Any])?["id64"] as? NSNumber,
       let result = info(display, current: current.uint64Value) {
        return result
    }

    // One managed display — a single screen, or "Displays have separate Spaces"
    // off, where every screen shares one list — plus the fallback for a failed
    // cursor lookup. Byte-identical to the behavior before the fix.
    let active = SLSGetActiveSpace(cid)
    for display in displays {
        if let result = info(display, current: active) { return result }
    }
    return nil
}

// MARK: - macOS version gate

// Major version of the running OS — not the build SDK — or 0 if it can't be read.
// Two gates key off this (the IOHID payload below and the yank guard); keep it one
// read so they can't disagree.
func macOSMajorVersion() -> Int {
    var buf = [CChar](repeating: 0, count: 32)
    var size = buf.count
    guard sysctlbyname("kern.osproductversion", &buf, &size, nil, 0) == 0,
          let major = Int(String(cString: buf).split(separator: ".").first ?? "") else {
        return 0
    }
    return major
}
let macOSMajor = macOSMajorVersion()

// macOS 27+ validates synthetic Dock swipes against a serialized IOHID payload.
// NOSWOOSH_FORCE_AUGMENT=0/1 overrides for testing without a rebuild.
func computeNeedsAugmentation() -> Bool {
    if let force = ProcessInfo.processInfo.environment["NOSWOOSH_FORCE_AUGMENT"] {
        return force == "1"
    }
    return macOSMajor >= 27
}
let needsAugmentation = computeNeedsAugmentation()

// MARK: - Synthetic Dock-swipe gesture (undocumented CGEventFields)

func field(_ n: UInt32) -> CGEventField { unsafeBitCast(n, to: CGEventField.self) }
let fieldCGSEventType   = field(55)
let fieldGestureHIDType = field(110)
let fieldSwipeMask      = field(115)   // 27 payload
let fieldSwipeMotion    = field(123)
let fieldSwipeProgress  = field(124)
let fieldSwipePositionX = field(125)   // 27 payload
let fieldSwipePositionY = field(126)   // 27 payload
let fieldSwipeVelocityX = field(129)
let fieldSwipeVelocityY = field(130)
let fieldGesturePhase   = field(132)

let kCGSEventGesture: Int64 = 29
let kCGSEventDockControl: Int64 = 30
let kIOHIDEventTypeDockSwipe: Int64 = 23
let kCGGestureMotionHorizontal: Int64 = 1
let kRawIOHIDPayloadTag: Int = 4205    // 0x106D — CGEvent field carrying the blob
let gestureVelocity = 2000.0

enum GesturePhase: Int64 { case began = 1, changed = 2, ended = 4, cancelled = 8 }

// Synthetic events we post re-enter our own event tap; both paths tag them so
// the tap lets them straight back out. A tag travels with the event, so it also
// works across processes — which a counter could not, and that was #8: a running
// daemon intercepted the CLI's events and moved the wrong way.

// MARK: pre-27 path (macOS 26) — bare Dock-swipe, near-zero progress

// This path is correct on macOS 26.6+; on 26.0–26.5 WindowServer drops the
// destination's surfaces at commit (see the header note and issue #1, which
// also records the workarounds that were tried and rejected).

// Synthetic events identify themselves to our own event tap via this tag in
// the user-data field, so the tap passes them through instead of intercepting
// them. Real trackpad gestures carry 0 there.
let noswooshEventTag: Int64 = 0x4E53_5753 // 'NSWS'

func postDockSwipe(_ phase: GesturePhase, right: Bool) {
    guard let ev = CGEvent(source: nil) else { return }
    // Near-zero progress commits the switch with nothing left to animate.
    // NOTE: not FLT_TRUE_MIN — that subnormal flushes to zero (sign lost) in
    // the event pipeline on Apple Silicon, breaking direction; 1e-4 survives.
    let progress = 1e-4 * (right ? 1 : -1)
    let velocity = gestureVelocity * (right ? 1 : -1)
    ev.setIntegerValueField(fieldCGSEventType, value: kCGSEventDockControl)
    ev.setIntegerValueField(fieldGestureHIDType, value: kIOHIDEventTypeDockSwipe)
    ev.setIntegerValueField(fieldGesturePhase, value: phase.rawValue)
    ev.setDoubleValueField(fieldSwipeProgress, value: progress)
    ev.setIntegerValueField(fieldSwipeMotion, value: kCGGestureMotionHorizontal)
    ev.setDoubleValueField(fieldSwipeVelocityX, value: velocity)
    ev.setDoubleValueField(fieldSwipeVelocityY, value: velocity)
    ev.setIntegerValueField(.eventSourceUserData, value: noswooshEventTag)
    ev.post(tap: .cgSessionEventTap)
}

// MARK: macOS 27+ path — IOHID payload + companion pairs

func fixed1616(_ v: Double) -> Int32 {
    let f = Int32(truncatingIfNeeded: Int64(v * 65536.0))
    if f == 0 && v != 0 { return v > 0 ? 1 : -1 }
    return f
}

// Little-endian byte buffer helpers for the packed IOHID structs.
extension Array where Element == UInt8 {
    mutating func le(_ v: UInt16) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    mutating func le(_ v: UInt32) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    mutating func le(_ v: UInt64) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    mutating func le(_ v: Int32)  { le(UInt32(bitPattern: v)) }
}

// Serialized IOHID queue payload macOS 27 validates the synthetic swipe against:
// a queue header, a fluid-touch gesture record, and (on motion/end) a velocity
// record. Layout reverse-engineered from joshuarli/iss.
func generateIOHIDPayload(_ ev: CGEvent) -> [UInt8] {
    let phase   = ev.getIntegerValueField(fieldGesturePhase)
    let motion  = ev.getIntegerValueField(fieldSwipeMotion)
    let progress = ev.getDoubleValueField(fieldSwipeProgress)
    let posX    = ev.getDoubleValueField(fieldSwipePositionX)
    let posY    = ev.getDoubleValueField(fieldSwipePositionY)
    let velX    = ev.getDoubleValueField(fieldSwipeVelocityX)
    let velY    = ev.getDoubleValueField(fieldSwipeVelocityY)
    let mask    = ev.getIntegerValueField(fieldSwipeMask)
    // The velocity record is required on macOS 27 (dropping it entirely stops the
    // switch), even when the velocities are zero on the non-ended phases.
    let includeVelocity = velX != 0 || velY != 0 || phase == GesturePhase.ended.rawValue

    var p = [UInt8]()
    // IOHIDSystemQueueElementHeader (28 bytes)
    let ts = ev.timestamp
    p.le(ts != 0 ? ts : mach_absolute_time())   // timestamp
    p.le(UInt64(0))                             // sender_id
    p.le(UInt32(0))                             // options
    p.le(UInt32(0))                             // attribute_length
    p.le(UInt32(includeVelocity ? 2 : 1))       // event_count
    // IOHIDFluidTouchGestureData (40 bytes): 16-byte base + fields
    p.le(UInt32(40))                            // base.size
    p.le(UInt32(23))                            // base.type = fluid-touch gesture
    p.le(UInt32((UInt32(truncatingIfNeeded: phase) & 0xFF) << 24)) // base.options
    p.append(0); p.append(0); p.append(0); p.append(0)            // base.depth + reserved[3]
    p.le(fixed1616(posX))                       // position_x
    p.le(fixed1616(posY))                       // position_y
    p.le(Int32(0))                              // position_z
    p.le(UInt32(truncatingIfNeeded: mask))      // swipe_mask
    p.le(UInt16(truncatingIfNeeded: motion))    // gesture_motion
    p.le(UInt16(3))                             // gesture_flavor = Dock primary
    p.le(fixed1616(progress))                   // swipe_progress
    if includeVelocity {
        // IOHIDVelocityEventData (28 bytes): 16-byte base + 3 fixed velocities
        p.le(UInt32(28))                        // base.size
        p.le(UInt32(9))                         // base.type = velocity
        p.le(UInt32(0))                         // base.options
        p.append(1); p.append(0); p.append(0); p.append(0)       // base.depth = 1 + reserved
        p.le(fixed1616(velX))                   // velocity_x
        p.le(fixed1616(velY))                   // velocity_y
        p.le(Int32(0))                          // velocity_z
    }
    return p
}

// Round-trip the event through its serialized form to append the raw IOHID
// payload under field 4205, which the plain setters cannot write.
func augment(_ ev: CGEvent) -> CGEvent? {
    guard let cf = ev.data else { return nil }
    var bytes = [UInt8](cf as Data)
    // Serialized-event format must be version 2 (header 00 00 00 02).
    guard bytes.count >= 4, bytes[0] == 0, bytes[1] == 0, bytes[2] == 0, bytes[3] == 2 else { return nil }
    let payload = generateIOHIDPayload(ev)
    let len = payload.count
    bytes.append(UInt8((len >> 8) & 0xFF))
    bytes.append(UInt8(len & 0xFF))
    bytes.append(UInt8((kRawIOHIDPayloadTag >> 8) & 0xFF))
    bytes.append(UInt8(kRawIOHIDPayloadTag & 0xFF))
    bytes.append(contentsOf: payload)
    return CGEvent(withDataAllocator: nil, data: Data(bytes) as CFData)
}

func makeAugmentedDockEvent(_ phase: GesturePhase, right: Bool) -> CGEvent? {
    guard let ev = CGEvent(source: nil) else { return nil }
    ev.setIntegerValueField(fieldCGSEventType, value: kCGSEventDockControl)
    ev.setIntegerValueField(fieldGestureHIDType, value: kIOHIDEventTypeDockSwipe)
    ev.setIntegerValueField(fieldGesturePhase, value: phase.rawValue)
    // Near-zero progress, same as the pre-27 path and for the same reason: it
    // commits the switch with nothing left to animate. This path used full travel
    // (±1.0) through 1.7.0, which visibly slid on 27 — the switch was correct but
    // not instant, defeating the point. The ±9999 fling on .ended is what commits
    // it, so the magnitude here can be ~0 without losing the switch; only the sign
    // matters. Not FLT_TRUE_MIN (flushes to zero on Apple Silicon, losing the sign)
    // and not 0 either — `fixed1616` would serialize it as 0 in the IOHID payload.
    // On the 27 path direction is inverted: rightward = negative progress.
    ev.setDoubleValueField(fieldSwipeProgress, value: right ? -1e-4 : 1e-4)
    ev.setIntegerValueField(fieldSwipeMotion, value: kCGGestureMotionHorizontal)
    ev.setDoubleValueField(fieldSwipePositionX, value: 0.1)
    // A strong "fling" velocity on the terminal phase is what commits the switch.
    if phase == .ended {
        ev.setDoubleValueField(fieldSwipeVelocityX, value: right ? -9999.0 : 9999.0)
    }
    return ev
}

// Post a DockControl event paired with its companion gesture event.
func postPair(_ dock: CGEvent) {
    guard let companion = CGEvent(source: nil) else { return }
    companion.setIntegerValueField(.eventSourceUserData, value: noswooshEventTag)
    companion.setIntegerValueField(fieldCGSEventType, value: kCGSEventGesture)
    dock.post(tap: .cgSessionEventTap)
    companion.post(tap: .cgSessionEventTap)
}

var postingAllowed = true

// MARK: - Switch core (both input sources call only this)

// One switch in flight at a time. A post is not committed when it is handed to the Dock:
// measured on 27.0 from this process, the Dock's own model — the per-display "Current Space"
// and SLSGetActiveSpace, which flip together — reads the new space 38ms after the post, so
// until then the list still reads the space we posted *from*. A second post inside that window
// is computed from an index the Dock has already left, and when that index is at the end of the
// list the swipe is one the Dock has to clamp. A clamped swipe is expensive: measured here at
// mean luma 201 -> 7.6 for ~500ms (a black screen), with the space list frozen while the clamps
// keep coming, every gesture already posted silently ignored, and the reads staying stale — so
// the preempt decides "already there", stands down, and macOS's own follow rule animates the
// switch. On a two-space desktop that window is *every* rapid press, because every step is a
// step to the end of the list; that is why single presses were instant and bursts went black
// and then animated.
//
// So a post happens only once the Dock's model has caught up with the previous one, and a
// request arriving before that is parked and re-evaluated from a fresh read. Nothing is ever
// posted from an index we cannot verify — neither a stale read (this gate) nor a guessed one:
// the per-display prediction that used to cover rapid presses here was removed for the same
// reason, since a stale guess posts the same unpostable direction.

// Space the in-flight post started from, or nil when nothing is in flight.
var postedFrom: UInt64?
var postedAt = Date.distantPast
// A healthy commit takes ~38ms. Past this the swipe was dropped rather than merely slow; the
// follow rule needs ~320ms to pull the same switch off natively, so giving up here still leaves
// room to re-post from a read we can trust again.
let postCommitTimeout = 0.3

// Parked requests. A relative one (Ctrl+arrow, a real swipe) accumulates as net steps — holding
// the key is a press every ~33ms on the default repeat rate and each press is one space, so
// coalescing them into "one step" would quietly cut a held key short. An app activation parks as
// its pid instead: the latest activation is what the user asked for, and re-running the whole
// preempt from a fresh read turns "that space already landed" into a no-op rather than a step.
var pendingSteps = 0
var pendingReach: pid_t?
var pendingTimer: Timer?

func listShows(_ space: UInt64) -> Bool {
    guard let info = spaceInfo(), info.currentIndex >= 0,
          info.currentIndex < info.ids.count else { return false }
    return info.ids[info.currentIndex] == space
}

// False while the Dock has not committed the last post yet: the caller must not compute a
// direction from the list until this is true. Clears the record once it has, and on the timeout
// above, so a dropped swipe cannot wedge the daemon into never posting again. An unreadable
// list counts as caught up — posting blind is what upstream always did there, and blocking
// forever would silently disable every switch.
func dockCaughtUp() -> Bool {
    guard let from = postedFrom else { return true }
    if listShows(from) {
        guard Date().timeIntervalSince(postedAt) > postCommitTimeout else { return false }
        log("switch posted \(Int(postCommitTimeout * 1000))ms ago never committed (swipe dropped)")
    }
    postedFrom = nil
    return true
}

func notePost(from space: UInt64) {
    postedFrom = space
    postedAt = Date()
}

// Debug line for the switch core itself (the preempt has `preemptTrace`). An intermittent miss on
// the Ctrl+arrow/swipe side is invisible otherwise: the space just moves natively, animated, with
// nothing recorded anywhere. NOSWOOSH_DEBUG=1.
func switchTrace(_ note: @autoclosure () -> String) {
    guard debugEnabled else { return }
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    log("\(formatter.string(from: Date())) switch: \(note())")
}

func parkStep(right: Bool) {
    pendingSteps += right ? 1 : -1
    switchTrace("parked a \(right ? "right" : "left") press (net \(pendingSteps)) — a switch of ours is still uncommitted")
    startPendingTimer()
}

func parkReach(pid: pid_t) {
    pendingReach = pid
    startPendingTimer()
}

// Apply a parked request as soon as the Dock catches up: a 20ms tick, against the ~320ms the
// follow rule would take to animate the same switch. One request per tick, deliberately: an app
// activation posts a gesture, which closes the gate again, so applying the parked steps straight
// after it would be posting into *its* commit window — the clamp this whole section exists to
// avoid, and measured as a black screen when both were parked together under a burst of swipes.
func startPendingTimer() {
    guard pendingTimer == nil else { return }
    pendingTimer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { timer in
        guard dockCaughtUp() else { return }
        if let pid = pendingReach {
            pendingReach = nil
            // The activation that parked this may have been superseded while we waited. Applying
            // it then would drag the user to the space of an app they are no longer looking at,
            // and the newer activation — already satisfied where they are — would fight it (its
            // window orders in on its own space, so the follow rule pulls them straight back,
            // animated). Same guard the old retry used for the same reason.
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
               let app = NSRunningApplication(processIdentifier: pid) {
                preemptAppActivationSpace(app)
            }
            if pendingSteps == 0 { timer.invalidate(); pendingTimer = nil }
            return
        }
        let steps = pendingSteps
        pendingSteps = 0
        timer.invalidate(); pendingTimer = nil
        applySteps(steps)
    }
}

// One gesture per space of travel: a Dock swipe moves exactly one. Clamped to the list so a
// burst of parked presses can never ask the Dock to step off either end (the clamp this whole
// section exists to avoid), and skipped entirely at an edge, as a single press there always was.
func applySteps(_ steps: Int) {
    guard steps != 0 else { return }
    guard let info = spaceInfo(), info.currentIndex >= 0,
          info.currentIndex < info.ids.count else {
        // No list to compute a direction against (private API changed?): post one step blind,
        // which is what upstream always did there, rather than silently stopping.
        switchTrace("one step \(steps > 0 ? "right" : "left") blind (no readable space list)")
        postSwitchGesture(right: steps > 0)
        return
    }
    let clamped = max(-info.currentIndex, min(steps, info.ids.count - 1 - info.currentIndex))
    guard clamped != 0 else { return }
    switchTrace("\(abs(clamped)) step(s) \(clamped > 0 ? "right" : "left") from \(info.ids[info.currentIndex]) at list index \(info.currentIndex) of \(info.ids.count)\(clamped != steps ? " (parked \(steps) clamped to the list)" : "")")
    for _ in 0..<abs(clamped) { postSwitchGesture(right: clamped > 0) }
    notePost(from: info.ids[info.currentIndex])
}

func postSwitchGesture(right: Bool) {
    // Gate on the daemon's own posting grant: see postingAllowed.
    guard postingAllowed else { return }
    // A began/changed/ended sequence must complete; a partial one leaves the Dock
    // mid-gesture on a blank space. On the 27 path, build all three augmented
    // events up front and post nothing if any fails to build, so we never emit a
    // truncated sequence.
    if needsAugmentation {
        var events: [CGEvent] = []
        for phase in [GesturePhase.began, .changed, .ended] {
            guard let dock = makeAugmentedDockEvent(phase, right: right),
                  let aug = augment(dock) else { return }
            // Tag it like the 26 path so our tap lets it back out. Must be set
            // *after* augment(): the serialize/deserialize round-trip in there
            // drops eventSourceUserData, which is why the 27 path used to rely on
            // a counter instead — and why a running daemon then intercepted the
            // CLI's events and moved the wrong way (#8).
            aug.setIntegerValueField(.eventSourceUserData, value: noswooshEventTag)
            events.append(aug)
        }
        events.forEach(postPair)
    } else {
        postDockSwipe(.began, right: right)
        postDockSwipe(.changed, right: right)
        postDockSwipe(.ended, right: right)
    }
}

func switchSpace(right: Bool) {
    // Park the press instead of computing a direction from a list that is still reporting the
    // space we are leaving — a stale read here is a swipe the Dock refuses.
    guard dockCaughtUp() else {
        parkStep(right: right)
        return
    }
    applySteps(right ? 1 : -1)
}

// MARK: - App-activation preempt (Cmd+Tab, `open -b <app>`, Dock icon click)

// Activating an app whose window is on another space drags that space along with a
// slide animation. Unlike a swipe, that switch is not an event we ever see — the Dock
// runs its window-order follow rule internally (same rule the yank guard below keeps
// off your back) — so the tap has nothing to intercept and no substitution to make.
// The only way to lose the animation is to *arrive first*: on the front-switch
// notification, switch to the app's space ourselves with the instant gesture. By the
// time the app orders its window in, that space is already current and the follow rule
// has nothing left to animate. Same preemption as the yank guard, pointed the other
// way: the guard takes activation so a window never orders in, this takes the space so
// the order-in needs no transition.
//
// Measured on 27.0 (26A428), single display, two spaces. Native Cmd+Tab flips the space
// 632-671ms after the Cmd release and shows ~140ms of slide in captured frames (3 frames
// mid-slide); with this, 371-402ms and zero mid-slide frames — 6/6 Cmd+Tab rounds and
// 14/14 `open -b` rounds, both directions, plus a 2-space jump through a fullscreen
// space. "Landed on the right space" alone proves nothing here: a switch that works and
// *slides* passes it (see the 1.7.0 regression in the traps), so the frames are the test.
//
// Cursor-display caveat (see spaceInfo): a Dock swipe lands on the display under the
// cursor, and it cannot be steered, so a target space that belongs to another display
// is left alone rather than guessed at — native animation stays in that one case.
// Single display, or "Displays have separate Spaces" off: the whole list is visible here
// and nothing is skipped.

// Space holding this app: the space of its *frontmost* ordinary window. CGWindowList is
// ordered front to back, so the first layer-0 window of the pid that is on a space is the one
// macOS itself will order in when the app activates — and therefore the space its follow rule
// would drag us to.
//
// This replaced a rule that required all of an app's windows to be on one space and gave up
// otherwise. Requiring that looked prudent and was wrong: any app that keeps a second window
// elsewhere stopped preempting entirely (WeChat: a 280x380 chat window on the neighbouring
// space plus the main window over here is enough), and the only symptom is the animation
// quietly coming back for that app. Windows on no space at all (the 1512x33 title-bar helpers
// WeChat and Chrome both keep) are skipped, not counted as a space.
func spaceForApp(_ pid: pid_t) -> UInt64? {
    let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements],
                                          kCGNullWindowID) as? [[String: Any]] ?? []
    for w in list {
        guard (w[kCGWindowLayer as String] as? Int) == 0,
              (w[kCGWindowOwnerPID as String] as? Int) == Int(pid),
              let window = w[kCGWindowNumber as String] as? UInt32 else { continue }
        let spaces = SLSCopySpacesForWindows(cid, 0x7, [window] as CFArray)
            .takeRetainedValue() as? [NSNumber] ?? []
        if let space = spaces.first?.uint64Value { return space }
    }
    return nil
}

// ProcessSerialNumber for a pid. GetProcessForPID is deprecated in C and marked
// unavailable *to Swift* (not merely warned about), so it is resolved at runtime the way
// setCtrlArrowShortcuts resolves SLSSetSymbolicHotKeyEnabled. ApplicationServices is
// already linked (Carbon/AX), so this is a lookup, not a load.
typealias GetProcessForPIDFn = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

let getProcessForPID: GetProcessForPIDFn? = {
    guard let services = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY),
          let symbol = dlsym(services, "GetProcessForPID") else { return nil }
    return unsafeBitCast(symbol, to: GetProcessForPIDFn.self)
}()

func psn(for pid: pid_t) -> ProcessSerialNumber? {
    guard let getProcessForPID else { return nil }
    var psn = ProcessSerialNumber()
    return getProcessForPID(pid, &psn) == noErr ? psn : nil
}

// Daemon-only: a CLI switch exits within 150ms, so preempting there would only race
// the caller's own switch. NOSWOOSH_APP_SWITCH=0 turns it off without a rebuild.
let appSwitchPreemptEnabled = ProcessInfo.processInfo.environment["NOSWOOSH_APP_SWITCH"] != "0"

// Technique and the `SLSSpaceSetFrontPSN` call both come from yabai's
// `skip_window_focus_animation` (asmvik, MIT), which does this from its process event
// handler with SIP enabled. That call repoints the activation's *own* space target (see
// `AppleSpacesSwitchOnActivate`, a separate path from the follow rule the gesture
// preempts) at the space we just switched to. A single-display A/B on 27.0 measured no
// difference with it removed (8 rounds each way, same landings, same zero mid-slide
// frames), so on this geometry the gesture alone is doing the work — but the geometry it
// plausibly guards (another display, a slower follow) is not testable from one screen,
// and losing it would be silent. Keep unless you have multi-display evidence.

// NOSWOOSH_DEBUG=1 logs one line per activation: which space the app is on, what the space
// list said, what was posted, and why nothing was when nothing was — plus one line per switch the
// core posts. An intermittent miss is otherwise invisible — the Dock's follow covers for it with
// the animation, and no error is reported anywhere — so it has to be readable afterwards instead
// of guessed at. Every line carries a timestamp: a bare sequence of decisions cannot tell a burst
// from an afternoon.
let debugEnabled = ProcessInfo.processInfo.environment["NOSWOOSH_DEBUG"] != nil

func preemptTrace(_ app: NSRunningApplication, _ note: @autoclosure () -> String) {
    guard debugEnabled else { return }
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    log("\(formatter.string(from: Date())) preempt \(app.localizedName ?? "pid \(app.processIdentifier)"): \(note())")
}

func preemptAppActivationSpace(_ app: NSRunningApplication) {
    let pid = app.processIdentifier
    // A newer activation supersedes anything parked for an older one, whatever this call then
    // decides: "nothing to do" is a decision about the app in front *now*.
    pendingReach = nil
    // Deliberately the list's own answer, with no "where we think we are heading" state on
    // top of it. An earlier version preferred an in-flight target for a few hundred ms after
    // posting, and that is strictly worse here: when the guess was wrong (a gesture the Dock
    // dropped, or a switch that had already landed) it computed a step that the list would
    // have clamped, so it posted a swipe off the end of the space list — a rubber-band at
    // best, and measured on 27.0 a *black screen* for ~400ms (mean luma 197 -> 5.5, five
    // frames at 20ms). The list is the Dock's own model, and it is right whenever it has
    // finished moving; `dockCaughtUp` above is what establishes that, and until it does this
    // preempt parks the request instead of guessing (which is the same clamp by another route).
    guard let target = spaceForApp(pid) else {
        preemptTrace(app, "no window on any space (windowless app, or another display)")
        return
    }
    // Before reading the list for a decision: it reports the space we are leaving until the
    // Dock commits, so inside that window "already there" is a wrong answer for the app that
    // needs the switch (macOS then animates it) and the computed direction is one the Dock has
    // already left (which is the clamp). Park it; the tick re-runs this whole decision.
    guard dockCaughtUp() else {
        preemptTrace(app, "a switch of ours is still uncommitted — deferring to \(target)")
        parkReach(pid: pid)
        return
    }
    guard let info = spaceInfo(), let index = info.ids.firstIndex(of: target) else {
        preemptTrace(app, "space \(target) not in this display's list")
        return
    }
    // Landing on the space you are already on is the common case (an app activated on its
    // own space) and is also what makes this safe to leave on: nothing to do, nothing
    // posted. A windowless app — noswoosh itself, when the yank guard activates us — fails
    // at spaceForApp and lands here too.
    guard index != info.currentIndex else {
        preemptTrace(app, "nothing to do: already on \(target) (list index \(info.currentIndex) of \(info.ids.count))")
        return
    }
    guard let psn = psn(for: pid) else {
        preemptTrace(app, "no PSN for pid \(pid)")
        return
    }
    let steps = index - info.currentIndex
    _ = SLSSpaceSetFrontPSN(cid, target, psn)
    preemptTrace(app, "\(info.ids[info.currentIndex]) -> \(target): \(abs(steps)) step(s) \(steps > 0 ? "right" : "left"), list index \(info.currentIndex) of \(info.ids.count)")
    // One gesture per space of travel: a Dock swipe moves exactly one space. Posted as
    // a burst, and like the Ctrl+arrow path they are tagged/counted so our own tap
    // passes them through instead of re-interpreting them as a swipe to replace. The whole
    // burst is one request against the gate above: it starts from an index the Dock confirms,
    // and each gesture lands one space on from the last, so the last one lands on the target.
    for _ in 0..<abs(steps) { postSwitchGesture(right: steps > 0) }
    notePost(from: info.ids[info.currentIndex])
}

func installAppActivationPreempt() {
    NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didActivateApplicationNotification,
        object: nil, queue: .main
    ) { note in
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication else { return }
        preemptAppActivationSpace(app)
    }
}

// MARK: - Empty-desktop yank guard

// Landing on a space with no ordinary windows makes macOS pick some other app
// and activate it. If that app's window lives on a different space, ordering it
// in trips the Dock's window-order follow rule and you are yanked away ~400ms
// after landing — the Dock logs "switching to space N for window(...) ordered on
// non-visible space". This is macOS behavior, not ours: plain native switching
// does it too.
//
// The old fix was `workspaces-auto-swoosh -bool NO`, which stops the Dock from
// registering for that notification at all. But disassembling the Dock shows the
// rule's switcher has exactly ONE caller — that same notification block — so
// killing it also kills Dock-icon-follow (clicking a Dock icon to jump to the
// space its window is on). One pref, both behaviors; you cannot split them.
//
// So instead we let the Dock keep its rule and remove the *cause*: the moment we
// land somewhere with nothing to focus, we take activation ourselves. macOS
// still activates its pick (~at landing), but that app never gets to order its
// off-space window in first, so the follow never fires. Measured margin is
// ~380ms, which is why a plain notification observer is fast enough.
//
// Costs, both small: we are an .accessory app with no windows and no menu, so
// the menu bar stays with whatever macOS picked and nothing is visible; only
// keystrokes typed at an empty desktop go nowhere, which is where they were
// already going. Requires .accessory (not .prohibited) — a prohibited app
// cannot become active at all.
//
// Verified on macOS 26.6: 3/3 yanked without the guard, 0/3 with it. Two things
// that do NOT work, so don't "simplify" to them: parking a real window on the
// destination space (verified resident, still yanks — emptiness is the trigger,
// not the cause), and activating BEFORE the switch (the switch re-activates
// macOS's pick at landing and wipes it out). It has to be on landing.

// Is any ordinary (layer 0) window resident on this space?
func spaceHasWindows(_ spaceID: UInt64) -> Bool {
    let list = CGWindowListCopyWindowInfo([.excludeDesktopElements],
                                          kCGNullWindowID) as? [[String: Any]] ?? []
    let ids = list.compactMap { w -> UInt32? in
        guard (w[kCGWindowLayer as String] as? Int) == 0 else { return nil }
        return w[kCGWindowNumber as String] as? UInt32
    }
    guard !ids.isEmpty else { return false }
    let spaces = SLSCopySpacesForWindows(cid, 0x7, ids as CFArray)
        .takeRetainedValue() as? [NSNumber] ?? []
    return spaces.contains { $0.uint64Value == spaceID }
}

// macOS 27 fixed this at the source: it activates **Finder** on a windowless
// landing. Finder owns the desktop and has no off-space window to order in, so the
// chain never starts and nothing yanks — measured 4/4 rounds on 27.0 (26A5416b) with
// a browser parked on another space, versus a reliable yank on 26.6. Running the
// guard there would only displace Finder, and on an empty desktop a user expects
// Finder active (desktop clicks, its menu bar, Cmd+N). So gate it off on 27+.
//
// An unreadable version (0) means run it: a needless activation on an unknown OS is
// a far cheaper mistake than the yank coming back on one that needs the guard.
// NOSWOOSH_FORCE_YANK_GUARD=0/1 overrides, for testing either side without a rebuild.
let yankGuardNeeded: Bool = {
    if let force = ProcessInfo.processInfo.environment["NOSWOOSH_FORCE_YANK_GUARD"] {
        return force == "1"
    }
    return macOSMajor < 27
}()

// Daemon-only: a CLI switch exits within 150ms, so claiming activation there
// would be pointless (and we would hand focus back on exit anyway).
func installYankGuard() {
    NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.activeSpaceDidChangeNotification,
        object: nil, queue: .main
    ) { _ in
        if !spaceHasWindows(SLSGetActiveSpace(cid)) {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

// A real horizontal swipe's direction comes from its progress sign (on .changed)
// or velocity sign (on .ended). A real trackpad swipe to the right carries
// *positive* progress and velocity, on 26 and 27 alike — measured on 27.0
// (26A428) with a passive tap: +0.65 / +7.8 landed one space right, -0.57 / -7.2
// one space left, natively.
//
// This is deliberately NOT the sign we *post* on 27. `makeAugmentedDockEvent`
// must send negative-for-right there, confirmed in a 27.0 VM: forcing positive
// progress moved left and negative moved right, twice each. So on 27 the read
// and write sides use opposite conventions. That asymmetry is real — do not
// "tidy" it by making them agree.
//
// Flipping the reading side too (1.7.2 and earlier) inverts every trackpad swipe,
// while Ctrl+arrow keeps working because it never reads a real gesture. Don't
// re-add it.
func isRightSwipe(_ direction: Double) -> Bool {
    direction > 0
}

// MARK: - Login daemon installation

// The LaunchAgent lives here rather than in the Homebrew cask because Homebrew 7 sandboxes
// cask install steps (see `setup`). Written from the app bundle so the plist points at a
// real path whichever way the binary was invoked — /Applications/noswoosh-pro.app when the
// cask installed it, or ~/.local/bin from a source install.
let launchAgentLabel = "xu.max.noswoosh-pro"

func installLaunchAgent() {
    let executable = (Bundle.main.executablePath ?? CommandLine.arguments[0])
    // Resolve symlinks: setup is normally reached through the cask's /opt/homebrew/bin
    // symlink, and a LaunchAgent pointed at *that* is a plist that breaks the moment the
    // cask is uninstalled or relinked.
    let exe = URL(fileURLWithPath: executable).resolvingSymlinksInPath().standardizedFileURL.path
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let plistPath = "\(home)/Library/LaunchAgents/\(launchAgentLabel).plist"
    let logPath = "\(home)/Library/Logs/noswoosh-pro.log"
    let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>Label</key>
        <string>\(launchAgentLabel)</string>
        <key>ProgramArguments</key>
        <array>
            <string>\(exe)</string>
        </array>
        <key>RunAtLoad</key>
        <true/>
        <key>KeepAlive</key>
        <true/>
        <key>ProcessType</key>
        <string>Interactive</string>
        <key>LimitLoadToSessionType</key>
        <string>Aqua</string>
        <key>StandardErrorPath</key>
        <string>\(logPath)</string>
    </dict>
    </plist>
    """
    do {
        try FileManager.default.createDirectory(atPath: "\(home)/Library/LaunchAgents",
                                                withIntermediateDirectories: true)
        try plist.write(toFile: plistPath, atomically: true, encoding: .utf8)
    } catch {
        FileHandle.standardError.write("could not write \(plistPath): \(error)\n".data(using: .utf8)!)
        return
    }
    // bootout first so an existing agent picks up a moved or replaced binary; both calls
    // may fail (nothing loaded / already loaded) — the bootstrap below is what matters.
    _ = runTool("/bin/launchctl", ["bootout", "gui/\(getuid())/\(launchAgentLabel)"])
    if !runTool("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plistPath]) {
        FileHandle.standardError.write("launchctl bootstrap failed — the daemon will start at next login\n".data(using: .utf8)!)
    }
}

// MARK: - CLI modes

let args = CommandLine.arguments
if args.count > 1 {
    switch args[1] {
    case "list":
        if let info = spaceInfo() {
            print("space \(info.currentIndex + 1) of \(info.ids.count)")
        }
        exit(0)
    case "left", "right":
        switchSpace(right: args[1] == "right")
        // brief grace so the gesture events flush before exit
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
        exit(0)
    case "setup":
        setCtrlArrowShortcuts(enabled: false)
        // Also install the login daemon. The Homebrew cask used to do this from its
        // postflight, which no longer works: Homebrew 7 runs cask install steps inside a
        // sandbox, and `setup`'s WindowServer/cfprefsd calls are killed with SIGKILL there
        // (measured: hotkeys stayed enabled and the step died silently behind
        // must_succeed). Sandboxed or not, the user is going to run this once anyway, so
        // the whole "make it work" job lives here.
        installLaunchAgent()
        // Versions 1.6.4 and earlier disabled the Dock's window-order space-follow
        // (workspaces-auto-swoosh) to suppress the empty-desktop yank. That also
        // killed Dock-icon-follow, because the Dock runs both off the same
        // notification. The daemon's yank guard handles the yank directly now, so
        // leave the pref at the macOS default. Clear an override a prior version
        // left — restarting the Dock only if we actually removed one, so a fresh
        // install gets no gratuitous restart.
        if runTool("/usr/bin/defaults", ["delete", "com.apple.dock", "workspaces-auto-swoosh"]) {
            _ = runTool("/usr/bin/killall", ["Dock"])
        }
        print("""
        noswoosh-pro setup complete:
          - system animated Ctrl+arrow shortcuts disabled (live + persisted)
          - login daemon installed (\(launchAgentLabel)) and started
        Remaining: grant Accessibility permission (System Settings > Privacy & Security >
        Accessibility). The daemon prompts on its own within a second of starting.
        """)
        exit(0)
    case "teardown":
        setCtrlArrowShortcuts(enabled: true)
        print("noswoosh-pro teardown complete: system Ctrl+arrow shortcuts re-enabled.")
        exit(0)
    case "version", "--version":
        print("noswoosh-pro \(noswooshVersion)")
        exit(0)
    default:
        FileHandle.standardError.write("usage: noswoosh-pro [left | right | list | setup | teardown | version]\n".data(using: .utf8)!)
        exit(1)
    }
}

// MARK: - Daemon mode

func log(_ message: String) {
    FileHandle.standardError.write("noswoosh-pro: \(message)\n".data(using: .utf8)!)
}

// Accessibility trust is evaluated when the process starts and cached for its
// lifetime, so a grant made while we are running does not take effect. Rather
// than making the user restart the daemon by hand, poll and exit once trusted:
// the LaunchAgent sets KeepAlive, so launchd immediately starts a fresh process
// that picks the grant up. Run outside launchd there is nothing to restart us,
// so say so instead.
let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
if !AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary) {
    log("waiting for Accessibility permission (System Settings > Privacy & Security > Accessibility)")
    var secondsWaited = 0
    var openedSettings = false
    Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
        if AXIsProcessTrusted() {
            if getppid() == 1 {
                log("Accessibility granted — restarting to apply it")
            } else {
                log("Accessibility granted — restart noswoosh to apply it")
            }
            exit(0)
        }
        secondsWaited += 1
        // The system prompt above already offers an "Open System Settings" button.
        // Give it a chance; if it was dismissed we are a background agent with no
        // UI, and the only remaining signal is a log file nobody opens — so take
        // the user to the pane directly, once.
        if secondsWaited == 15, !openedSettings {
            openedSettings = true
            let pane = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            if let url = URL(string: pane), NSWorkspace.shared.open(url) {
                log("opened System Settings > Privacy & Security > Accessibility")
            }
        }
    }
}

// Whether *this* process may post synthetic events ("Device Control and Data Access",
// kTCCServicePostEvent — a separate grant from Accessibility on current macOS). Without it a
// posted switch is dropped with no error, and on current macOS each dropped attempt also
// re-raises the system prompt: for a daemon that posts on every app activation that is a
// permission dialog per keystroke, which is what the user sees.
//
// CGPreflightPostEventAccess answers for the process's own record, which is the right question
// only when we are our own responsible process — i.e. launchd started us (ppid 1). Started
// from a shell instead, the grant is inherited from the terminal and preflight reports "no"
// for posts that in fact work (verified: the CLI's posts land while preflight is false), so
// there the flag is left alone rather than gating a working setup into silence.

// Posting synthetic events is a *separate* grant from Accessibility on current macOS — the
// "Device Control and Data Access" pane (kTCCServicePostEvent). Without it every posted event
// is dropped *and* each attempt re-raises the system prompt, so the app reads as one begging
// for permission in a loop while the space switches that reach the Dock are just the native
// ones. Ask once, then wait like the Accessibility gate above rather than posting into a wall.
postingAllowed = getppid() != 1 || CGPreflightPostEventAccess()
if !postingAllowed {
    log("waiting for \"Device Control and Data Access\" permission — System Settings > Privacy & Security > 设备控制和数据访问 (until then switches stay native)")
    _ = CGRequestPostEventAccess()
    var secondsWaited = 0
    var openedSettings = false
    // Poll rather than exit: every posting path reads `postingAllowed`, so a grant starts
    // working within a second and no restart is needed.
    Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
        if CGPreflightPostEventAccess() {
            postingAllowed = true
            log("event-posting permission granted")
        }
        secondsWaited += 1
        if secondsWaited == 15, !openedSettings {
            openedSettings = true
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security"),
               NSWorkspace.shared.open(url) {
                log("opened System Settings > Privacy & Security")
            }
        }
    }
}

let app = NSApplication.shared
// .accessory, not .prohibited: no Dock icon and no Cmd-Tab entry either way, but
// a prohibited app cannot become active, which the yank guard depends on.
app.setActivationPolicy(.accessory)
if yankGuardNeeded {
    installYankGuard()
} else if ProcessInfo.processInfo.environment["NOSWOOSH_FORCE_YANK_GUARD"] != nil {
    log("empty-desktop yank guard off (forced by NOSWOOSH_FORCE_YANK_GUARD)")
} else {
    log("empty-desktop yank guard off (macOS \(macOSMajor) handles it natively)")
}
if appSwitchPreemptEnabled {
    installAppActivationPreempt()
} else {
    log("app-activation preempt off (NOSWOOSH_APP_SWITCH=0)")
}

// Input source 1: Ctrl+Left / Ctrl+Right hotkey.
var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                              eventKind: UInt32(kEventHotKeyPressed))
InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
    var hotKeyID = EventHotKeyID()
    GetEventParameter(event, EventParamName(kEventParamDirectObject),
                      EventParamType(typeEventHotKeyID), nil,
                      MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    switchSpace(right: hotKeyID.id == 2)
    return noErr
}, 1, &eventType, nil, nil)

for (id, keyCode) in [(UInt32(1), UInt32(kVK_LeftArrow)), (UInt32(2), UInt32(kVK_RightArrow))] {
    var ref: EventHotKeyRef?
    let hotKeyID = EventHotKeyID(signature: OSType(0x5350_5357), id: id) // 'SPSW'
    let status = RegisterEventHotKey(keyCode, UInt32(controlKey), hotKeyID,
                                     GetApplicationEventTarget(), 0, &ref)
    if status != noErr {
        log("could not register Ctrl+arrow hotkey (status \(status))")
    }
}

// Input source 2: intercept real 3-finger horizontal swipes and replace them
// with the instant switch. Direction is read from progress (Changed) or, for
// discrete swipes that skip Changed, velocity (Ended). Vertical swipes (Mission
// Control, App Exposé) and everything else pass through untouched.
var swipeTracking = false
var swipeFired = false
var swipeTap: CFMachPort?

func resetSwipeState() { swipeTracking = false; swipeFired = false }

let swipeCallback: CGEventTapCallBack = { _, type, ev, _ in
    let pass = Unmanaged.passUnretained(ev)

    if type == .tapDisabledByUserInput || type == .tapDisabledByTimeout {
        resetSwipeState()
        if AXIsProcessTrusted(), let t = swipeTap { CGEvent.tapEnable(tap: t, enable: true) }
        return pass
    }

    let et = ev.getIntegerValueField(fieldCGSEventType)

    // Let our own synthetic events through without re-intercepting them.
    if (et == kCGSEventDockControl || et == kCGSEventGesture)
        && ev.getIntegerValueField(.eventSourceUserData) == noswooshEventTag {
        return pass
    }

    if et == kCGSEventDockControl
        && ev.getIntegerValueField(fieldGestureHIDType) == kIOHIDEventTypeDockSwipe
        && ev.getIntegerValueField(fieldSwipeMotion) == kCGGestureMotionHorizontal {
        let phase = ev.getIntegerValueField(fieldGesturePhase)
        switch phase {
        case GesturePhase.began.rawValue:
            swipeTracking = true; swipeFired = false
            return nil
        case GesturePhase.changed.rawValue:
            if swipeTracking && !swipeFired {
                let p = ev.getDoubleValueField(fieldSwipeProgress)
                if p != 0 { swipeFired = true; switchSpace(right: isRightSwipe(p)) }
            }
            return swipeTracking ? nil : pass
        case GesturePhase.ended.rawValue:
            let wasTracking = swipeTracking
            if swipeTracking && !swipeFired {
                let v = ev.getDoubleValueField(fieldSwipeVelocityX)
                if v != 0 { switchSpace(right: isRightSwipe(v)) }
            }
            resetSwipeState()
            // On macOS 27 let the real terminal event through (fields cleared) so
            // the Dock can close its native gesture state after our synthetic
            // sequence already switched.
            if needsAugmentation && wasTracking {
                ev.setDoubleValueField(fieldSwipeVelocityX, value: 0)
                ev.setDoubleValueField(fieldSwipeVelocityY, value: 0)
                ev.setDoubleValueField(fieldSwipeProgress, value: 0)
                return pass
            }
            return wasTracking ? nil : pass
        case GesturePhase.cancelled.rawValue:
            resetSwipeState()
            return nil
        default:
            return swipeTracking ? nil : pass
        }
    }

    // Suppress companion gesture events belonging to a swipe we're intercepting.
    if et == kCGSEventGesture && swipeTracking { return nil }
    return pass
}

// Tap the private DockControl (30) and companion gesture (29) event types.
let swipeMask = (CGEventMask(1) << kCGSEventGesture) | (CGEventMask(1) << kCGSEventDockControl)
if let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                               options: .defaultTap, eventsOfInterest: swipeMask,
                               callback: swipeCallback, userInfo: nil) {
    swipeTap = tap
    let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    // The callback re-enables the tap when the system disables it, but a disable
    // can arrive without a callback under load. Poll as a backstop so swipes never
    // silently die until the next relaunch.
    Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
        if AXIsProcessTrusted(), !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
            log("re-enabled swipe event tap")
        }
    }
} else {
    // Fails when not (yet) trusted; the Accessibility poll above restarts us
    // once granted, and the fresh process creates the tap successfully.
    log("could not create swipe event tap (Accessibility not granted yet?)")
}

app.run()
