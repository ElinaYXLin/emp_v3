import Foundation

// FX presets (Effects section): the knob sensitivities of every control in the
// Effects section, the saturator recipe, the reverb style and a suggested macro position. They
// leave the Emulation page alone (see EmulationPreset below). Range sliders reset to 0–100%.
// INIT is the app's default state; the rest are grouped by vibe for the
// preset menu. Reverb values go through the quadratic reverb knob (see
// AppState.effective). The Lo-Mid EQ is a very wide bell (Q 0.1 at 150 Hz),
// so it's kept low except where a preset is meant to feel thick or warm.
//
// Vibe guidelines:
//   Nostalgic — worn records, old radios: more roll-off, grit, a little grain
//   Calming   — dark, soft and slow: heavy roll-off, blur, little grit
//   Inspiring — open and airy: light roll-off, clean, roomy reverb/shimmer
//   Dreamy    — suspended in time: group delay, blur, grain, shimmer
//   Playful   — character and attitude: odd harmonics, crunchy recipes

struct GlobalPreset {
    enum Vibe: String, CaseIterable {
        case nostalgic = "Nostalgic", calming = "Calming", inspiring = "Inspiring",
             dreamy = "Dreamy", playful = "Playful"
    }

    let name: String
    let vibe: Vibe?          // nil only for INIT
    let macro: Double
    let recipe: String
    let style: String        // reverb style (the Effects page's reverb dropdown)
    let sensitivity: [String: Double]


    // Every control in the Effects section:
    // Color eq sat oddsat rolloff | Temporal Haze shimmer depth reverb | Spectral Haze gd murk blur(Scatter)
    // (+ post tube, which presets have always set). Grain Echo lives in Grit → Texture presets.
    private static func s(eq: Double, sat: Double, odd: Double, roll: Double,
                          gd: Double, blur: Double,
                          rev: Double, shim: Double, depth: Double = 0, tube: Double = 0, murk: Double = 0) -> [String: Double] {
        ["eq": eq, "sat": sat, "oddsat": odd, "rolloff": roll,
         "gd": gd, "murk": murk, "blur": blur,
         "reverb": rev, "shimmer": shim, "depth": depth,
         GlobalPreset.postTubeKey: tube]
    }

    /// Post tube saturator amount (0–100), stored with the knob values but
    /// applied to AppState.postTube rather than as a knob sensitivity.
    static let postTubeKey = "posttube"

    static let initName = "INIT"
    /// "None": every Effects-section knob (and the Tube) to 0; macro, recipe and style untouched.
    static let noneName = "None"
    static let effectKeys = ["eq", "sat", "oddsat", "rolloff", "shimmer", "depth", "reverb", "gd", "murk", "blur"]

    static let initPreset = GlobalPreset(name: initName, vibe: nil, macro: 0, recipe: "Classic", style: "Dark Room", sensitivity:
        s(eq: 24, sat: 35.5, odd: 11, roll: 43, gd: 25, blur: 50, rev: 15, shim: 50))

