// SpotHaptics/Sources/SpotHaptics/SpotHapticsHooks.x.swift
// ─────────────────────────────────────────────────────────────────────────────
// Orion hooks that bridge Spotify's internal playback engine to the
// HapticEngineManager.
//
// Hook strategy (layered for robustness):
//
//   LAYER 1 – SPTPlayerImpl  (primary, most reliable)
//     The main playback coordinator. Hooks `playerImpl:stateDidChange:` which
//     fires on every play/pause/seek/track-change event with a full state
//     object containing the current track's Spotify URI.
//
//   LAYER 2 – SPTQueueServicePlayerImpl  (fallback for newer Spotify builds)
//     Alternative player coordinator introduced in later SDK versions.
//     Hooks the same state-change selector.
//
//   LAYER 3 – NSNotificationCenter observer  (belt-and-suspenders)
//     Spotify posts `SPTNowPlayingItemDidChangeNotification` whenever the
//     current track changes. Caught here as a last-resort fallback, extracting
//     the track URI from the `userInfo` dictionary.
//
// FIX (crash on launch): Each Spotify-internal class hook now lives in its own
// HookGroup. The Tweak init guards every group activation with NSClassFromString
// so that Orion never calls fatalError on a missing class (which caused an
// instant crash on Spotify 9.0.96 / iOS 26 where one or more of these classes
// was renamed/removed).
//
// Build environment:
//   - Orion (https://orion.theos.dev) – the Theos-native Swift hooking framework
//   - Theos 2.x with Swift support
//   - Deployment target: iOS 13+ (CHHapticEngine requires iOS 13)
//
// File location inside the repo:
//   SpotHaptics/Sources/SpotHaptics/SpotHapticsHooks.x.swift
// ─────────────────────────────────────────────────────────────────────────────

import Orion
import Foundation
import UIKit
import os.log

private let hlog = OSLog(subsystem: "com.spotc.SpotHaptics", category: "Hooks")

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Shared helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Extract the best identifier from an opaque Spotify player-state object.
/// Tries, in order:
///   1. `item.URI`            (e.g. "spotify:track:4iV5W9uYEdYUVa79Axb7Rh")
///   2. `item.trackUri`       (some SDK versions)
///   3. `item.name` / `item.trackName`  (human-readable title fallback)
private func extractTrackID(fromState state: AnyObject) -> String? {
    // --- URI via item.URI ---
    if let item = (state as? NSObject)?.value(forKeyPath: "item.URI") as? String,
       !item.isEmpty {
        return item
    }
    // --- URI via item.trackUri ---
    if let item = (state as? NSObject)?.value(forKeyPath: "item.trackUri") as? String,
       !item.isEmpty {
        return item
    }
    // --- Human-readable name ---
    if let name = (state as? NSObject)?.value(forKeyPath: "item.name") as? String,
       !name.isEmpty {
        return name
    }
    if let name = (state as? NSObject)?.value(forKeyPath: "item.trackName") as? String,
       !name.isEmpty {
        return name
    }
    return nil
}

