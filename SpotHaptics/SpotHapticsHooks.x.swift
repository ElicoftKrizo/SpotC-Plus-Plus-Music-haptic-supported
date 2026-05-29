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
// MARK: - HookGroup declaration
// ─────────────────────────────────────────────────────────────────────────────

struct SpotHapticsGroup: HookGroup {}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - LAYER 1: SPTPlayerImpl hook
//
// `SPTPlayerImpl` is Spotify's primary playback coordinator.
// The method `playerImpl:stateDidChange:` is called by the SDK whenever the
// player's state changes (new track, play, pause, seek, shuffle, repeat …).
//
// Selector observed in Hopper/class-dump of Spotify 8.x–9.x:
//   -[SPTPlayerImpl playerImpl:stateDidChange:]
// ─────────────────────────────────────────────────────────────────────────────

class SPTPlayerImplHook: ClassHook<NSObject> {
    typealias Group = SpotHapticsGroup
    static let targetName = "SPTPlayerImpl"

    // Fires on every player state change.
    // `state` is an `SPTPlayerState` (opaque NSObject subclass).
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
//
// Introduced in Spotify ~8.8+. Acts as the queue-aware replacement for parts
// of SPTPlayerImpl. Exposes the same `stateDidChange:` pattern.
// ─────────────────────────────────────────────────────────────────────────────

class SPTQueueServicePlayerImplHook: ClassHook<NSObject> {
    typealias Group = SpotHapticsGroup
    static let targetName = "SPTQueueServicePlayerImpl"

    func playerImpl(_ playerImpl: AnyObject, stateDidChange state: AnyObject) {
        orig.playerImpl(playerImpl, stateDidChange: state)
        handleStateChange(state)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - LAYER 3: SPTNowPlayingModel / current-item change
//
// `SPTNowPlayingModel` tracks the "now playing" bar at the bottom of the UI.
// `setCurrentTrack:` is called when the track changes; this is an extra hook
// that fires even if the player-state hooks miss an event.
// ─────────────────────────────────────────────────────────────────────────────

class SPTNowPlayingModelHook: ClassHook<NSObject> {
    typealias Group = SpotHapticsGroup
    static let targetName = "SPTNowPlayingModel"

    // Called when a new track is loaded into the now-playing model.
    func setCurrentTrack(_ track: AnyObject) {
        orig.setCurrentTrack(track)

        // `track` is usually an SPTPlayerTrack-ish object
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
//
// Spotify posts several notifications to NSNotificationCenter.
// Catching these ensures haptics fire even if method swizzling misses an event
// (e.g. during cold-start or SDK version mismatches).
// ─────────────────────────────────────────────────────────────────────────────

// Known Spotify notification names (from class-dump / runtime inspection):
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
        // userInfo keys vary by Spotify version; try several known keys
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
    typealias Group = SpotHapticsGroup

    // Tear down engine when the app moves to background to save battery
    func applicationDidEnterBackground(_ application: UIApplication) {
        orig.applicationDidEnterBackground(application)
        HapticEngineManager.shared.teardown()
    }

    // Re-arm observer when returning to foreground
    func applicationWillEnterForeground(_ application: UIApplication) {
        orig.applicationWillEnterForeground(application)
        // Singleton re-creates the engine on next playHaptics() call automatically
        os_log("App foregrounded – haptic engine will re-arm on next play",
               log: hlog, type: .debug)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Tweak entry point
// ─────────────────────────────────────────────────────────────────────────────

struct SpotHaptics: Tweak {
    init() {
        // Activate all hooks
        SpotHapticsGroup().activate()

        // Arm the notification observer immediately
        _ = SpotHapticsNotificationObserver.shared

        os_log("SpotHaptics loaded – haptic hooks active", log: hlog, type: .info)
    }
}