    static let all: [GlobalPreset] = [
        initPreset,
        // 20 most different of the original 40 kept (farthest-point selection on
        // knob values + recipe + reverb style), plus 20 newer presets spread across
        // more of the Effects knobs. All tested at macro 50 % for resonance,
        // ringing, clicks, harshness, pumping, stereo balance and tonal sanity.
        // ── Nostalgic ──
        .init(name: "Cassette From an Old Friend", vibe: .nostalgic, macro: 60, recipe: "Faded Polaroid", style: "Dark Room", sensitivity:
            s(eq: 6, sat: 30, odd: 12, roll: 55, gd: 15, blur: 20, rev: 15, shim: 10, depth: 13, tube: 15, murk: 20)),
        .init(name: "Midnight Diner Jukebox", vibe: .nostalgic, macro: 60, recipe: "Late Night Diner", style: "Hall", sensitivity:
            s(eq: 15, sat: 40, odd: 40, roll: 50, gd: 15, blur: 15, rev: 30, shim: 10, depth: 13, tube: 20, murk: 20)),
        .init(name: "Snow Day at Grandma's", vibe: .nostalgic, macro: 60, recipe: "Grandma's Kitchen", style: "Cathedral", sensitivity:
            s(eq: 21, sat: 36, odd: 6, roll: 60, gd: 20, blur: 30, rev: 35, shim: 30, depth: 19, tube: 0, murk: 20)),
        .init(name: "Old Photograph in a Shoebox", vibe: .nostalgic, macro: 60, recipe: "Old Photograph", style: "Memory Fog", sensitivity:
            s(eq: 6, sat: 30, odd: 12, roll: 75, gd: 30, blur: 50, rev: 25, shim: 20, depth: 16, tube: 0, murk: 30)),
        .init(name: "Living Room Hi-Fi, 1978", vibe: .nostalgic, macro: 60, recipe: "Warmth", style: "Dark Room", sensitivity:
            s(eq: 35, sat: 45, odd: 5, roll: 30, gd: 0, blur: 0, rev: 20, shim: 0, depth: 20, tube: 25, murk: 25)),
        .init(name: "Birthday Party on VHS", vibe: .nostalgic, macro: 60, recipe: "Faded Polaroid", style: "Dark Room", sensitivity:
            s(eq: 5, sat: 20, odd: 25, roll: 45, gd: 35, blur: 30, rev: 15, shim: 0, depth: 0, tube: 20, murk: 10)),
        .init(name: "Grandpa's Turntable", vibe: .nostalgic, macro: 60, recipe: "Old Photograph", style: "Dark Room", sensitivity:
            s(eq: 25, sat: 40, odd: 10, roll: 50, gd: 10, blur: 10, rev: 25, shim: 0, depth: 30, tube: 10, murk: 35)),
        .init(name: "Mom's Car Stereo, Summer 1996", vibe: .nostalgic, macro: 60, recipe: "Summer '99", style: "Dark Room", sensitivity:
            s(eq: 15, sat: 25, odd: 30, roll: 35, gd: 0, blur: 0, rev: 10, shim: 10, depth: 15, tube: 35, murk: 40)),
        // ── Calming ──
        .init(name: "Campfire Under the Stars", vibe: .calming, macro: 55, recipe: "Campfire Crackle", style: "Hall", sensitivity:
            s(eq: 9, sat: 30, odd: 15, roll: 55, gd: 20, blur: 30, rev: 40, shim: 40, depth: 37, tube: 12, murk: 25)),
        .init(name: "Snowfall Through a Window", vibe: .calming, macro: 60, recipe: "Lullaby", style: "Cathedral", sensitivity:
            s(eq: 15, sat: 20, odd: 0, roll: 75, gd: 25, blur: 42, rev: 50, shim: 45, depth: 38, tube: 12, murk: 25)),
        .init(name: "Forest Cabin, Rain on the Roof", vibe: .calming, macro: 55, recipe: "Rainy Sunday", style: "Dark Room", sensitivity:
            s(eq: 21, sat: 29.5, odd: 4, roll: 65, gd: 25, blur: 35, rev: 35, shim: 30, depth: 34, tube: 7, murk: 25)),
        .init(name: "Library Nap", vibe: .calming, macro: 55, recipe: "Velvet", style: "Memory Fog", sensitivity:
            s(eq: 20, sat: 25, odd: 0, roll: 80, gd: 20, blur: 45, rev: 25, shim: 25, depth: 32, tube: 12, murk: 30)),
        .init(name: "Honey Tea by the Fireplace", vibe: .calming, macro: 55, recipe: "Honey & Smoke", style: "Dark Room", sensitivity:
            s(eq: 30, sat: 35, odd: 0, roll: 40, gd: 0, blur: 0, rev: 30, shim: 20, depth: 45, tube: 10, murk: 30)),
        .init(name: "Rainy Window, Sunday Afternoon", vibe: .calming, macro: 55, recipe: "Rainy Sunday", style: "Memory Fog", sensitivity:
            s(eq: 15, sat: 20, odd: 0, roll: 55, gd: 20, blur: 25, rev: 45, shim: 25, depth: 25, tube: 0, murk: 45)),
        .init(name: "Ocean Hush at Dusk", vibe: .calming, macro: 60, recipe: "Velvet", style: "Cathedral", sensitivity:
            s(eq: 10, sat: 15, odd: 0, roll: 45, gd: 45, blur: 40, rev: 50, shim: 35, depth: 30, tube: 0, murk: 20)),
        .init(name: "Weighted Blanket", vibe: .calming, macro: 60, recipe: "Lullaby", style: "Dark Room", sensitivity:
            s(eq: 40, sat: 30, odd: 0, roll: 35, gd: 0, blur: 0, rev: 15, shim: 0, depth: 50, tube: 15, murk: 60)),
        // ── Inspiring ──
        .init(name: "Mountain Air After Rain", vibe: .inspiring, macro: 60, recipe: "Silk", style: "Hall", sensitivity:
            s(eq: 5, sat: 25, odd: 0, roll: 20, gd: 10, blur: 20, rev: 50, shim: 40, depth: 32, tube: 15, murk: 5)),
        .init(name: "Stadium Lights, Home Team Winning", vibe: .inspiring, macro: 60, recipe: "Punch", style: "Hall", sensitivity:
            s(eq: 12.5, sat: 38, odd: 25.5, roll: 10, gd: 5, blur: 5, rev: 50, shim: 20, depth: 26, tube: 10, murk: 5)),
        .init(name: "Open Road, Windows Down", vibe: .inspiring, macro: 60, recipe: "Summer '99", style: "Plate", sensitivity:
            s(eq: 10, sat: 40, odd: 20, roll: 20, gd: 10, blur: 10, rev: 25, shim: 15, depth: 24, tube: 15, murk: 5)),
        .init(name: "Sunrise Over the Rooftops", vibe: .inspiring, macro: 55, recipe: "Silk", style: "Hall", sensitivity:
            s(eq: 5, sat: 25, odd: 5, roll: 0, gd: 0, blur: 15, rev: 50, shim: 55, depth: 10, tube: 15, murk: 0)),
        .init(name: "First Day of Something New", vibe: .inspiring, macro: 55, recipe: "Sweeten", style: "Plate", sensitivity:
            s(eq: 0, sat: 45, odd: 15, roll: 0, gd: 10, blur: 0, rev: 40, shim: 20, depth: 0, tube: 25, murk: 0)),
        .init(name: "Graduation Morning", vibe: .inspiring, macro: 55, recipe: "Glow", style: "Hall", sensitivity:
            s(eq: 10, sat: 30, odd: 5, roll: 10, gd: 0, blur: 25, rev: 55, shim: 40, depth: 35, tube: 10, murk: 0)),
        .init(name: "Skyscraper Window at Noon", vibe: .inspiring, macro: 60, recipe: "Punch", style: "Plate", sensitivity:
            s(eq: 20, sat: 50, odd: 30, roll: 0, gd: 0, blur: 0, rev: 25, shim: 0, depth: 0, tube: 40, murk: 0)),
        // ── Dreamy ──
        .init(name: "Underwater Summer Dream", vibe: .dreamy, macro: 65, recipe: "Velvet", style: "Memory Fog", sensitivity:
            s(eq: 20, sat: 30, odd: 5, roll: 90, gd: 50, blur: 42, rev: 40, shim: 50, depth: 55, tube: 18, murk: 45)),
        .init(name: "Church Basement Choir Practice", vibe: .dreamy, macro: 60, recipe: "Glow", style: "Cathedral", sensitivity:
            s(eq: 6, sat: 18, odd: 3, roll: 50, gd: 20, blur: 30, rev: 55, shim: 70, depth: 61, tube: 3, murk: 15)),
        .init(name: "Night Drive, Headlights on the Rain", vibe: .dreamy, macro: 60, recipe: "Silk", style: "Tunnel", sensitivity:
            s(eq: 15, sat: 45, odd: 15, roll: 50, gd: 35, blur: 40, rev: 40, shim: 45, depth: 54, tube: 18, murk: 25)),
        .init(name: "Half-Asleep on a Long Flight", vibe: .dreamy, macro: 60, recipe: "First Kiss", style: "Memory Fog", sensitivity:
            s(eq: 15, sat: 30, odd: 5, roll: 75, gd: 35, blur: 42, rev: 35, shim: 45, depth: 54, tube: 8, murk: 30)),
        .init(name: "Memory of a Song You Can't Name", vibe: .dreamy, macro: 60, recipe: "Faded Polaroid", style: "Memory Fog", sensitivity:
            s(eq: 9, sat: 24, odd: 6, roll: 60, gd: 40, blur: 50, rev: 40, shim: 30, depth: 49, tube: 18, murk: 30)),
        .init(name: "Floating in a Swimming Pool at Night", vibe: .dreamy, macro: 65, recipe: "Velvet", style: "Memory Fog", sensitivity:
            s(eq: 15, sat: 20, odd: 0, roll: 60, gd: 55, blur: 45, rev: 40, shim: 45, depth: 45, tube: 0, murk: 55)),
        .init(name: "Kaleidoscope Ceiling", vibe: .dreamy, macro: 60, recipe: "First Kiss", style: "Tunnel", sensitivity:
            s(eq: 0, sat: 20, odd: 10, roll: 15, gd: 30, blur: 50, rev: 30, shim: 45, depth: 20, tube: 0, murk: 0)),
        .init(name: "Lucid Daydream", vibe: .dreamy, macro: 60, recipe: "Glow", style: "Cathedral", sensitivity:
            s(eq: 5, sat: 15, odd: 0, roll: 25, gd: 70, blur: 35, rev: 45, shim: 30, depth: 40, tube: 0, murk: 15)),
        .init(name: "Moon Through Frosted Glass", vibe: .dreamy, macro: 60, recipe: "Silk", style: "Memory Fog", sensitivity:
            s(eq: 10, sat: 10, odd: 0, roll: 70, gd: 25, blur: 55, rev: 60, shim: 50, depth: 55, tube: 0, murk: 30)),
        // ── Playful ──
        .init(name: "First Dance in the Gym", vibe: .playful, macro: 60, recipe: "First Kiss", style: "Hall", sensitivity:
            s(eq: 8, sat: 36, odd: 12, roll: 40, gd: 15, blur: 25, rev: 45, shim: 30, depth: 24, tube: 5, murk: 10)),
        .init(name: "Attic Radio During a Storm", vibe: .playful, macro: 60, recipe: "Crunch", style: "Dark Room", sensitivity:
            s(eq: 0, sat: 32, odd: 40, roll: 80, gd: 20, blur: 20, rev: 20, shim: 25, depth: 22, tube: 35, murk: 30)),
        .init(name: "Last Day of Summer Vacation", vibe: .playful, macro: 60, recipe: "Sweeten", style: "Plate", sensitivity:
            s(eq: 10, sat: 45, odd: 20, roll: 45, gd: 25, blur: 35, rev: 35, shim: 30, depth: 24, tube: 15, murk: 15)),
        .init(name: "Tin-Can Telephone", vibe: .playful, macro: 65, recipe: "Crunch", style: "Tunnel", sensitivity:
            s(eq: 0, sat: 24, odd: 36, roll: 85, gd: 5, blur: 10, rev: 5, shim: 0, depth: 15, tube: 35, murk: 10)),
        .init(name: "Boombox in a Summer Camp", vibe: .playful, macro: 65, recipe: "Summer '99", style: "Dark Room", sensitivity:
            s(eq: 20, sat: 35, odd: 50, roll: 20, gd: 0, blur: 0, rev: 20, shim: 0, depth: 0, tube: 45, murk: 20)),
        .init(name: "Arcade at the Mall, 1989", vibe: .playful, macro: 60, recipe: "Crunch", style: "Tunnel", sensitivity:
            s(eq: 0, sat: 25, odd: 60, roll: 30, gd: 15, blur: 35, rev: 30, shim: 15, depth: 0, tube: 30, murk: 0)),
        .init(name: "Bubblegum Pop Radio", vibe: .playful, macro: 60, recipe: "Sweeten", style: "Plate", sensitivity:
            s(eq: 10, sat: 40, odd: 35, roll: 5, gd: 0, blur: 10, rev: 35, shim: 30, depth: 25, tube: 20, murk: 10)),
        .init(name: "Cardboard Box Fort", vibe: .playful, macro: 60, recipe: "Grandma's Kitchen", style: "Dark Room", sensitivity:
            s(eq: 45, sat: 30, odd: 20, roll: 65, gd: 0, blur: 0, rev: 10, shim: 0, depth: 30, tube: 25, murk: 35)),
    ]