/// True when the state object signals playback is active (not paused/stopped).
private func isPlaying(state: AnyObject) -> Bool {
    // `isPaused` flag (Bool or NSNumber)
    if let paused = (state as? NSObject)?.value(forKeyPath: "isPaused") {
        if let b = paused as? Bool      { return !b }
        if let n = paused as? NSNumber  { return !n.boolValue }
    }
    // `playbackStatus` == 1 means playing in some SDK versions
    if let status = (state as? NSObject)?.value(forKeyPath: "playbackStatus") as? Int {
        return status == 1
    }
    // Default: assume playing if we can't determine
    return true
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - HookGroup declarations
//
// Each Spotify-internal class gets its own group so we can activate them
// independently. Activating a group whose target class doesn't exist causes
// Orion to call fatalError — separate groups + NSClassFromString guards prevent
// that crash entirely.
// ─────────────────────────────────────────────────────────────────────────────

struct SpotHapticsGroup: HookGroup {}           // UIApplication — always exists
struct SPTPlayerImplGroup: HookGroup {}         // SPTPlayerImpl — may not exist
struct SPTQueueServiceGroup: HookGroup {}       // SPTQueueServicePlayerImpl — may not exist
struct SPTNowPlayingGroup: HookGroup {}         // SPTNowPlayingModel — may not exist

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - LAYER 1: SPTPlayerImpl hook
// ─────────────────────────────────────────────────────────────────────────────

class SPTPlayerImplHook: ClassHook<NSObject> {
    typealias Group = SPTPlayerImplGroup
    static let targetName = "SPTPlayerImpl"

    // Fires on every player state change.
    func playerImpl(_ playerImpl: AnyObject, stateDidChange state: AnyObject) {
        orig.playerImpl(playerImpl, stateDidChange: state)
        handleStateChange(state)
    }

    // Some Spotify versions use a slightly different selector name.
    func playerImpl(
        _ playerImpl: AnyObject,
        didChangeState state: AnyObject
    ) {
        orig.playerImpl(playerImpl, didChangeState: state)
        handleStateChange(state)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - LAYER 2: SPTQueueServicePlayerImpl hook (newer builds)
// ─────────────────────────────────────────────────────────────────────────────

class SPTQueueServicePlayerImplHook: ClassHook<NSObject> {
    typealias Group = SPTQueueServiceGroup
    static let targetName = "SPTQueueServicePlayerImpl"

    func playerImpl(_ playerImpl: AnyObject, stateDidChange state: AnyObject) {
        orig.playerImpl(playerImpl, stateDidChange: state)
        handleStateChange(state)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - LAYER 3: SPTNowPlayingModel / current-item change
// ─────────────────────────────────────────────────────────────────────────────

class SPTNowPlayingModelHook: ClassHook<NSObject> {
    typealias Group = SPTNowPlayingGroup
    static let targetName = "SPTNowPlayingModel"

    func setCurrentTrack(_ track: AnyObject) {
        orig.setCurrentTrack(track)

        let uri  = (track as? NSObject)?.value(forKeyPath: "URI")       as? String
            ?? (track as? NSObject)?.value(forKeyPath: "trackUri")    as? String
            ?? (track as? NSObject)?.value(forKeyPath: "name")         as? String

        guard let id = uri, !id.isEmpty else { return }

        os_log("SPTNowPlayingModel track change: %{public}@", log: hlog, type: .debug, id)
        HapticEngineManager.shared.playHaptics(forTrackID: id)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Shared state-change handler (used by LAYER 1 & 2)
// ─────────────────────────────────────────────────────────────────────────────

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
// MARK: - LAYER 4: NSNotificationCenter observer (belt-and-suspenders)
// ─────────────────────────────────────────────────────────────────────────────

private let kTrackDidChange   = "SPTNowPlayingItemDidChangeNotification"
private let kPlaybackPlay     = "SPTPlaybackPlayNotification"
private let kPlaybackPause    = "SPTPlaybackPauseNotification"
private let kPlaybackStop     = "SPTPlaybackStopNotification"

final class SpotHapticsNotificationObserver {
    static let shared = SpotHapticsNotificationObserver()

    private init() {
        let nc = NotificationCenter.default

        nc.addObserver(
            self,
            selector: #selector(onTrackChange(_:)),
            name: NSNotification.Name(kTrackDidChange),
            object: nil
        )
        nc.addObserver(
            self,
            selector: #selector(onPlay(_:)),
            name: NSNotification.Name(kPlaybackPlay),
            object: nil
        )
        nc.addObserver(
            self,
            selector: #selector(onPause(_:)),
            name: NSNotification.Name(kPlaybackPause),
            object: nil
        )
        nc.addObserver(
            self,
            selector: #selector(onStop(_:)),
            name: NSNotification.Name(kPlaybackStop),
            object: nil
        )

        os_log("Notification observers registered", log: hlog, type: .info)
    }

    @objc private func onTrackChange(_ note: Notification) {
        let id = (note.userInfo?["SPTNowPlayingItemURI"]     as? String)
            ?? (note.userInfo?["uri"]                       as? String)
            ?? (note.userInfo?["trackUri"]                  as? String)
            ?? (note.userInfo?["SPTNowPlayingTrackTitle"]   as? String)

        guard let trackID = id, !trackID.isEmpty else { return }

        os_log("Notification track change: %{public}@", log: hlog, type: .debug, trackID)
        HapticEngineManager.shared.playHaptics(forTrackID: trackID)
    }

    @objc private func onPlay(_ note: Notification) {
        HapticEngineManager.shared.resumeHaptics()
    }

    @objc private func onPause(_ note: Notification) {
        HapticEngineManager.shared.pauseHaptics()
    }

    @objc private func onStop(_ note: Notification) {
        HapticEngineManager.shared.stopHaptics()
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - App lifecycle hooks (background / foreground)
// ─────────────────────────────────────────────────────────────────────────────

class UIApplicationHook: ClassHook<UIApplication> {
    typealias Group = SpotHapticsGroup   // UIApplication always exists — safe to activate unconditionally

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
        // ── Spotify-internal hooks ────────────────────────────────────────────
        // IMPORTANT: Orion calls fatalError if a ClassHook's targetName class
        // doesn't exist in the process at activation time. Each Spotify class
        // is guarded with NSClassFromString so a missing class is gracefully
        // logged and skipped instead of crashing the app.

        if NSClassFromString("SPTPlayerImpl") != nil {
            SPTPlayerImplGroup().activate()
            os_log("SPTPlayerImpl hook: active", log: hlog, type: .info)
        } else {
            os_log("SPTPlayerImpl not found — hook skipped (renamed in this Spotify build?)",
                   log: hlog, type: .error)
        }

        if NSClassFromString("SPTQueueServicePlayerImpl") != nil {
            SPTQueueServiceGroup().activate()
            os_log("SPTQueueServicePlayerImpl hook: active", log: hlog, type: .info)
        } else {
            os_log("SPTQueueServicePlayerImpl not found — hook skipped",
                   log: hlog, type: .info)
        }

        if NSClassFromString("SPTNowPlayingModel") != nil {
            SPTNowPlayingGroup().activate()
            os_log("SPTNowPlayingModel hook: active", log: hlog, type: .info)
        } else {
            os_log("SPTNowPlayingModel not found — hook skipped",
                   log: hlog, type: .info)
        }

        // ── UIApplication hook (always safe — UIApplication always exists) ───
        SpotHapticsGroup().activate()

        // ── Notification observer (works regardless of class hooks) ───────────
        _ = SpotHapticsNotificationObserver.shared

        os_log("SpotHaptics loaded — haptic hooks active", log: hlog, type: .info)
    }
}
