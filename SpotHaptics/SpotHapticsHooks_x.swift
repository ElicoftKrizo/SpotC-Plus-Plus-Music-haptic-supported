// SpotHaptics/Sources/SpotHaptics/SpotHapticsHooks.x.swift
// ─────────────────────────────────────────────────────────────────────────────
// Bridges Spotify's internal playback engine to HapticEngineManager.
//
// FIX (crash on launch — EXC_BREAKPOINT / fatalError in libswiftCore):
//   Orion's ClassHook<NSObject> calls fatalError at *compile-time-generated*
//   static init if the target ObjC class is absent at dylib load time.
//   That happens *before* any Swift init() code runs, so NSClassFromString
//   guards in init() cannot help.
//
//   Solution: Remove ALL ClassHook usage for Spotify-internal classes.
//   Replace with plain ObjC runtime swizzling (method_exchangeImplementations)
//   performed lazily inside the Tweak init(), guarded by NSClassFromString.
//   Only UIApplicationHook (which targets UIApplication — always present) keeps
//   ClassHook, because that is safe.
//
// Hook strategy:
//   SWIZZLE 1 – SPTPlayerImpl.playerImpl:stateDidChange:
//   SWIZZLE 2 – SPTPlayerImpl.playerImpl:didChangeState:
//   SWIZZLE 3 – SPTQueueServicePlayerImpl.playerImpl:stateDidChange:
//   SWIZZLE 4 – SPTNowPlayingModel.setCurrentTrack:
//   LAYER  5  – NSNotificationCenter (always-on belt-and-suspenders)
//   HOOK   6  – UIApplicationHook (background / foreground lifecycle)
// ─────────────────────────────────────────────────────────────────────────────

import Orion
import ObjectiveC
import Foundation
import UIKit
import os.log

private let hlog = OSLog(subsystem: "com.spotc.SpotHaptics", category: "Hooks")

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Shared helpers
// ─────────────────────────────────────────────────────────────────────────────

private func extractTrackID(fromState state: AnyObject) -> String? {
    for keyPath in ["item.URI", "item.trackUri", "item.name", "item.trackName"] {
        if let val = (state as? NSObject)?.value(forKeyPath: keyPath) as? String,
           !val.isEmpty { return val }
    }
    return nil
}

private func isPlaying(state: AnyObject) -> Bool {
    if let paused = (state as? NSObject)?.value(forKeyPath: "isPaused") {
        if let b = paused as? Bool     { return !b }
        if let n = paused as? NSNumber { return !n.boolValue }
    }
    if let status = (state as? NSObject)?.value(forKeyPath: "playbackStatus") as? Int {
        return status == 1
    }
    return true
}

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
// MARK: - ObjC runtime swizzle helper
// ─────────────────────────────────────────────────────────────────────────────

