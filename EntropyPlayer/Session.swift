import SwiftUI
import Combine
import AppKit

// Session persistence: the current configuration (every knob, range, recipe,
// presets, modes, gains, colour) is saved to
// Application Support/EntropyPlayer/session.json (inside the app's sandbox
// container) whenever it changes, and restored on launch — except that
// Post-Gain comes back 6 dB lower, for safety. (The 4-band EQ, Tube knob and
// Hi-Q/Lo-Q are kept in UserDefaults and restore as they were.)
struct SessionState: Codable {
    var macro = 0.0
    var preampDb = 0.0
    var postGainDb = 0.0
    var sensitivity: [String: Double] = [:]
    var ranges: [String: RangeValue] = [:]
    var satRecipe = SaturatorRecipe.classic.name
    var selectedPreset = GlobalPreset.initName
    var selectedEmuPreset = EmulationPreset.offName
    var dynamics = "limiter"
    var vibrato = false
    var vibratoFast = false
    var waveColor = "#35d6d0"
}

extension AppState {
    static let sessionPostGainSafetyDb = 6.0

    private static var sessionURL: URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("EntropyPlayer", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("session.json")
    }

    func currentSession() -> SessionState {
        var s = SessionState()
        s.macro = macroMode == .vibrato ? vibratoCenter : macro
        s.preampDb = preampDb
        // If Post-Gain is still at the safety-lowered launch value, keep
        // saving the user's own setting so the drop doesn't stack per launch.
        if let raw = sessionPostGainRaw, abs(postGainDb - max(-24, raw - Self.sessionPostGainSafetyDb)) < 0.01 {
            s.postGainDb = raw
        } else {
            s.postGainDb = postGainDb
        }
        s.sensitivity = sensitivity; s.ranges = ranges
        s.satRecipe = satRecipe
        s.selectedPreset = selectedPreset; s.selectedEmuPreset = selectedEmuPreset
        s.dynamics = dynamicsMode == .limiter ? "limiter" : "compressor"
        s.vibrato = macroMode == .vibrato; s.vibratoFast = vibratoSpeed == .fast
        s.waveColor = waveColor.hexString
        return s
    }

    /// Restores the last session (Post-Gain lowered by 6 dB). Returns false if none.
    @discardableResult
    func restoreSession() -> Bool {
        guard let url = Self.sessionURL, let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(SessionState.self, from: data) else { return false }
        sensitivity = AppSettings.defaultSensitivities.merging(s.sensitivity) { _, new in new }
        ranges      = AppSettings().ranges.merging(s.ranges) { _, new in new }
        satRecipe   = s.satRecipe
        selectedPreset = s.selectedPreset; selectedEmuPreset = s.selectedEmuPreset
        waveColor   = Color(hex: s.waveColor)
        dynamicsMode = s.dynamics == "compressor" ? .compressor : .limiter
        audio.setDynamics(mode: dynamicsMode)
        preampDb    = s.preampDb
        audio.setPreamp(db: Float(preampDb))
        sessionPostGainRaw = s.postGainDb
        postGainDb  = max(-24, s.postGainDb - Self.sessionPostGainSafetyDb)
        audio.setPostGain(db: Float(postGainDb))
        vibratoSpeed = s.vibratoFast ? .fast : .slow
        setMacro(s.macro)
        if s.vibrato { setMacroMode(.vibrato) }
        return true
    }

    /// Saves whenever anything changes: checked at most every 2 s (the
    /// throttle always delivers the latest change, so nothing is lost) and
    /// written only when the content actually differs.
    func startSessionAutosave() -> AnyCancellable {
        objectWillChange
            .throttle(for: .seconds(2), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.saveSessionIfChanged() }
            }
    }

    func saveSessionIfChanged() {
        guard let url = Self.sessionURL,
              let data = try? JSONEncoder().encode(currentSession()), data != lastSessionData else { return }
        lastSessionData = data
        try? data.write(to: url, options: .atomic)
    }
}