    static func presets(in vibe: Vibe) -> [GlobalPreset] { all.filter { $0.vibe == vibe } }

    static func named(_ name: String) -> GlobalPreset? { all.first { $0.name == name } }
}

// MARK: - Emulation presets

// Emulation presets (Emulation page): Choir, Tape and Tube Amp knob
// sensitivities only, so they combine freely with any FX preset. Same vibes
// as the FX presets. Note Wobble acts through the Even Sat stage, so it only
// does something when the FX side has some Even Sat.
struct EmulationPreset {
    typealias Vibe = GlobalPreset.Vibe
    let name: String
    let vibe: Vibe?          // nil only for None
    let sensitivity: [String: Double]

    static let keys = ["voices", "detune", "cdelay", "cvib", "hyst", "sag", "wow", "erase",
                       "fuzz", "bloom", "fur", "wobble"]

    // Keys: Choir voices detune delay vibrato | Tape hyst sag wow erase | Tube fuzz bloom fur wobble
    private static func s(_ voices: Double, _ detune: Double, _ delay: Double, _ vib: Double,
                          _ hyst: Double, _ sag: Double, _ wow: Double, _ erase: Double,
                          _ fuzz: Double, _ bloom: Double, _ fur: Double, _ wobble: Double) -> [String: Double] {
        ["voices": voices, "detune": detune, "cdelay": delay, "cvib": vib,
         "hyst": hyst, "sag": sag, "wow": wow, "erase": erase,
         "fuzz": fuzz, "bloom": bloom, "fur": fur, "wobble": wobble]
    }

