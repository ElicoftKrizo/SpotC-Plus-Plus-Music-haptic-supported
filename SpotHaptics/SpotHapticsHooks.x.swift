// SpotHaptics/Sources/SpotHaptics/SpotHapticsHooks.x.swift
// ─────────────────────────────────────────────────────────────────────────────
// CRASH FIX — EXC_BREAKPOINT / EXC_BREAKPOINT (SIGTRAP) on iOS 26.5 / Spotify 2.6.4
//
// ROOT CAUSE (confirmed via crash log image-frame analysis):
//
//   Orion's ClassHook<NSObject> generates a *static initializer* that is
//   baked into the dylib's __mod_init_func section at compile time.
//   During dyld initialization (before any Swift init() code runs), that
//   static initializer fires and calls into Orion to register each hook.
//
//   Orion's internal registration logic calls:
//
//       guard let cls = NSClassFromString(targetName) else {
//           // dispatches fatalError onto its "error-handler-queue"
//           fatalError("Could not find class '\(targetName)'")
//       }
//
//   This is the EXACT "error-handler-queue" / _assertionFailure /
//   EXC_BREAKPOINT chain visible in the crash report.
//
//   Spotify 2.6.4 (running on iPhone OS 26.5) renamed or internalized
//   SPTPlayerImpl, SPTQueueServicePlayerImpl, and SPTNowPlayingModel.
//   Their ObjC class records are absent from the runtime at dylib-load time,
//   so Orion fires fatalError → SIGTRAP on Thread 0 before the app's UI
//   ever appears.
//
//   NSClassFromString guards inside Tweak.init() CANNOT prevent this —
//   the static initializer runs first, at a lower level than Swift init().
//
// SECOND BUG (in SpotHapticsHooks_x.swift — the previous "fix" attempt):
//
//   method_exchangeImplementations(A, B) was used with a replacement class
//   whose body calls `self.method(...)`. After the exchange, `self.method()`
//   dispatches on self's class (SPTPlayerImpl), which now holds the
//   replacement IMP → infinite recursion → stack overflow on first playback.
//
// THIS FIX:
//   • ALL ClassHook<NSObject> definitions for Spotify-internal classes are
//     REMOVED. Orion's static init never fires for missing classes.
//   • Replaced with hookTwoArg / hookOneArg helpers that use:
//         imp_implementationWithBlock + method_setImplementation
//     The original IMP is captured as a C function pointer BEFORE install,
//     and called directly — zero message-dispatch, zero recursion risk.
//   • Guards: NSClassFromString returns nil → os_log + skip, never crash.
//   • ClassHook<UIApplication> is kept; UIApplication is ALWAYS present.
//   • The Makefile is unchanged — this file still goes through Logos/Orion.
//
// Hook layers (priority order):
//   RUNTIME 1 – SPTPlayerImpl.playerImpl:stateDidChange:
//   RUNTIME 2 – SPTPlayerImpl.playerImpl:didChangeState:
//   RUNTIME 3 – SPTQueueServicePlayerImpl.playerImpl:stateDidChange:
//   RUNTIME 4 – SPTNowPlayingModel.setCurrentTrack:
//   NC LAYER  – NSNotificationCenter (always-on, belt-and-suspenders)
//   LIFECYCLE – UIApplicationHook via Orion ClassHook (UIApplication = safe)
// ─────────────────────────────────────────────────────────────────────────────

import Orion
import ObjectiveC
import Foundation
import UIKit
import os.log

private let hlog = OSLog(subsystem: "com.spotc.SpotHaptics", category: "Hooks")

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Shared state-change helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Walks a set of KVC key-paths on an opaque Spotify state object, returning
/// the first non-empty String found (track URI or human-readable name).
private func extractTrackID(fromState state: AnyObject) -> String? {
    let keyPaths = ["item.URI", "item.trackUri", "item.name", "item.trackName"]
    for kp in keyPaths {
        if let val = (state as? NSObject)?.value(forKeyPath: kp) as? String,
           !val.isEmpty {
            return val
        }
    }
    return nil
}