/// Swizzles `selector` on `targetClass` with the IMP from `replacementClass`.
/// Returns true on success, silently returns false if anything is missing.
@discardableResult
private func swizzle(
    targetClass: AnyClass,
    selector: Selector,
    replacementClass: AnyClass
) -> Bool {
    guard
        let original = class_getInstanceMethod(targetClass, selector),
        let replacement = class_getInstanceMethod(replacementClass, selector)
    else {
        os_log("swizzle: method %{public}@ not found on %{public}@",
               log: hlog, type: .info,
               NSStringFromSelector(selector), NSStringFromClass(targetClass))
        return false
    }
    method_exchangeImplementations(original, replacement)
    os_log("swizzled %{public}@ on %{public}@",
           log: hlog, type: .info,
           NSStringFromSelector(selector), NSStringFromClass(targetClass))
    return true
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Swizzle replacement implementations
//
// These classes exist only to hold replacement IMPs.
// They are NEVER instantiated or registered as hooks with Orion.
// ─────────────────────────────────────────────────────────────────────────────

@objc private class SPTPlayerImplSwizzle: NSObject {
    @objc func playerImpl(_ playerImpl: AnyObject, stateDidChange state: AnyObject) {
        // Call original (swizzled, so self's class now points to orig)
        self.playerImpl(playerImpl, stateDidChange: state)
        handleStateChange(state)
    }
    @objc func playerImpl(_ playerImpl: AnyObject, didChangeState state: AnyObject) {
        self.playerImpl(playerImpl, didChangeState: state)
        handleStateChange(state)
    }
}

@objc private class SPTQueueSwizzle: NSObject {
    @objc func playerImpl(_ playerImpl: AnyObject, stateDidChange state: AnyObject) {
        self.playerImpl(playerImpl, stateDidChange: state)
        handleStateChange(state)
    }
}

@objc private class SPTNowPlayingSwizzle: NSObject {
    @objc func setCurrentTrack(_ track: AnyObject) {
        self.setCurrentTrack(track)
        let uri = (track as? NSObject)?.value(forKeyPath: "URI") as? String
            ?? (track as? NSObject)?.value(forKeyPath: "trackUri") as? String
            ?? (track as? NSObject)?.value(forKeyPath: "name") as? String
        guard let id = uri, !id.isEmpty else { return }
        os_log("SPTNowPlayingModel track: %{public}@", log: hlog, type: .debug, id)
        HapticEngineManager.shared.playHaptics(forTrackID: id)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - NSNotificationCenter observer
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
        let id = (note.userInfo?["SPTNowPlayingItemURI"] as? String)
            ?? (note.userInfo?["uri"] as? String)
            ?? (note.userInfo?["trackUri"] as? String)
            ?? (note.userInfo?["SPTNowPlayingTrackTitle"] as? String)
        guard let trackID = id, !trackID.isEmpty else { return }
        HapticEngineManager.shared.playHaptics(forTrackID: trackID)
    }
    @objc private func onPlay(_ note: Notification)  { HapticEngineManager.shared.resumeHaptics() }
    @objc private func onPause(_ note: Notification) { HapticEngineManager.shared.pauseHaptics() }
    @objc private func onStop(_ note: Notification)  { HapticEngineManager.shared.stopHaptics() }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - UIApplication lifecycle (ClassHook is safe here — UIApplication
//         is always present in every iOS process)
// ─────────────────────────────────────────────────────────────────────────────

struct SpotHapticsGroup: HookGroup {}

class UIApplicationHook: ClassHook<UIApplication> {
    typealias Group = SpotHapticsGroup

    func applicationDidEnterBackground(_ application: UIApplication) {
        orig.applicationDidEnterBackground(application)
        HapticEngineManager.shared.teardown()
    }
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
        // UIApplication hook via Orion — always safe
        SpotHapticsGroup().activate()

        // ── Runtime swizzles (guarded — missing class = skip, not crash) ─────
        if let cls = NSClassFromString("SPTPlayerImpl") {
            swizzle(targetClass: cls,
                    selector: #selector(SPTPlayerImplSwizzle.playerImpl(_:stateDidChange:)),
                    replacementClass: SPTPlayerImplSwizzle.self)
            swizzle(targetClass: cls,
                    selector: #selector(SPTPlayerImplSwizzle.playerImpl(_:didChangeState:)),
                    replacementClass: SPTPlayerImplSwizzle.self)
        } else {
            os_log("SPTPlayerImpl not found — swizzle skipped", log: hlog, type: .error)
        }

        if let cls = NSClassFromString("SPTQueueServicePlayerImpl") {
            swizzle(targetClass: cls,
                    selector: #selector(SPTQueueSwizzle.playerImpl(_:stateDidChange:)),
                    replacementClass: SPTQueueSwizzle.self)
        } else {
            os_log("SPTQueueServicePlayerImpl not found — swizzle skipped",
                   log: hlog, type: .info)
        }

        if let cls = NSClassFromString("SPTNowPlayingModel") {
            swizzle(targetClass: cls,
                    selector: #selector(SPTNowPlayingSwizzle.setCurrentTrack(_:)),
                    replacementClass: SPTNowPlayingSwizzle.self)
        } else {
            os_log("SPTNowPlayingModel not found — swizzle skipped",
                   log: hlog, type: .info)
        }

        // Belt-and-suspenders: notification observer always runs
        _ = SpotHapticsNotificationObserver.shared

        os_log("SpotHaptics loaded — hooks active", log: hlog, type: .info)
    }
}