    static let offName = "None"
    static let off = EmulationPreset(name: offName, vibe: nil, sensitivity: s(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    // Tape (hyst sag wow erase) and Tube (fuzz bloom) values were scaled down
    // (×0.45 / 0.35 / 0.25 / 0.6, ×0.5 / 0.5) when those effects were made much
    // stronger, so each preset lands a little stronger than it originally sounded.
    static let all: [EmulationPreset] = [
        off,
        // Every preset layers at least two of Choir, Tape and Tube Amp.
        //                                                        choir v  det dly vib   tape hys sag wow ers   tube fz blm fur wob
        // ── Nostalgic ──
        .init(name: "Church Choir on a Worn Cassette", vibe: .nostalgic, sensitivity: s(45, 30, 40, 25,  20, 10, 12, 21,   0,  5,  5, 15)),
        .init(name: "Garage Band Demo Tape",           vibe: .nostalgic, sensitivity: s(15, 25, 20, 10,  25, 14,  8, 18,  20, 15, 15, 20)),
        .init(name: "Wedding Video, 1994",             vibe: .nostalgic, sensitivity: s(30, 20, 30, 20,  16,  9, 11, 18,   5, 10,  0, 15)),
        .init(name: "Jukebox in a Smoky Bar",          vibe: .nostalgic, sensitivity: s(10, 15, 15,  5,  18, 10,  6, 15,  15, 18, 35, 25)),
        // ── Calming ──
        .init(name: "Lullaby on a Valve Radio",        vibe: .calming,   sensitivity: s(35, 15, 40, 10,  11,  4,  5, 15,   5, 18,  0, 15)),
        .init(name: "Monks by the Fireplace",          vibe: .calming,   sensitivity: s(55, 20, 60, 10,   9,  2,  2,  9,   8, 20, 10, 10)),
        .init(name: "Slow Tide Reel",                  vibe: .calming,   sensitivity: s(40, 25, 55, 15,  14,  5,  9, 12,   0, 12,  0, 20)),
        .init(name: "Velvet Living Room Choir",        vibe: .calming,   sensitivity: s(30, 15, 35, 10,  11,  4,  2, 15,  10, 20,  0, 15)),
        // ── Inspiring ──
        .init(name: "Cathedral Choir to Tape",         vibe: .inspiring, sensitivity: s(85, 35, 60, 25,  16,  4,  1,  6,   0,  8,  0,  0)),
        .init(name: "Gospel Hall Through a Valve Amp", vibe: .inspiring, sensitivity: s(70, 45, 35, 45,   7,  0,  0,  3,  12, 18,  5, 10)),
        .init(name: "Stadium Anthem Master",           vibe: .inspiring, sensitivity: s(100, 25, 25, 20,  18,  5,  2,  9,  10, 15,  0,  0)),
        .init(name: "Studio Two, Full Band",           vibe: .inspiring, sensitivity: s(25, 20, 20, 15,  20,  5,  2,  9,   8, 12,  0,  5)),
        // ── Dreamy ──
        .init(name: "Choir Lost in a Melting Reel",    vibe: .dreamy,    sensitivity: s(75, 60, 80, 30,  14, 12, 19, 12,   0,  8,  0, 30)),
        .init(name: "Ghosts in the Amp",               vibe: .dreamy,    sensitivity: s(50, 70, 70, 55,   4,  0, 10,  6,  18, 15, 15, 45)),
        .init(name: "Underwater Valve Choir",          vibe: .dreamy,    sensitivity: s(45, 40, 60, 25,   9,  7, 10, 21,  22, 22, 10, 60)),
        .init(name: "Sleepwalking Tape Ensemble",      vibe: .dreamy,    sensitivity: s(60, 50, 65, 35,  16, 10, 15, 18,   5, 10,  5, 35)),
        // ── Playful ──
        .init(name: "Barbershop on a Wobbly Deck",     vibe: .playful,   sensitivity: s(30, 40, 20, 70,  11,  7, 14,  6,   5,  0,  0, 20)),
        .init(name: "Fuzz Bass Karaoke",               vibe: .playful,   sensitivity: s(40, 50, 25, 40,   9,  4,  0,  0,  35, 20, 25, 10)),
        .init(name: "Kazoo Choir Meets Fuzz Pedal",    vibe: .playful,   sensitivity: s(60, 85, 30, 90,   0,  0,  8,  6,  25, 10, 20,  0)),
        .init(name: "Crackle, Pop & Sing-Along",       vibe: .playful,   sensitivity: s(35, 30, 30, 30,  14,  9,  8, 12,  22, 15, 70, 30)),
    ]

    static func presets(in vibe: Vibe) -> [EmulationPreset] { all.filter { $0.vibe == vibe } }
    static func named(_ name: String) -> EmulationPreset? { all.first { $0.name == name } }
}

// MARK: - Texture presets

// Texture presets (Blur + Grit sections): every Blur and Grit knob, nothing
// else, so they combine freely with any FX and Emulation preset.
struct TexturePreset {
    typealias Vibe = GlobalPreset.Vibe
    let name: String
    let vibe: Vibe?          // nil only for Off
    let sensitivity: [String: Double]

    static let keys = ["bsmear", "bwash", "bsmoke", "bunder", "bswell", "bdiffuse",
                       "bits", "softclip", "gnoise", "rattle", "corpus", "grain"]

    // Blur: smear wash smoke underwater swell diffuse | Grit: bits softclip grain(dust) rattle corpus grainEcho
    private static func s(_ smear: Double, _ wash: Double, _ smoke: Double, _ under: Double, _ swell: Double, _ diffuse: Double,
                          _ bits: Double, _ clip: Double, _ dust: Double, _ rattle: Double, _ corpus: Double, _ echo: Double) -> [String: Double] {
        ["bsmear": smear, "bwash": wash, "bsmoke": smoke, "bunder": under, "bswell": swell, "bdiffuse": diffuse,
         "bits": bits, "softclip": clip, "gnoise": dust, "rattle": rattle, "corpus": corpus, "grain": echo]
    }

    static let offName = "None"
    static let off = TexturePreset(name: offName, vibe: nil, sensitivity: s(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    static let all: [TexturePreset] = [
        off,
        //                                                         blur smr wsh smk und swl dif   grit bit clp dst rtl cor ech
        // ── Nostalgic ── dust, wood and a little melt
        .init(name: "Dusty Vinyl Sleeve",          vibe: .nostalgic, sensitivity: s(10, 15,  0,  0, 10, 30,  25, 10, 45, 10, 20, 15)),
        .init(name: "Worn VHS Tracking",           vibe: .nostalgic, sensitivity: s(20, 10, 10,  0,  0, 40,  40, 15, 30, 20,  0, 20)),
        .init(name: "Shoebox of Polaroids",        vibe: .nostalgic, sensitivity: s(25, 30, 10, 10, 20, 30,  15,  5, 30,  0, 15, 35)),
        .init(name: "Grandfather's Wood Radio",    vibe: .nostalgic, sensitivity: s(10, 10,  0, 15, 10, 20,  20, 25, 25, 15, 50, 10)),
        // ── Calming ── soft and blurred, almost no grit
        .init(name: "Rain on a Fogged Window",     vibe: .calming,   sensitivity: s(30, 40, 20, 15, 35, 40,   0,  0, 20,  0, 10, 25)),
        .init(name: "Wool Blanket",                vibe: .calming,   sensitivity: s(35, 30,  0, 25, 40, 30,   0, 15, 10,  0, 25, 15)),
        .init(name: "Candlelit Haze",              vibe: .calming,   sensitivity: s(20, 45, 15, 10, 30, 35,   5,  0, 15,  0, 10, 20)),
        .init(name: "Sea Glass",                   vibe: .calming,   sensitivity: s(25, 35, 10, 35, 25, 50,   0,  0, 10,  0,  0, 30)),
        // ── Inspiring ── wide and clean
        .init(name: "Morning Light Bloom",         vibe: .inspiring, sensitivity: s(10, 20,  0,  0, 30, 45,   0,  0,  5,  0,  0, 10)),
        .init(name: "Open Sky Shimmer",            vibe: .inspiring, sensitivity: s(15, 25,  0,  0, 20, 60,   0,  0,  0,  0,  0, 15)),
        .init(name: "Clean Linen",                 vibe: .inspiring, sensitivity: s( 5, 10,  0,  0, 15, 30,   5,  0,  5,  0, 10,  5)),
        .init(name: "Wide Horizon",                vibe: .inspiring, sensitivity: s(20, 30,  5,  0, 35, 70,   0,  0,  5,  0,  0, 20)),
        // ── Dreamy ── heavy blur, memory echoes
        .init(name: "Melting Clocks",              vibe: .dreamy,    sensitivity: s(60, 45, 15, 20, 50, 50,   0,  0, 10,  0,  0, 40)),
        .init(name: "Deep End of the Pool",        vibe: .dreamy,    sensitivity: s(30, 30, 10, 65, 30, 40,   0, 10, 10,  0,  0, 30)),
        .init(name: "Smoke Rings",                 vibe: .dreamy,    sensitivity: s(25, 25, 55, 10, 30, 45,  10,  0, 20,  0,  0, 35)),
        .init(name: "Half-Remembered Dream",       vibe: .dreamy,    sensitivity: s(45, 55, 20, 25, 45, 60,   5,  0, 15,  0,  0, 50)),
        // ── Playful ── crunchy, sandy, rattly
        .init(name: "8-Bit Afternoon",             vibe: .playful,   sensitivity: s( 0,  0,  0,  0,  0, 20,  70, 20, 15, 10,  0, 10)),
        .init(name: "Rattling Toy Box",            vibe: .playful,   sensitivity: s(10, 10,  0,  0, 10, 30,  20, 15, 20, 60, 40, 15)),
        .init(name: "Broken Boombox",              vibe: .playful,   sensitivity: s( 5, 10,  0,  0,  0, 25,  50, 45, 40, 35, 15, 10)),
        .init(name: "Sandbox Static",              vibe: .playful,   sensitivity: s(10, 15, 20,  0, 10, 35,  40, 10, 60, 15, 10, 20)),
    ]

    static func presets(in vibe: Vibe) -> [TexturePreset] { all.filter { $0.vibe == vibe } }
    static func named(_ name: String) -> TexturePreset? { all.first { $0.name == name } }
}

// MARK: - Suites

// Suites set the FX, Emulation and Texture presets together — one scene.
struct SuitePreset {
    typealias Vibe = GlobalPreset.Vibe
    let name: String
    let vibe: Vibe
    let fx: String, emulation: String, texture: String

    static let noneName = "None"
    /// Shown when the FX / Emulation / Texture presets no longer match one suite.
    static let customName = "Custom"

    static let all: [SuitePreset] = [
        // ── Nostalgic ──
        .init(name: "Opening a Dust-Covered Childhood Scrapbook", vibe: .nostalgic,
              fx: "Old Photograph in a Shoebox", emulation: "Wedding Video, 1994", texture: "Shoebox of Polaroids"),
        .init(name: "Grandpa's Record Player on a Sunday", vibe: .nostalgic,
              fx: "Grandpa's Turntable", emulation: "Jukebox in a Smoky Bar", texture: "Grandfather's Wood Radio"),
        .init(name: "Rewinding the Tape of Your 5th Birthday", vibe: .nostalgic,
              fx: "Birthday Party on VHS", emulation: "Wedding Video, 1994", texture: "Worn VHS Tracking"),
        .init(name: "Mixtape From a Friend Who Moved Away", vibe: .nostalgic,
              fx: "Cassette From an Old Friend", emulation: "Church Choir on a Worn Cassette", texture: "Dusty Vinyl Sleeve"),
        // ── Calming ──
        .init(name: "Rainy Afternoon Nap on the Couch", vibe: .calming,
              fx: "Rainy Window, Sunday Afternoon", emulation: "Velvet Living Room Choir", texture: "Rain on a Fogged Window"),
        .init(name: "Hot Cocoa by a Crackling Fire", vibe: .calming,
              fx: "Honey Tea by the Fireplace", emulation: "Monks by the Fireplace", texture: "Candlelit Haze"),
        .init(name: "The Sea From a Beach House Bedroom", vibe: .calming,
              fx: "Ocean Hush at Dusk", emulation: "Slow Tide Reel", texture: "Sea Glass"),
        .init(name: "Car Ride Home With Mom, Half Asleep", vibe: .calming,
              fx: "Mom's Car Stereo, Summer 1996", emulation: "Lullaby on a Valve Radio", texture: "Wool Blanket"),
        .init(name: "Snow Falling Outside Grandma's Window", vibe: .calming,
              fx: "Snow Day at Grandma's", emulation: "Lullaby on a Valve Radio", texture: "Wool Blanket"),
        // ── Inspiring ──
        .init(name: "Watching the Sunrise From the Car Roof", vibe: .inspiring,
              fx: "Sunrise Over the Rooftops", emulation: "Studio Two, Full Band", texture: "Morning Light Bloom"),
        .init(name: "Walking Out of the Last Exam", vibe: .inspiring,
              fx: "First Day of Something New", emulation: "Stadium Anthem Master", texture: "Open Sky Shimmer"),
        .init(name: "Hilltop After the Rain", vibe: .inspiring,
              fx: "Mountain Air After Rain", emulation: "Cathedral Choir to Tape", texture: "Wide Horizon"),
        .init(name: "Fresh Sheets on a Saturday Morning", vibe: .inspiring,
              fx: "Graduation Morning", emulation: "Gospel Hall Through a Valve Amp", texture: "Clean Linen"),
        // ── Dreamy ──
        .init(name: "Floating on Your Back in a Summer Pool", vibe: .dreamy,
              fx: "Floating in a Swimming Pool at Night", emulation: "Underwater Valve Choir", texture: "Deep End of the Pool"),
        .init(name: "A Dream You Almost Remember", vibe: .dreamy,
              fx: "Memory of a Song You Can't Name", emulation: "Sleepwalking Tape Ensemble", texture: "Half-Remembered Dream"),
        .init(name: "Midnight Drive Through a Sleeping City", vibe: .dreamy,
              fx: "Night Drive, Headlights on the Rain", emulation: "Ghosts in the Amp", texture: "Smoke Rings"),
        .init(name: "A Long Afternoon Where the Clocks Melt", vibe: .dreamy,
              fx: "Half-Asleep on a Long Flight", emulation: "Choir Lost in a Melting Reel", texture: "Melting Clocks"),
        // ── Playful ──
        .init(name: "Playing Games on an Old TV After School", vibe: .playful,
              fx: "Arcade at the Mall, 1989", emulation: "Garage Band Demo Tape", texture: "8-Bit Afternoon"),
        .init(name: "Toy Box in the Attic During a Storm", vibe: .playful,
              fx: "Attic Radio During a Storm", emulation: "Crackle, Pop & Sing-Along", texture: "Rattling Toy Box"),
        .init(name: "Boombox at the Summer Camp Talent Show", vibe: .playful,
              fx: "Boombox in a Summer Camp", emulation: "Kazoo Choir Meets Fuzz Pedal", texture: "Broken Boombox"),
    ]

    static func presets(in vibe: Vibe) -> [SuitePreset] { all.filter { $0.vibe == vibe } }
    static func named(_ name: String) -> SuitePreset? { all.first { $0.name == name } }
}
