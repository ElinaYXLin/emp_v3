import Foundation

// FX presets (Effects page): the knob sensitivities of every effect on the
// Effects page, the saturator recipe and a suggested macro position. They
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
    let sensitivity: [String: Double]

    // Keys: eq sat oddsat rolloff | gd gdrand blur | reverb shimmer grain depth | post tube
    private static func s(eq: Double, sat: Double, odd: Double, roll: Double,
                          gd: Double, gdr: Double, blur: Double,
                          rev: Double, shim: Double, grain: Double, depth: Double = 0, tube: Double = 0) -> [String: Double] {
        ["eq": eq, "sat": sat, "oddsat": odd, "rolloff": roll,
         "gd": gd, "gdrand": gdr, "blur": blur,
         "reverb": rev, "shimmer": shim, "grain": grain, "depth": depth,
         GlobalPreset.postTubeKey: tube]
    }

    /// Post tube saturator amount (0–100), stored with the knob values but
    /// applied to AppState.postTube rather than as a knob sensitivity.
    static let postTubeKey = "posttube"

    static let initName = "INIT"

    static let initPreset = GlobalPreset(name: initName, vibe: nil, macro: 0, recipe: "Classic", sensitivity:
        s(eq: 24, sat: 35.5, odd: 11, roll: 43, gd: 25, gdr: 36, blur: 50, rev: 15, shim: 50, grain: 50))

    static let all: [GlobalPreset] = [
        initPreset,
        // ── Nostalgic ──
        .init(name: "Grandpa's Favorite Record", vibe: .nostalgic, macro: 60, recipe: "Old Photograph", sensitivity:
            s(eq: 18, sat: 33, odd: 9, roll: 70, gd: 15, gdr: 20, blur: 25, rev: 20, shim: 15, grain: 20, depth: 14, tube: 0)),
        .init(name: "Walkman on the School Bus", vibe: .nostalgic, macro: 60, recipe: "Vintagize", sensitivity:
            s(eq: 0, sat: 24, odd: 15, roll: 60, gd: 10, gdr: 40, blur: 10, rev: 5, shim: 0, grain: 15, depth: 10, tube: 15)),
        .init(name: "Cassette From an Old Friend", vibe: .nostalgic, macro: 60, recipe: "Faded Polaroid", sensitivity:
            s(eq: 6, sat: 30, odd: 12, roll: 55, gd: 15, gdr: 35, blur: 20, rev: 15, shim: 10, grain: 35, depth: 13, tube: 15)),
        .init(name: "Midnight Diner Jukebox", vibe: .nostalgic, macro: 60, recipe: "Late Night Diner", sensitivity:
            s(eq: 15, sat: 40, odd: 40, roll: 50, gd: 15, gdr: 15, blur: 15, rev: 30, shim: 10, grain: 10, depth: 13, tube: 20)),
        .init(name: "Mom's Car Radio, 1996", vibe: .nostalgic, macro: 60, recipe: "Summer '99", sensitivity:
            s(eq: 6, sat: 21, odd: 21, roll: 60, gd: 10, gdr: 20, blur: 10, rev: 10, shim: 0, grain: 10, depth: 10, tube: 25)),
        .init(name: "Snow Day at Grandma's", vibe: .nostalgic, macro: 60, recipe: "Grandma's Kitchen", sensitivity:
            s(eq: 21, sat: 36, odd: 6, roll: 60, gd: 20, gdr: 20, blur: 30, rev: 35, shim: 30, grain: 25, depth: 19, tube: 0)),
        .init(name: "Old Photograph in a Shoebox", vibe: .nostalgic, macro: 60, recipe: "Old Photograph", sensitivity:
            s(eq: 6, sat: 30, odd: 12, roll: 75, gd: 30, gdr: 40, blur: 50, rev: 25, shim: 20, grain: 45, depth: 16, tube: 0)),
        .init(name: "VHS Tape of a Birthday Party", vibe: .nostalgic, macro: 60, recipe: "Faded Polaroid", sensitivity:
            s(eq: 0, sat: 27, odd: 18, roll: 70, gd: 15, gdr: 55, blur: 25, rev: 15, shim: 5, grain: 30, depth: 12, tube: 15)),
        .init(name: "Arcade at the Mall, 1989", vibe: .nostalgic, macro: 60, recipe: "Crunch", sensitivity:
            s(eq: 10, sat: 40, odd: 40, roll: 45, gd: 10, gdr: 20, blur: 10, rev: 30, shim: 5, grain: 20, depth: 12, tube: 30)),
        .init(name: "Sleepover Mixtape", vibe: .nostalgic, macro: 60, recipe: "Vintagize", sensitivity:
            s(eq: 9, sat: 27, odd: 12, roll: 60, gd: 15, gdr: 35, blur: 20, rev: 20, shim: 10, grain: 30, depth: 13, tube: 15)),
        .init(name: "Grandma's Kitchen Radio", vibe: .nostalgic, macro: 60, recipe: "Grandma's Kitchen", sensitivity:
            s(eq: 18, sat: 30, odd: 12, roll: 70, gd: 15, gdr: 20, blur: 20, rev: 20, shim: 10, grain: 15, depth: 13, tube: 0)),
        // ── Calming ──
        .init(name: "Rainy Window, Sunday Afternoon", vibe: .calming, macro: 55, recipe: "Rainy Sunday", sensitivity:
            s(eq: 10.5, sat: 31.5, odd: 3.5, roll: 65, gd: 25, gdr: 30, blur: 40, rev: 35, shim: 35, grain: 30, depth: 36, tube: 7)),
        .init(name: "Campfire Under the Stars", vibe: .calming, macro: 55, recipe: "Campfire Crackle", sensitivity:
            s(eq: 9, sat: 30, odd: 15, roll: 55, gd: 20, gdr: 25, blur: 30, rev: 40, shim: 40, grain: 25, depth: 37, tube: 12)),
        .init(name: "Lullaby From the Next Room", vibe: .calming, macro: 60, recipe: "Lullaby", sensitivity:
            s(eq: 25, sat: 30, odd: 0, roll: 85, gd: 50, gdr: 30, blur: 55, rev: 45, shim: 45, grain: 40, depth: 38, tube: 12)),
        .init(name: "Honey Tea by the Fireplace", vibe: .calming, macro: 55, recipe: "Honey & Smoke", sensitivity:
            s(eq: 21, sat: 36, odd: 6, roll: 55, gd: 20, gdr: 15, blur: 25, rev: 25, shim: 35, grain: 15, depth: 36, tube: 0)),
        .init(name: "Falling Asleep to the Radio", vibe: .calming, macro: 65, recipe: "Lullaby", sensitivity:
            s(eq: 25, sat: 35, odd: 10, roll: 80, gd: 45, gdr: 35, blur: 65, rev: 45, shim: 50, grain: 55, depth: 40, tube: 12)),
        .init(name: "Ocean Hush at Dusk", vibe: .calming, macro: 60, recipe: "Velvet", sensitivity:
            s(eq: 20, sat: 25, odd: 0, roll: 70, gd: 40, gdr: 45, blur: 55, rev: 45, shim: 40, grain: 35, depth: 37, tube: 12)),
        .init(name: "Tea Kettle Morning", vibe: .calming, macro: 55, recipe: "Warmth", sensitivity:
            s(eq: 18, sat: 27, odd: 4.5, roll: 55, gd: 15, gdr: 20, blur: 25, rev: 30, shim: 20, grain: 15, depth: 31, tube: 7)),
        .init(name: "Snowfall Through a Window", vibe: .calming, macro: 60, recipe: "Lullaby", sensitivity:
            s(eq: 15, sat: 20, odd: 0, roll: 75, gd: 30, gdr: 30, blur: 60, rev: 50, shim: 45, grain: 40, depth: 38, tube: 12)),
        .init(name: "Forest Cabin, Rain on the Roof", vibe: .calming, macro: 55, recipe: "Rainy Sunday", sensitivity:
            s(eq: 21, sat: 29.5, odd: 4, roll: 65, gd: 25, gdr: 30, blur: 35, rev: 35, shim: 30, grain: 25, depth: 34, tube: 7)),
        .init(name: "Library Nap", vibe: .calming, macro: 55, recipe: "Velvet", sensitivity:
            s(eq: 20, sat: 25, odd: 0, roll: 80, gd: 20, gdr: 20, blur: 45, rev: 25, shim: 25, grain: 20, depth: 32, tube: 12)),
        // ── Inspiring ──
        .init(name: "Sunrise Over the Rooftops", vibe: .inspiring, macro: 55, recipe: "Silk", sensitivity:
            s(eq: 10, sat: 30, odd: 5, roll: 15, gd: 10, gdr: 20, blur: 15, rev: 45, shim: 35, grain: 20, depth: 30, tube: 15)),
        .init(name: "First Day of Something New", vibe: .inspiring, macro: 55, recipe: "Sweeten", sensitivity:
            s(eq: 5, sat: 35, odd: 10, roll: 10, gd: 5, gdr: 15, blur: 10, rev: 40, shim: 25, grain: 15, depth: 28, tube: 15)),
        .init(name: "Mountain Air After Rain", vibe: .inspiring, macro: 60, recipe: "Silk", sensitivity:
            s(eq: 5, sat: 25, odd: 0, roll: 20, gd: 10, gdr: 20, blur: 20, rev: 50, shim: 40, grain: 25, depth: 32, tube: 15)),
        .init(name: "Stadium Lights, Home Team Winning", vibe: .inspiring, macro: 60, recipe: "Punch", sensitivity:
            s(eq: 12.5, sat: 38, odd: 25.5, roll: 10, gd: 5, gdr: 10, blur: 5, rev: 50, shim: 20, grain: 10, depth: 26, tube: 10)),
        .init(name: "Open Road, Windows Down", vibe: .inspiring, macro: 60, recipe: "Summer '99", sensitivity:
            s(eq: 10, sat: 40, odd: 20, roll: 20, gd: 10, gdr: 25, blur: 10, rev: 25, shim: 15, grain: 15, depth: 24, tube: 15)),
        .init(name: "Graduation Morning", vibe: .inspiring, macro: 55, recipe: "Glow", sensitivity:
            s(eq: 6, sat: 21, odd: 6, roll: 15, gd: 10, gdr: 15, blur: 15, rev: 55, shim: 45, grain: 20, depth: 34, tube: 5)),
        // ── Dreamy ──
        .init(name: "Underwater Summer Dream", vibe: .dreamy, macro: 65, recipe: "Velvet", sensitivity:
            s(eq: 20, sat: 30, odd: 5, roll: 90, gd: 70, gdr: 60, blur: 60, rev: 40, shim: 50, grain: 50, depth: 55, tube: 18)),
        .init(name: "Church Basement Choir Practice", vibe: .dreamy, macro: 60, recipe: "Glow", sensitivity:
            s(eq: 6, sat: 18, odd: 3, roll: 50, gd: 20, gdr: 15, blur: 30, rev: 55, shim: 70, grain: 20, depth: 61, tube: 3)),
        .init(name: "Night Drive, Headlights on the Rain", vibe: .dreamy, macro: 60, recipe: "Silk", sensitivity:
            s(eq: 15, sat: 45, odd: 15, roll: 50, gd: 35, gdr: 40, blur: 40, rev: 40, shim: 45, grain: 35, depth: 54, tube: 18)),
        .init(name: "Floating in a Swimming Pool at Night", vibe: .dreamy, macro: 65, recipe: "Velvet", sensitivity:
            s(eq: 20, sat: 25, odd: 5, roll: 80, gd: 60, gdr: 55, blur: 55, rev: 45, shim: 50, grain: 55, depth: 55, tube: 18)),
        .init(name: "Half-Asleep on a Long Flight", vibe: .dreamy, macro: 60, recipe: "First Kiss", sensitivity:
            s(eq: 15, sat: 30, odd: 5, roll: 75, gd: 35, gdr: 40, blur: 60, rev: 35, shim: 45, grain: 50, depth: 54, tube: 8)),
        .init(name: "Aurora Over an Empty Field", vibe: .dreamy, macro: 60, recipe: "Glow", sensitivity:
            s(eq: 6.5, sat: 16, odd: 0, roll: 50, gd: 45, gdr: 50, blur: 55, rev: 50, shim: 65, grain: 45, depth: 60, tube: 8)),
        .init(name: "Memory of a Song You Can't Name", vibe: .dreamy, macro: 60, recipe: "Faded Polaroid", sensitivity:
            s(eq: 9, sat: 24, odd: 6, roll: 60, gd: 40, gdr: 60, blur: 50, rev: 40, shim: 30, grain: 70, depth: 49, tube: 18)),
        // ── Playful ──
        .init(name: "Boombox in a Summer Camp", vibe: .playful, macro: 65, recipe: "Summer '99", sensitivity:
            s(eq: 9, sat: 30, odd: 27, roll: 30, gd: 10, gdr: 20, blur: 10, rev: 25, shim: 0, grain: 20, depth: 15, tube: 20)),
        .init(name: "First Dance in the Gym", vibe: .playful, macro: 60, recipe: "First Kiss", sensitivity:
            s(eq: 8, sat: 36, odd: 12, roll: 40, gd: 15, gdr: 20, blur: 25, rev: 45, shim: 30, grain: 35, depth: 24, tube: 5)),
        .init(name: "Attic Radio During a Storm", vibe: .playful, macro: 60, recipe: "Crunch", sensitivity:
            s(eq: 0, sat: 32, odd: 40, roll: 80, gd: 20, gdr: 50, blur: 20, rev: 20, shim: 25, grain: 40, depth: 22, tube: 35)),
        .init(name: "Last Day of Summer Vacation", vibe: .playful, macro: 60, recipe: "Sweeten", sensitivity:
            s(eq: 10, sat: 45, odd: 20, roll: 45, gd: 25, gdr: 40, blur: 35, rev: 35, shim: 30, grain: 50, depth: 24, tube: 15)),
        .init(name: "Roller Rink Saturday", vibe: .playful, macro: 60, recipe: "Summer '99", sensitivity:
            s(eq: 15, sat: 45, odd: 35, roll: 30, gd: 10, gdr: 20, blur: 10, rev: 45, shim: 15, grain: 20, depth: 20, tube: 15)),
        .init(name: "Tin-Can Telephone", vibe: .playful, macro: 65, recipe: "Crunch", sensitivity:
            s(eq: 0, sat: 24, odd: 36, roll: 85, gd: 5, gdr: 20, blur: 10, rev: 5, shim: 0, grain: 15, depth: 15, tube: 35)),
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
    let vibe: Vibe?          // nil only for Off
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

    static let offName = "Off"
    static let off = EmulationPreset(name: offName, vibe: nil, sensitivity: s(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    static let all: [EmulationPreset] = [
        off,
        // Every preset layers at least two of Choir, Tape and Tube Amp.
        //                                                        choir v  det dly vib   tape hys sag wow ers   tube fz blm fur wob
        // ── Nostalgic ──
        .init(name: "Church Choir on a Worn Cassette", vibe: .nostalgic, sensitivity: s(45, 30, 40, 25,  45, 30, 50, 35,   0, 10,  5, 15)),
        .init(name: "Garage Band Demo Tape",           vibe: .nostalgic, sensitivity: s(15, 25, 20, 10,  55, 40, 30, 30,  40, 30, 15, 20)),
        .init(name: "Wedding Video, 1994",             vibe: .nostalgic, sensitivity: s(30, 20, 30, 20,  35, 25, 45, 30,  10, 20,  0, 15)),
        .init(name: "Jukebox in a Smoky Bar",          vibe: .nostalgic, sensitivity: s(10, 15, 15,  5,  40, 30, 25, 25,  30, 35, 35, 25)),
        // ── Calming ──
        .init(name: "Lullaby on a Valve Radio",        vibe: .calming,   sensitivity: s(35, 15, 40, 10,  25, 10, 20, 25,  10, 35,  0, 15)),
        .init(name: "Monks by the Fireplace",          vibe: .calming,   sensitivity: s(55, 20, 60, 10,  20,  5, 10, 15,  15, 40, 10, 10)),
        .init(name: "Slow Tide Reel",                  vibe: .calming,   sensitivity: s(40, 25, 55, 15,  30, 15, 35, 20,   0, 25,  0, 20)),
        .init(name: "Velvet Living Room Choir",        vibe: .calming,   sensitivity: s(30, 15, 35, 10,  25, 10, 10, 25,  20, 40,  0, 15)),
        // ── Inspiring ──
        .init(name: "Cathedral Choir to Tape",         vibe: .inspiring, sensitivity: s(85, 35, 60, 25,  35, 10,  5, 10,   0, 15,  0,  0)),
        .init(name: "Gospel Hall Through a Valve Amp", vibe: .inspiring, sensitivity: s(70, 45, 35, 45,  15,  0,  0,  5,  25, 35,  5, 10)),
        .init(name: "Stadium Anthem Master",           vibe: .inspiring, sensitivity: s(100, 25, 25, 20, 40, 15, 10, 15,  20, 30,  0,  0)),
        .init(name: "Studio Two, Full Band",           vibe: .inspiring, sensitivity: s(25, 20, 20, 15,  45, 15, 10, 15,  15, 25,  0,  5)),
        // ── Dreamy ──
        .init(name: "Choir Lost in a Melting Reel",    vibe: .dreamy,    sensitivity: s(75, 60, 80, 30,  30, 35, 75, 20,   0, 15,  0, 30)),
        .init(name: "Ghosts in the Amp",               vibe: .dreamy,    sensitivity: s(50, 70, 70, 55,  10,  0, 40, 10,  35, 30, 15, 45)),
        .init(name: "Underwater Valve Choir",          vibe: .dreamy,    sensitivity: s(45, 40, 60, 25,  20, 20, 40, 35,  45, 45, 10, 60)),
        .init(name: "Sleepwalking Tape Ensemble",      vibe: .dreamy,    sensitivity: s(60, 50, 65, 35,  35, 30, 60, 30,  10, 20,  5, 35)),
        // ── Playful ──
        .init(name: "Barbershop on a Wobbly Deck",     vibe: .playful,   sensitivity: s(30, 40, 20, 70,  25, 20, 55, 10,  10,  0,  0, 20)),
        .init(name: "Fuzz Bass Karaoke",               vibe: .playful,   sensitivity: s(40, 50, 25, 40,  20, 10,  0,  0,  70, 40, 25, 10)),
        .init(name: "Kazoo Choir Meets Fuzz Pedal",    vibe: .playful,   sensitivity: s(60, 85, 30, 90,   0,  0, 30, 10,  50, 20, 20,  0)),
        .init(name: "Crackle, Pop & Sing-Along",       vibe: .playful,   sensitivity: s(35, 30, 30, 30,  30, 25, 30, 20,  45, 30, 70, 30)),
    ]

    static func presets(in vibe: Vibe) -> [EmulationPreset] { all.filter { $0.vibe == vibe } }
    static func named(_ name: String) -> EmulationPreset? { all.first { $0.name == name } }
}
