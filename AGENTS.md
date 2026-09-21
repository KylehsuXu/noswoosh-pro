# Working on noswoosh-pro

Fork of [mmathys/noswoosh](https://github.com/mmathys/noswoosh). Same one Swift file
(`noswoosh.swift`), bundle script, and release workflow; the product, app bundle, CLI,
bundle id (`xu.max.noswoosh-pro`) and LaunchAgent label are renamed, and one feature is
added: the app-activation preempt. Keep this file in sync with upstream's when merging.

One Swift file (`noswoosh.swift`), a bundle script, and a release workflow. Read the
source comments first — they explain the technique. This file covers only what the
code can't tell you.

## Shape

Two input sources — the Ctrl+arrow hotkey and an event tap that intercepts real
3-finger swipes — both call one `switchSpace(right:)` core. The core has two posting
paths chosen by `needsAugmentation` (runtime `kern.osproductversion >= 27`): the
lightweight pre-27 path (verified on macOS 26), and the macOS 27+ path that attaches a
serialized IOHID payload. Keep new work behind that gate so a change to one OS can't
regress the other. Verified on macOS 26 and 27 only — don't claim older releases the
pre-27 path *should* handle but nobody has tested.

## Build and release

```sh
swiftc noswoosh.swift -O -o noswoosh-pro -F /System/Library/PrivateFrameworks -framework SkyLight
./scripts/make-app-bundle.sh --out build     # assembles noswoosh-pro.app
```

Releasing is a tag push: bump `noswooshVersion` in `noswoosh.swift`, then
`git tag vX.Y.Z && git push origin vX.Y.Z`. The tag must match the source version — the
workflow fails otherwise.

In *this* fork there are no signing secrets, so the release comes out ad-hoc signed: the
workflow still builds and publishes both zips, but skips signing, notarization and the
cask bump (that step is gated on notarization). After it finishes, update
`Casks/noswoosh-pro.rb` in `KylehsuXu/homebrew-tap` by hand with the new version and the
sha256 of `noswoosh-pro-<version>.app.zip` (the workflow prints it). Ad-hoc means every
release needs the Accessibility checkbox ticked again — signing secrets are the fix.

Upstream, the tap bump is automatic; don't copy that expectation here until the
`HOMEBREW_TAP_TOKEN` secret exists and `can_notarize` is true.

## Traps

**Don't re-add the "all windows on one space" rule to the preempt.** `spacesForApp` takes the
space of the app's *frontmost* window in `CGWindowList` order. Requiring every window to share
one space looks safer and is silently useless: WeChat keeps a 280x380 chat window on the
neighbouring space plus the main window elsewhere, and Chrome keeps a "translate this page?"
popup, so the preempt simply stops firing for that app — the only symptom is the animation
coming back for that one app, which reads like a regression in a build that didn't change.
Windows on no space (the 1512x33 title-bar helpers both apps keep) are skipped, not counted.

**A landing activation is not a user activation.** When a space becomes current macOS activates
the app that owns it — the Dock logs that app's app-state notification (`LSNotificationCode:
0x200`) immediately before `becameCurrent(N)`. The preempt used to read that as the user
activating an app: it asked which space the app's *frontmost* window is on, and for an app living
on both spaces (WeChat: main window on the one you just arrived on, the 280x380 chat window on
the one you left) that answer is the space you came from, so it switched straight back ~25ms
after the landing. That is the reported "flash and return", identical on Ctrl+arrow and on a
swipe, with the space list never sitting still long enough for anything to confirm it — and on a
two-space desktop it fires on every press, because every step is a step to an end.
`preemptAppActivationSpace` now stands down when the app already has a window on the space we are
on: macOS is showing that window, so the activation is *for* this space. Not the all-windows rule
above — an app with no window on the current space still preempts, which is what that rule broke.
Cost, measured: an app whose *far* window happens to be its frontmost one no longer preempts, so
macOS animates that switch instead.

Verify it by eye with `NOSWOOSH_DEBUG=1`, driving the switch from the CLI (the hotkey can't be
driven synthetically) — on the space holding WeChat's main window, activating WeChat used to log
`preempt 微信: 5 -> 4: 1 step(s) left` and move the space, and now logs `has a window on 5 —
macOS activated it for this space` and stays put. Red/green on 27.0, 3 spaces, 1.8.8.

Sibling, not fixed: macOS can move the space back on its own. With the preempt disabled outright
(`NOSWOOSH_APP_SWITCH=0`) landing on a space activated that space's app and then, ~30ms later,
the focus-owning app, with `becameCurrent(oldSpace)` — no follow-rule line and no gesture of
ours. Measured only with the pi harness as the focus owner, so it may be an artifact of that app;
if a user still reports the flash while the preempt is standing down, measure this next.

**Don't tidy the private-API constants.** The numeric `CGEventField`s and the `1e-4`
gesture progress are load-bearing and hard-won. `FLT_TRUE_MIN` — what the reference
implementations use — is flushed to zero on Apple Silicon and breaks direction. Both
paths use `1e-4` as of 1.7.1: the 27 path shipped `±1.0` (full travel) through 1.7.0,
which switched correctly and so passed every functional test, but *visibly slid* —
instant switching is the whole point, and no assertion in this repo catches a switch
that works but animates. The ±9999 fling on `.ended` is what commits the 27 swipe, so
only the sign of progress matters; don't use `0`, which `fixed1616` serializes as 0 in
the IOHID payload. Verify by eye on a real 27, not just by checking that it switched.

**The macOS 27 IOHID payload is byte-exact.** `generateIOHIDPayload` writes packed
little-endian structs (28/40/28-byte records) whose sizes and field offsets the Dock
validates. One wrong offset and 27 silently drops the swipe — no error, just no switch.
Don't "clean up" the manual byte writes into Swift structs; Swift doesn't guarantee C
packing. If you touch it, re-verify on a real 27 (see VM testing below), not just a
compile.

**The passthrough counter couples the core and the tap.** Every synthetic event the
core posts re-enters our own event tap. The core bumps `passthrough` by exactly the
number of events it posts (1 per bare event, 2 per augmented pair); the tap decrements
and passes those through instead of re-intercepting. If you change how many events a
post emits, update the bump in lockstep or the tap will eat its own output or act on it
twice.

**On macOS 27 the read and write sides use opposite sign conventions, on purpose.**
`makeAugmentedDockEvent` must *post* negative-for-right on 27 (positive posts move left —
confirmed in a 27.0 VM by forcing each sign), while `isRightSwipe` *reads* a real
gesture, and real trackpad swipes carry positive-for-right on 26 and 27 alike. So only
the writer branches on `needsAugmentation`; the reader is unconditional. Flipping the
reader too inverts every trackpad swipe on 27 while Ctrl+arrow keeps working, because the
hotkey path never reads a real gesture — that was the 1.7.2 bug fixed in #7. If direction
is backwards on one OS but right on the other, check which *side* you changed, not the
field constants.

**The daemon must be `.accessory`, not `.prohibited`.** The yank guard works by
taking activation the moment we land on a space with no windows. A `.prohibited` app
cannot become active at all, so "tidying" the policy back silently reintroduces the
empty-desktop yank with no error and no log line. Neither policy shows a Dock icon or
a Cmd-Tab entry, so the change is invisible until you test on an empty desktop. Note the guard only
runs on macOS < 27 (`yankGuardNeeded`), so testing this on a 27 box proves nothing —
use `NOSWOOSH_FORCE_YANK_GUARD=1` there, or test on 26.

**The yank guard has to fire on landing, not before.** Taking activation ahead of the
switch does nothing — the switch re-activates macOS's own pick when it commits. And
parking a real window on the destination space doesn't help either; emptiness is what
triggers the hunt, but the yank comes from the *other* app's window ordering. Both
were measured; see the README section.

**Never `cp` over the running binary.** `cp` rewrites the destination inode in place.
Do that to a running, signed binary and the kernel keeps page hashes that no longer
match it, then SIGKILLs every subsequent exec of that inode — new processes included.
The symptom is maddening: `codesign -v --strict` passes, the hash matches the build
byte for byte, the same bytes run fine from another path, and launchd just reports
`-9`. `scripts/install.sh` boots the agent out and `rm -f`s the target first; keep it
that way, and reach for `rm`-then-copy (or a temp file plus `mv`) anywhere else.

**Accessibility trust is cached for a process's lifetime.** That is the entire reason
the daemon polls `AXIsProcessTrusted()` and `execv`s itself once granted — a fresh
process image is what re-evaluates the grant. It looks like a redundant loop; it
isn't. Since 1.8.8 the LaunchAgent carries **no** `KeepAlive`: quitting the daemon
has to stick, so launchd will not bring it back and re-exec is the only thing keeping
the grant from costing every user a manual `launchctl kickstart`.

**Testing permission logic from a terminal lies to you.** TCC attributes a
terminal-launched binary's request to the terminal, so it reports *trusted* even when
the shipped app would not be. To exercise the untrusted path, force the branch in a
scratch build rather than trusting a green run.

**`setup`/`teardown` change system settings and restart the Dock.** If you toggle them
while testing, restore the user's original state before you finish.

**Space switching follows the cursor, not keyboard focus.** The Dock routes a Dock-swipe
to the display under the mouse pointer, and native Ctrl+arrow routes the same way —
hovering a second display, with no click and no focus change, makes it the target.
`SLSGetActiveSpace` and `SLSCopyActiveMenuBarDisplayIdentifier` track keyboard focus
instead, so they are the wrong input for anything that must agree with where a swipe will
land; using them for the boundary clamp was issue #3. The swipe cannot be *steered*
either: the 27 path carries `fieldSwipePositionX/Y`, but the pre-27 path has no position
field, so only the clamp can be made to follow. When testing multi-display, pin the cursor
explicitly with `CGWarpMouseCursorPosition` — otherwise results depend on wherever you
happened to leave it. Only relevant with "Displays have separate Spaces" on; with it off
every screen shares one space list.

**The ~38ms commit window is the whole clamp story — keep one switch in flight.** A posted
swipe is not committed when it is handed to the Dock: measured on 27.0 from this process, the
Dock's own space model (the per-display `Current Space` *and* `SLSGetActiveSpace` — they flip
together) reads the new space **38ms after the post**, so until then the list still reads the
space we came *from*. A second post inside that window computes its direction from an index the
Dock has already left, and when that index sits at an end of the list the swipe is one the Dock
has to clamp. A clamp is expensive and silent: measured mean luma 201 → 7.6 for ~500ms (a black
screen), the space list frozen while the clamps keep coming, every gesture already posted ignored,
and the now-silent reads making the preempt decide "already there" — so macOS's own follow rule
animates the switch instead. That is the whole reported symptom pair (black screen **and** the
animation coming back) in one mechanism. On a two-space desktop the window is *every* rapid press,
because every step is a step to an end: 4 of 6 bursts of app activations 20ms apart went black on
1.8.5 (5-10 dark frames each, three of them with the space moving again ~1.5-2.2s later), 0 of 10
on the fix. So the switch core posts one switch at a time: `dockCaughtUp()` refuses while the list
still reads the space the last post started from, and a request arriving before that is parked
(`parkStep` / `parkReach`) and re-evaluated from a fresh read on a 20ms tick. Don't "simplify"
this back into a straight post — the failure is intermittent, looks like a Dock bug, and leaves no
trace anywhere unless `NOSWOOSH_DEBUG=1` is set.

**The dead guard was the tell: don't re-add a `SLSGetActiveSpace` comparison.** This repo used to
skip a preempt when the per-display list and `SLSGetActiveSpace` disagreed ("the list is
mid-update"). With a single managed display those are the same value: `spaceInfo()` derives
`currentIndex` *from* `SLSGetActiveSpace`, so the guard compared it to itself and could never fire —
and it would not have helped anyway, because both APIs flip together at commit (0 disagreements in
1ms-resolution sampling across ~40 switches). The trustworthy signal is our own posting record
(`postedFrom` + the list), never two views of the same lagging model.

**The retry was the fuse, not the rescue.** `retryPreemptIfStuck` re-posted the same direction
150ms after a post whose target the list had not confirmed. All five firings in a wild log happened
inside rapid-switching bursts — i.e. during a wedge, where its "still on the old space" test passes
forever, so it just kept feeding same-direction swipes into a wedged Dock. Deleted. A dropped post
now costs one animated switch (the follow rule covers it) instead of a black screen.

**One parked request per tick, and don't merge them back.** The pending tick applies a parked app
activation *or* parked steps, never both: an activation posts a gesture, which closes the gate
again, so applying the parked steps straight after it is posting into *its* commit window.
Measured as 9 dark frames in one burst — found while writing this fix, in the fix.

**A parked app switch must not outlive a newer activation.** Before applying `pendingReach`, check
that pid is still frontmost, and clear `pendingReach` on every new activation. Otherwise the daemon
moves to the space of an app the user has already left, and the newer app's window ordering drags
them back, animated.

**The CLI is not gated against a running daemon.** `noswoosh-pro left/right` runs in its own
process, so its in-flight record is its own; a CLI switch posted inside a daemon switch's commit
window (or the reverse) is still the clamp above. At human cadence it is unreachable (a process
spawn is ~100-460ms against a 38ms window), but a hotkey tool that *repeats* a CLI binding can hit
it. Closing it means routing the CLI's request through the daemon — a second event tag the tap
converts into a gated `switchSpace` — which nobody has needed yet.

**Nothing secret belongs in this repo.** Signing material lives in
`~/.config/noswoosh-signing/` and in CI secrets. The `.p12` must be exported with
legacy PBE flags (`-keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1`) or
macOS `security import` rejects it.

## Checking your work

`noswoosh list` prints `space N of M` and is the cheapest confirmation that the private
API reads still work. Real verification needs several spaces — a change can compile,
run, and still switch the wrong way, or not at all.

**"Automatically rearrange Spaces based on most recent use" will misdirect your
tests.** It's in System Settings > Desktop & Dock, it's on by default, and it reorders
spaces as you use them — so a space's *index* is not stable between two runs a few
seconds apart. Navigate and assert by space **id** (`id64` from
`SLSCopyManagedDisplaySpaces`), re-reading the order before each run; a harness that
walks "two to the right" can land somewhere else entirely and you'll score a working
build as broken, or a broken one as fixed. Turning the setting off while testing works
too, but then you're not testing the configuration most users actually run. (Users hit
the same thing as "spaces switch in an unexpected order" — see the README.)

Test both OS paths. The catch: whichever machine you're on only runs one path natively.
Use `NOSWOOSH_FORCE_AUGMENT=1` / `=0` to force the 27 / pre-27 path regardless of OS for
a smoke test, but the payload is only *validated* by the real OS — a forced path can
post without switching. So confirm the 27 path on an actual macOS 27.

**The app-activation race is drivable from a script; the swipe path is not.** A tight loop of
`NSRunningApplication.activate()` produces the same `didActivateApplicationNotification` the
preempt handles, so Cmd+Tab / skhd bursts can be reproduced without a keyboard — that is what
`scripts/race-check.swift` does, and it is the regression check for this whole class of bug:

```sh
swift scripts/race-check.swift com.tencent.xinWeChat com.google.Chrome 20 24
```

It drives two apps that live on different spaces, grabs frames (needs Screen Recording permission
for the terminal — without it the run says so and the frames prove nothing), and fails on any frame
below luma 60: a clamped swipe blanks the display for ~500ms, measured at min luma 5.5 against ~200
for a normal desktop. On 1.8.5 it fails 2 of 2 runs at this cadence (7-10 black frames); with the
gate it passes 2 of 2 (min luma ~199). The list stats it prints are diagnostics, not a verdict: a
gated build *deliberately* parks and coalesces rapid activations, so it makes fewer space changes
than there were activations and is still working perfectly. **Cadence decides it** — a uniform 90ms
burst usually survives even the buggy build, because the damage needs two posts inside the 38ms
commit window; 20ms reproduces it in about two thirds of runs, and the user-visible streams that hit
it are key-repeat/jittered, with sub-38ms clusters. Read the daemon log afterwards with
`NOSWOOSH_DEBUG=1`: one `preempt` line per activation, one `switch:` line per posted switch, which
is what makes an intermittent miss readable instead of guessable. Assert by space `id64`, not index
(the auto-rearrange trap above).

The swipe path still cannot be driven synthetically: the daemon's tap *does* swallow an untagged
synthetic swipe, but the shapes differ from a real trackpad gesture in ways that mislead — a lone
terminal-phase event with its dock fields cleared still serializes its original IOHID blob, which
makes it look like the passthrough commits a step, and it does not. Verify swipe on a trackpad.

### Testing on a macOS 27 VM

The pre-27 path you can verify on a 26 host. For 27, a VM is the cheap loop (Apple's
Virtualization framework boots a 27 guest on a 26 host):

```sh
brew install cirruslabs/cli/tart        # needs: brew trust cirruslabs/cli
tart clone ghcr.io/cirruslabs/macos-golden-gate-vanilla:27.0 noswoosh-27   # ~30 GB
tart set noswoosh-27 --display 1280x800 --display-refit
tart run noswoosh-27 &                   # login is admin / admin; caffeinate -w <pid>
```

The guest has **no swiftc** (Command Line Tools are a stub), so build on the host and
copy the app in. Sign it with the same Developer ID as the installed app — TCC keys the
Accessibility grant to the code signature, not notarization or path, so a matching
signature reuses a grant already made in the VM:

```sh
./scripts/make-app-bundle.sh --binary /path/to/host-build --out /tmp/nsw \
    --sign "Developer ID Application: ... (TEAMID)"
ditto -c -k --keepParent /tmp/nsw/noswoosh.app /tmp/nsw.zip
scp /tmp/nsw.zip admin@$(tart ip noswoosh-27):                # ssh key via admin/admin
# in the VM: ditto -x -k nsw.zip ~/ ; then (re)bootstrap the LaunchAgent
```

Two traps that will waste your time:

- **Granting Accessibility.** The clean way is injecting a `kTCCServiceAccessibility`
  row into the system `TCC.db`, but SIP (on in the stock image) makes that DB read-only
  even to root. Either tick the checkbox once in the VM's System Settings window, or
  `tart run --recovery` + `csrutil disable` for a fully scriptable image. There is no
  in-between: a manual `.mobileconfig` doesn't grant Accessibility without MDM.
- **Don't drive the switch from a bare SSH/sudo process.** Event-posting trust is
  attributed to the *responsible* process; over SSH that's sshd, not noswoosh, so
  gestures are silently dropped and you'll misread a working build as broken. Launch via
  `launchctl asuser 501 sudo -u admin open -n ~/noswoosh.app --args right` — `open`
  makes the app its own responsible process, so the grant applies. Read the result with
  `... noswoosh list` between switches.

The **swipe path can't be tested in the VM** — there's no trackpad, so no real swipe
events to intercept. Verify swipe on a host with a trackpad (any supported OS; it shares
the switch core), and leave the 27-swipe-specific glue (companion suppression, terminal-
event passthrough) for bare-metal 27.

### Verifying the yank guard on 27

The yank guard is **not** behind `needsAugmentation` — it posts no events, so it runs
identically on both OSes and gets none of the protection that gate normally gives you.
Its correctness depends on macOS behavior that 27 could change, and every failure mode
is silent: the yank simply comes back, with no error and no log line. Unlike swipe, it
*can* be tested in the VM (no trackpad needed).

Do these in order; the first is cheapest and invalidates the rest if it fails.

**1. Re-check the "one pref, both behaviors" premise.** The whole design rests on the
Dock's follow rule having exactly one entry point, gated on `workspaces-auto-swoosh`.
That was established by disassembling the 26.6 Dock; 27 already tightened Dock-swipe
validation once, so don't assume it carried over.

```sh
lipo -thin arm64e -output /tmp/dock27 /System/Library/CoreServices/Dock.app/Contents/MacOS/Dock
otool -tV /tmp/dock27 > /tmp/dock27.asm
strings -a /tmp/dock27 | grep -c 'ordered on non-visible space'   # expect 1
```

Then resolve the `adrp`+`add` pair that references the `workspaces-auto-swoosh` literal
(string vmaddr = `0x100000000` + its file offset in the thinned slice) and confirm two
things still hold: the pref read is followed by a call to
`CGSSetWindowDidOrderInOnNonCurrentManagedSpacesOnlyNotificationBlock`, and the switcher
called at the end of that block still has exactly **one** caller — the block itself. If
it has two, the rule gained a second entry point and the premise is dead.

Baseline for comparison, macOS 26.6.2 (25G83), arm64e slice: pref read `0x1001e4afc`,
block install `0x1001e4b78`, callback body `0x1001e9754`, switcher `0x1001ed344` (one
caller, at `0x1001e9b10`). The notification payload carries `WindowID`,
`ManagedSpaceID`, `PSN.hi`/`PSN.lo`.

**2. Check `SLSCopySpacesForWindows` still reports truthfully.** It is the private half
of `spaceHasWindows()`, and if it changes shape the guard stops firing. Cheapest probe:
on a space you know has windows, confirm it returns that space id for those windows; on
a windowless one, confirm no window maps to it. Getting this wrong in the *other*
direction is worse than the yank — the guard would steal activation on every switch.

**3. Test the guard itself.** Arrange a windowless space in the guest, park on the space
next to it, then switch into it and see whether you stay:

```sh
launchctl asuser 501 sudo -u admin open -n ~/noswoosh.app --args right
sleep 1
launchctl asuser 501 sudo -u admin open -n ~/noswoosh.app --args list
```

Moved after the sleep means the guard failed. `open -n` is required for the same
responsible-process reason as everywhere else in this file. Read the Dock's own verdict
with `log stream --process Dock --info --debug` and grep for `non-visible space`; a hit
is the follow rule firing, which is exactly what the guard is supposed to prevent.

**4. Re-measure the race margin.** On 26.6 macOS activates its pick at ~300ms, we take
activation ~20ms later, and the yank would land ~700ms — roughly 380ms of headroom. It
is a race, not a guarantee. If 27 orders the window in sooner the margin narrows, and
that is worth knowing before it shows up as a flaky yank under load.

**Results, macOS 27.0 (26A5416b), tart VM, run 2026-08-25.**

- *Premise: holds.* `workspaces-auto-swoosh` read at `0x10017ad48`, `tbz` gate, one call
  to `CGSSetWindowDidOrderInOnNonCurrentManagedSpacesOnlyNotificationBlock` at
  `0x10017ae24` (the only one in the binary). Follow switcher `0x10018490c`, callers: 1.
  Same shape as 26.6. Note 27's Dock is arm64e-only, no fat slice to thin.
- *`SLSCopySpacesForWindows`: works.* Maps windows to spaces correctly, and the guard's
  negative case confirms it in both directions — landing on spaces with windows did
  **not** take activation, landing on the windowless one did.
- *Follow: works*, with the pref at default. 1.7.0's `setup` correctly cleared a legacy
  `workspaces-auto-swoosh = 0` left by an older build and restarted the Dock.
- *`.accessory` policy: works* — `NSApp.activate()` succeeds on 27.
- *The yank does not happen on 27, and we know why.* **27 activates Finder** when you
  land on a windowless space. Finder owns the desktop and has no off-space window to
  order in, so the chain never starts — no follow-rule log line, no yank, 4/4 rounds
  with no daemon running and a browser (Safari) parked on another space. 26.6 instead
  picks a real app with a window elsewhere and yanks you to it; traced on the host the
  same day at 20ms resolution: land on empty space at 64ms, yanked at 456ms, Dock logs
  `switching to space 121 for window(5ea9) ... ordered on non-visible space` (that
  window belonged to whichever ordinary app macOS happened to pick — Arc in one
  session, Tart in another). Apple appears to have fixed this at the source in 27.
  The race margin is therefore unmeasurable on 27 — there is no race.

  **Consequence for the guard: on 27 it is unnecessary, and it displaces Finder.**
  Verified in the VM — with the 1.7.0 daemon running, landing on the windowless space
  makes *noswoosh* frontmost instead of Finder. Harmless in the sense that nothing
  yanks, but on an empty desktop 27 users would expect Finder to be active (desktop
  clicks, Finder menu bar, Cmd+N). **Fixed:** the guard is now gated on `macOSMajor < 27`
  via `yankGuardNeeded`, sharing one `kern.osproductversion` read with
  `needsAugmentation` so the two gates can't disagree. Override either way with
  `NOSWOOSH_FORCE_YANK_GUARD=0/1`. An unreadable version runs the guard — a needless
  activation is cheaper than the yank returning. The daemon logs one line when it skips
  the guard, so the OS decision isn't silent. Caveat: one VM, one build (26A5416b).

Two traps that cost time here, both worth avoiding: `rm -rf`-ing the bundle while the
old daemon runs leaves that process on the orphaned inode, so it keeps serving the
*previous* build — check `lsof -p <pid> | awk '$4=="txt"'` against `stat -f %i` on disk
rather than trusting PID start times. And don't run `strings`/`otool` inside the guest:
Command Line Tools are a stub, so it silently returns nothing *and* pops an
"Install Command Line Developer Tools" dialog onto every space, which makes every space
non-empty and quietly invalidates the next yank test. Copy the binary to the host.
