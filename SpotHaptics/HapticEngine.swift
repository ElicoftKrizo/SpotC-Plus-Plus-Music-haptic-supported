// SpotHaptics/Sources/SpotHaptics/HapticEngine.swift
// ─────────────────────────────────────────────────────────────────────────────
// Singleton wrapper around CHHapticEngine.
// Handles engine lifecycle, pattern loading from the CustomHaptics bundle
// directory, and clean pause/stop on Spotify playback events.
// ─────────────────────────────────────────────────────────────────────────────

import CoreHaptics
import Foundation
import os.log

private let log = OSLog(subsystem: "com.spotc.SpotHaptics", category: "HapticEngine")

// MARK: - HapticEngineManager

final class HapticEngineManager {

    // ── Singleton ────────────────────────────────────────────────────────────
    static let shared = HapticEngineManager()
    private init() { setupEngine() }

    // ── State ────────────────────────────────────────────────────────────────
    private var engine: CHHapticEngine?
    private var player: CHHapticPatternPlayer?
    private var isEngineRunning = false
    private var currentPatternID: String?

    // Throttle repeated calls for the same track
    private var lastStartedID: String?

    // ── Engine Setup ─────────────────────────────────────────────────────────

    private func setupEngine() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            os_log("Device does not support haptics", log: log, type: .info)
            return
        }

        do {
            let eng = try CHHapticEngine()
            eng.playsHapticsOnly = true          // no audio output from haptics
            eng.isAutoShutdownEnabled = false    // we manage lifetime ourselves

            // Called when the engine stops unexpectedly (phone call, etc.)
            eng.stoppedHandler = { [weak self] reason in
                os_log("Haptic engine stopped: %{public}@",
                       log: log, type: .error, String(describing: reason))
                self?.isEngineRunning = false
                self?.player = nil
            }

            // Called when the engine is reset after an interruption
            eng.resetHandler = { [weak self] in
                os_log("Haptic engine reset – restarting", log: log, type: .info)
                self?.isEngineRunning = false
                self?.restartEngine()
            }

            engine = eng
            os_log("CHHapticEngine created", log: log, type: .info)
        } catch {
            os_log("Failed to create CHHapticEngine: %{public}@",
                   log: log, type: .error, String(describing: error))
        }
    }

    private func restartEngine() {
        engine?.start { [weak self] error in
            if let error = error {
                os_log("Engine restart failed: %{public}@",
                       log: log, type: .error, String(describing: error))
            } else {
                self?.isEngineRunning = true
            }
        }
    }

    // ── Bundle URL helper ─────────────────────────────────────────────────────

    /// Returns the URL for `<trackID>.ahap` inside
    /// `Payload/Spotify.app/CustomHaptics/`, or nil if not found.
    private func ahapURL(forTrackID trackID: String) -> URL? {
        // The .ahap files are injected into the main bundle under CustomHaptics/
        if let url = Bundle.main.url(
            forResource: trackID,
            withExtension: "ahap",
            subdirectory: "CustomHaptics"
        ) {
            return url
        }

        // Fallback: try a sanitised version of the ID (strip "spotify:track:" prefix)
        let sanitised = trackID
            .replacingOccurrences(of: "spotify:track:", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined(separator: "_")

        return Bundle.main.url(
            forResource: sanitised,
            withExtension: "ahap",
            subdirectory: "CustomHaptics"
        )
    }

    // ── Public API ────────────────────────────────────────────────────────────

    /// Call when a new track starts. `trackID` may be a Spotify URI, a plain
    /// track ID string, or the track title – we try all variants.
    func playHaptics(forTrackID trackID: String) {
        // Deduplicate rapid calls for the same track
        guard trackID != lastStartedID else { return }
        lastStartedID = trackID

        guard let engine = engine else { return }

        // Find the .ahap file
        guard let url = ahapURL(forTrackID: trackID) else {
            os_log("No .ahap found for track: %{public}@", log: log, type: .debug, trackID)
            stopHaptics()
            return
        }

        os_log("Loading haptic pattern for: %{public}@", log: log, type: .info, trackID)

        // Stop any currently playing pattern
        stopHaptics(resetLastID: false)

        // Start the engine if needed
        if !isEngineRunning {
            do {
                try engine.start()
                isEngineRunning = true
            } catch {
                os_log("Engine start failed: %{public}@",
                       log: log, type: .error, String(describing: error))
                return
            }
        }

        do {
            let pattern = try CHHapticPattern(contentsOf: url)
            let newPlayer = try engine.makePlayer(with: pattern)
            try newPlayer.start(atTime: CHHapticTimeImmediate)
            player = newPlayer
            currentPatternID = trackID
            os_log("Haptic pattern started for: %{public}@", log: log, type: .info, trackID)
        } catch {
            os_log("Failed to play haptic pattern: %{public}@",
                   log: log, type: .error, String(describing: error))
        }
    }

    /// Pause the haptic player (e.g. Spotify paused).
    func pauseHaptics() {
        guard let player = player else { return }
        do {
            try player.pause(atTime: CHHapticTimeImmediate)
            os_log("Haptic pattern paused", log: log, type: .debug)
        } catch {
            os_log("Pause failed: %{public}@", log: log, type: .error, String(describing: error))
        }
    }

    /// Resume a paused haptic player (e.g. Spotify resumed).
    func resumeHaptics() {
        guard let player = player else { return }
        do {
            try player.resume(atTime: CHHapticTimeImmediate)
            os_log("Haptic pattern resumed", log: log, type: .debug)
        } catch {
            os_log("Resume failed: %{public}@", log: log, type: .error, String(describing: error))
            // If resume fails, re-play from scratch
            if let id = currentPatternID {
                lastStartedID = nil
                playHaptics(forTrackID: id)
            }
        }
    }

    /// Stop and destroy the current player.
    func stopHaptics(resetLastID: Bool = true) {
        if resetLastID { lastStartedID = nil }
        currentPatternID = nil
        guard let p = player else { return }
        do {
            try p.stop(atTime: CHHapticTimeImmediate)
        } catch {
            os_log("Stop failed (non-fatal): %{public}@",
                   log: log, type: .debug, String(describing: error))
        }
        player = nil
        os_log("Haptic pattern stopped", log: log, type: .debug)
    }

    /// Full teardown – call on app background / termination.
    func teardown() {
        stopHaptics()
        engine?.stop()
        isEngineRunning = false
    }
}
