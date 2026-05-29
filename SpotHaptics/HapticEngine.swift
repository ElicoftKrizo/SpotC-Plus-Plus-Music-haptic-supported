import CoreHaptics
import Foundation
import os.log

private let log = OSLog(subsystem: "com.spotc.SpotHaptics", category: "HapticEngine")

// MARK: - HapticEngineManager

final class HapticEngineManager {

    // ── Singleton ─────────────────────────────────────────────────────────────
    // Swift guarantees thread-safe lazy initialization via an internal
    // dispatch_once equivalent — safe to access from any thread or hook context.
    static let shared = HapticEngineManager()
    private init() { setupEngine() }

    // ── State ─────────────────────────────────────────────────────────────────
    private var engine: CHHapticEngine?
    private var player: CHHapticPatternPlayer?
    private var isEngineRunning = false
    private var currentPatternID: String?
    private var lastStartedID: String?

    // ── Engine Setup ──────────────────────────────────────────────────────────

    private func setupEngine() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            os_log("Device does not support haptics", log: log, type: .info)
            return
        }

        do {
            let eng = try CHHapticEngine()
            eng.playsHapticsOnly    = true
            eng.isAutoShutdownEnabled = false

            eng.stoppedHandler = { [weak self] reason in
                os_log("Haptic engine stopped: %{public}@",
                       log: log, type: .error, String(describing: reason))
                self?.isEngineRunning = false
                self?.player = nil
            }

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
            // engine remains nil; all public API methods guard against this safely.
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

    // ── Bundle URL helper ──────────────────────────────────────────────────────

    private func ahapURL(forTrackID trackID: String) -> URL? {
        // Try the raw track ID first (e.g. "spotify:track:4iV5W9uYEdYUVa79Axb7Rh")
        if let url = Bundle.main.url(forResource: trackID,
                                     withExtension: "ahap",
                                     subdirectory: "CustomHaptics") {
            return url
        }

        // Sanitise: strip the URI prefix and replace non-alphanumeric chars with '_'
        let sanitised = trackID
            .replacingOccurrences(of: "spotify:track:", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined(separator: "_")

        return Bundle.main.url(forResource: sanitised,
                               withExtension: "ahap",
                               subdirectory: "CustomHaptics")
    }

    // ── Public API ────────────────────────────────────────────────────────────

    func playHaptics(forTrackID trackID: String) {
        // De-duplicate: don't restart a pattern that is already running.
        guard trackID != lastStartedID else { return }
        lastStartedID = trackID

        // If hardware/engine is unavailable, fail silently — never crash.
        guard let engine = engine else { return }

        guard let url = ahapURL(forTrackID: trackID) else {
            os_log("No .ahap found for track: %{public}@", log: log, type: .debug, trackID)
            stopHaptics()
            return
        }

        os_log("Loading haptic pattern for: %{public}@", log: log, type: .info, trackID)
        stopHaptics(resetLastID: false)

        // Start engine if it went to sleep (e.g. after background/foreground cycle).
        if !isEngineRunning {
            do {
                try engine.start()
                isEngineRunning = true
            } catch {
                os_log("Engine start failed: %{public}@", log: log, type: .error,
                       String(describing: error))
                return
            }
        }

        do {
            // Load via Data → JSON dictionary for full iOS 13–18 compatibility.
            // (CHHapticPattern(contentsOfURL:) is iOS 16+ only.)
            let data = try Data(contentsOf: url)

            guard let dict = try JSONSerialization.jsonObject(with: data) as? [CHHapticPattern.Key: Any] else {
                os_log("Failed to parse .ahap as dictionary for: %{public}@",
                       log: log, type: .error, trackID)
                return
            }

            let pattern   = try CHHapticPattern(dictionary: dict)
            let newPlayer = try engine.makePlayer(with: pattern)
            try newPlayer.start(atTime: CHHapticTimeImmediate)

            player           = newPlayer
            currentPatternID = trackID
            os_log("Haptic pattern started for: %{public}@", log: log, type: .info, trackID)
        } catch {
            os_log("Failed to play haptic pattern: %{public}@", log: log, type: .error,
                   String(describing: error))
        }
    }

    /// Called on playback pause. Stops the running pattern but retains
    /// currentPatternID so resumeHaptics() can restart the correct track.
    func pauseHaptics() {
        stopHaptics(resetLastID: false)
        os_log("Haptic pattern stopped on pause event", log: log, type: .debug)
    }

    /// Called on playback resume. Re-creates the player from scratch because
    /// CHHapticPatternPlayer has no pause/resume of its own.
    func resumeHaptics() {
        guard let id = currentPatternID else { return }
        lastStartedID = nil   // force playHaptics to restart even for same ID
        playHaptics(forTrackID: id)
    }

    func stopHaptics(resetLastID: Bool = true) {
        if resetLastID { lastStartedID = nil }
        guard let p = player else { return }
        do {
            try p.stop(atTime: CHHapticTimeImmediate)
        } catch {
            // Non-fatal: player may have already finished on its own.
            os_log("Stop error (non-fatal): %{public}@", log: log, type: .debug,
                   String(describing: error))
        }
        player = nil
        os_log("Haptic pattern stopped", log: log, type: .debug)
    }

    /// Full teardown for background entry or app termination.
    func teardown() {
        stopHaptics()
        engine?.stop()
        isEngineRunning = false
        os_log("HapticEngineManager torn down", log: log, type: .info)
    }
}
