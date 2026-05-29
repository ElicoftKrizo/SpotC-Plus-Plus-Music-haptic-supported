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
    private var lastStartedID: String?

    // ── Engine Setup ─────────────────────────────────────────────────────────

    private func setupEngine() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            os_log("Device does not support haptics", log: log, type: .info)
            return
        }

        do {
            let eng = try CHHapticEngine()
            eng.playsHapticsOnly = true          
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

    private func ahapURL(forTrackID trackID: String) -> URL? {
        if let url = Bundle.main.url(
            forResource: trackID,
            withExtension: "ahap",
            subdirectory: "CustomHaptics"
        ) {
            return url
        }

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

    func playHaptics(forTrackID trackID: String) {
        guard trackID != lastStartedID else { return }
        lastStartedID = trackID

        guard let engine = engine else { return }
        guard let url = ahapURL(forTrackID: trackID) else {
            os_log("No .ahap found for track: %{public}@", log: log, type: .debug, trackID)
            stopHaptics()
            return
        }

        os_log("Loading haptic pattern for: %{public}@", log: log, type: .info, trackID)
        stopHaptics(resetLastID: false)

        if !isEngineRunning {
            do {
                try engine.start()
                isEngineRunning = true
            } catch {
                os_log("Engine start failed: %{public}@", log: log, type: .error, String(describing: error))
                return
            }
        }

        do {
            // FIX: Read as Data + JSON dictionary to make it work on iOS 13-15
            let data = try Data(contentsOf: url)
            let dict = try JSONSerialization.jsonObject(with: data, options: []) as? [CHHapticPattern.Key: Any] ?? [:]
            let pattern = try CHHapticPattern(dictionary: dict)
            
            let newPlayer = try engine.makePlayer(with: pattern)
            try newPlayer.start(atTime: CHHapticTimeImmediate)
            player = newPlayer
            currentPatternID = trackID
            os_log("Haptic pattern started for: %{public}@", log: log, type: .info, trackID)
        } catch {
            os_log("Failed to play haptic pattern: %{public}@", log: log, type: .error, String(describing: error))
        }
    }

    func pauseHaptics() {
        // FIX: CHHapticPatternPlayer does not have a pause function. Stop it instead.
        stopHaptics(resetLastID: false)
        os_log("Haptic pattern stopped on pause event", log: log, type: .debug)
    }

    func resumeHaptics() {
        // FIX: Re-initialize and start the track player from scratch on resume
        if let id = currentPatternID {
            lastStartedID = nil
            playHaptics(forTrackID: id)
        }
    }

    func stopHaptics(resetLastID: Bool = true) {
        if resetLastID { lastStartedID = nil }
        guard let p = player else { return }
        do {
            try p.stop(atTime: CHHapticTimeImmediate)
        } catch {
            os_log("Stop failed (non-fatal): %{public}@", log: log, type: .debug, String(describing: error))
        }
        player = nil
        os_log("Haptic pattern stopped", log: log, type: .debug)
    }

    func teardown() {
        stopHaptics()
        engine?.stop()
        isEngineRunning = false
    }
}