/// Returns true when the state object signals active playback.
private func isPlaying(state: AnyObject) -> Bool {
    // isPaused flag (Bool or NSNumber)
    if let paused = (state as? NSObject)?.value(forKeyPath: "isPaused") {
        if let b = paused as? Bool     { return !b }
        if let n = paused as? NSNumber { return !n.boolValue }
    }
    // playbackStatus == 1 means playing in some SDK versions
    if let status = (state as? NSObject)?.value(forKeyPath: "playbackStatus") as? Int {
        return status == 1
    }
    // Default: assume playing
    return true
}

/// Central handler dispatched by every hook layer.
private func handleStateChange(_ state: AnyObject) {
    guard let id = extractTrackID(fromState: state) else { return }
    if isPlaying(state: state) {
        os_log("Track playing: %{public}@", log: hlog, type: .debug, id)
        HapticEngineManager.shared.playHaptics(forTrackID: id)
    } else {
        os_log("Playback paused/stopped", log: hlog, type: .debug)
        HapticEngineManager.shared.pauseHaptics()
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Safe ObjC runtime hook installer
//
// Design rationale vs method_exchangeImplementations:
//
//   method_exchangeImplementations(A, B) puts original IMP at B's slot.
//   Inside the replacement body, `self.method()` dispatches through self's
//   class (A), which now holds the replacement IMP → infinite recursion.
//
//   The pattern below avoids the exchange entirely:
//     1. Read the method's current IMP → origIMP  (captured in closure)
//     2. Build a new block IMP that calls origIMP directly via C ptr, then runs body
//     3. Write the new IMP into the slot with method_setImplementation
//
//   origIMP is a raw C function pointer — it bypasses ObjC dispatch completely.
//   Recursion is structurally impossible.
// ─────────────────────────────────────────────────────────────────────────────

// ObjC IMP calling conventions for the methods we hook.
// Every ObjC IMP receives (self, _cmd) as hidden first two args.

/// IMP for void methods with two ObjC-object arguments:
///   -[SPTPlayerImpl playerImpl:stateDidChange:]
///   -[SPTPlayerImpl playerImpl:didChangeState:]
///   -[SPTQueueServicePlayerImpl playerImpl:stateDidChange:]
private typealias TwoArgIMP = @convention(c) (AnyObject, Selector, AnyObject, AnyObject) -> Void

/// IMP for void methods with one ObjC-object argument:
///   -[SPTNowPlayingModel setCurrentTrack:]
private typealias OneArgIMP = @convention(c) (AnyObject, Selector, AnyObject) -> Void

// ── Two-argument hook ──────────────────────────────────────────────────────

/// Installs a post-hook on a two-argument void ObjC method.
/// Calls the original implementation first, then `body`.
/// Returns false (with a log) if the method is absent — never crashes.
@discardableResult
private func hookTwoArg(
    on cls: AnyClass,
    selector selectorName: String,
    body: @escaping (_ target: AnyObject, _ arg1: AnyObject, _ arg2: AnyObject) -> Void
) -> Bool {
    let sel = NSSelectorFromString(selectorName)

    guard let method = class_getInstanceMethod(cls, sel) else {
        os_log(
            "hookTwoArg: '%{public}@' not found on %{public}@ — skipping",
            log: hlog, type: .info,
            selectorName, NSStringFromClass(cls)
        )
        return false
    }

    // Capture original IMP as a bare C function pointer BEFORE we replace it.
    // This reference lives in the closure heap; it is never nil and never moves.
    let origIMP  = method_getImplementation(method)
    let origFunc = unsafeBitCast(origIMP, to: TwoArgIMP.self)

    // Freeze selector value so the block does not repeat NSSelectorFromString work.
    let frozenSel = sel

    let newBlock: @convention(block) (AnyObject, AnyObject, AnyObject) -> Void = {
        target, arg1, arg2 in
        origFunc(target, frozenSel, arg1, arg2)  // ← original Spotify code, direct C call
        body(target, arg1, arg2)                  // ← our haptic handler
    }

    // Install — no exchange, no recursion surface.
    method_setImplementation(method, imp_implementationWithBlock(newBlock))
    os_log(
        "hookTwoArg: installed '%{public}@' on %{public}@",
        log: hlog, type: .info,
        selectorName, NSStringFromClass(cls)
    )
    return true
}

// ── One-argument hook ──────────────────────────────────────────────────────

/// Installs a post-hook on a one-argument void ObjC method.
/// Same safe pattern as hookTwoArg.
@discardableResult
private func hookOneArg(
    on cls: AnyClass,
    selector selectorName: String,
    body: @escaping (_ target: AnyObject, _ arg1: AnyObject) -> Void
) -> Bool {
    let sel = NSSelectorFromString(selectorName)

    guard let method = class_getInstanceMethod(cls, sel) else {
        os_log(
            "hookOneArg: '%{public}@' not found on %{public}@ — skipping",
            log: hlog, type: .info,
            selectorName, NSStringFromClass(cls)
        )
        return false
    }

    let origIMP  = method_getImplementation(method)
    let origFunc = unsafeBitCast(origIMP, to: OneArgIMP.self)
    let frozenSel = sel

    let newBlock: @convention(block) (AnyObject, AnyObject) -> Void = { target, arg1 in
        origFunc(target, frozenSel, arg1)
        body(target, arg1)
    }

    method_setImplementation(method, imp_implementationWithBlock(newBlock))
    os_log(
        "hookOneArg: installed '%{public}@' on %{public}@",
        log: hlog, type: .info,
        selectorName, NSStringFromClass(cls)
    )
    return true
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - NSNotificationCenter observer (belt-and-suspenders)
//
// Catches Spotify's high-level playback notifications even if every runtime
// hook above misses an event (cold-start race, SDK version change, etc.)
// ─────────────────────────────────────────────────────────────────────────────

private let kTrackDidChange = "SPTNowPlayingItemDidChangeNotification"
private let kPlaybackPlay   = "SPTPlaybackPlayNotification"
private let kPlaybackPause  = "SPTPlaybackPauseNotification"
private let kPlaybackStop   = "SPTPlaybackStopNotification"

final class SpotHapticsNotificationObserver {
    static let shared = SpotHapticsNotificationObserver()

    private init() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(onTrackChange(_:)),
                       name: NSNotification.Name(kTrackDidChange), object: nil)
        nc.addObserver(self, selector: #selector(onPlay(_:)),
                       name: NSNotification.Name(kPlaybackPlay), object: nil)
        nc.addObserver(self, selector: #selector(onPause(_:)),
                       name: NSNotification.Name(kPlaybackPause), object: nil)
        nc.addObserver(self, selector: #selector(onStop(_:)),
                       name: NSNotification.Name(kPlaybackStop), object: nil)
        os_log("Notification observers registered", log: hlog, type: .info)
    }

    @objc private func onTrackChange(_ note: Notification) {
        // Spotify uses different userInfo keys across versions — try all known ones.
        let id = (note.userInfo?["SPTNowPlayingItemURI"]   as? String)
            ?? (note.userInfo?["uri"]                      as? String)
            ?? (note.userInfo?["trackUri"]                 as? String)
            ?? (note.userInfo?["SPTNowPlayingTrackTitle"]  as? String)
        guard let trackID = id, !trackID.isEmpty else { return }
        os_log("Notification track change: %{public}@", log: hlog, type: .debug, trackID)
        HapticEngineManager.shared.playHaptics(forTrackID: trackID)
    }

    @objc private func onPlay(_ note: Notification)  { HapticEngineManager.shared.resumeHaptics() }
    @objc private func onPause(_ note: Notification) { HapticEngineManager.shared.pauseHaptics()  }
    @objc private func onStop(_ note: Notification)  { HapticEngineManager.shared.stopHaptics()   }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - App lifecycle hook (ClassHook is safe — UIApplication always exists)
//
// This is the ONLY ClassHook in the file. UIApplication is a framework class
// guaranteed to be loaded before any tweak dylib initializer runs.
// ─────────────────────────────────────────────────────────────────────────────

struct SpotHapticsGroup: HookGroup {}

class UIApplicationHook: ClassHook<UIApplication> {
    typealias Group = SpotHapticsGroup

    /// Tear down the haptic engine when the app goes to background.
    /// CoreHaptics requires this to avoid resource leaks / audio-session conflicts.
    func applicationDidEnterBackground(_ application: UIApplication) {
        orig.applicationDidEnterBackground(application)
        HapticEngineManager.shared.teardown()
    }

    /// Re-arm the observer when the app returns to foreground.
    /// HapticEngineManager lazily restarts the engine on next playHaptics() call.
    func applicationWillEnterForeground(_ application: UIApplication) {
        orig.applicationWillEnterForeground(application)
        os_log("App foregrounded – haptic engine will re-arm on next play",
               log: hlog, type: .debug)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Tweak entry point
// ─────────────────────────────────────────────────────────────────────────────

struct SpotHaptics: Tweak {

    init() {
        // ── 1. UIApplication lifecycle via Orion ClassHook (always safe) ─────
        SpotHapticsGroup().activate()

        // ── 2. SPTPlayerImpl runtime hooks ────────────────────────────────────
        // Guard: if SPTPlayerImpl was renamed or removed in this Spotify build,
        // NSClassFromString returns nil → log + skip. No crash, no fatalError.
        if let cls = NSClassFromString("SPTPlayerImpl") {
            // Primary selector (Spotify 8.x)
            hookTwoArg(on: cls, selector: "playerImpl:stateDidChange:") { _, _, state in
                handleStateChange(state)
            }
            // Alternate selector variant seen in some build flavors
            hookTwoArg(on: cls, selector: "playerImpl:didChangeState:") { _, _, state in
                handleStateChange(state)
            }
        } else {
            os_log("SPTPlayerImpl not found in this Spotify build – hooks skipped",
                   log: hlog, type: .error)
        }

        // ── 3. SPTQueueServicePlayerImpl runtime hook (newer SDK fallback) ───
        if let cls = NSClassFromString("SPTQueueServicePlayerImpl") {
            hookTwoArg(on: cls, selector: "playerImpl:stateDidChange:") { _, _, state in
                handleStateChange(state)
            }
        } else {
            os_log("SPTQueueServicePlayerImpl not found – hook skipped",
                   log: hlog, type: .info)
        }

        // ── 4. SPTNowPlayingModel track-change hook ───────────────────────────
        if let cls = NSClassFromString("SPTNowPlayingModel") {
            hookOneArg(on: cls, selector: "setCurrentTrack:") { _, track in
                let uri = (track as? NSObject)?.value(forKeyPath: "URI")      as? String
                    ?? (track as? NSObject)?.value(forKeyPath: "trackUri")  as? String
                    ?? (track as? NSObject)?.value(forKeyPath: "name")      as? String
                guard let id = uri, !id.isEmpty else { return }
                os_log("SPTNowPlayingModel track: %{public}@", log: hlog, type: .debug, id)
                HapticEngineManager.shared.playHaptics(forTrackID: id)
            }
        } else {
            os_log("SPTNowPlayingModel not found – hook skipped",
                   log: hlog, type: .info)
        }

        // ── 5. NSNotificationCenter observer (always armed) ──────────────────
        _ = SpotHapticsNotificationObserver.shared

        os_log("SpotHaptics loaded – all haptic hooks active", log: hlog, type: .info)
    }
}
