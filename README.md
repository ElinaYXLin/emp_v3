# Entropy Music Player (EMP) — v3

*The classic Entropy Music Player with better emulation!*

A music player that makes music feel warm, hazy and nostalgic. One **Macro** slider drives a whole chain of effects (saturation, tape, smear, reverb, granular memory and more), so turning a single control moves a track from clean to a half-remembered dream.

EMP comes in two editions:

- **Desktop (macOS)** — the main, actively developed version described below.
- **Web** — the original single-file prototype, kept for reference (see [Web edition](#web-edition)).

---

## Desktop edition (macOS)

A native SwiftUI + Core Audio app with a custom real-time DSP engine. It plays local music folders, or processes **any audio on your Mac** live through System mode.

### Requirements

- macOS 12 or later (Apple Silicon or Intel)
- Xcode 14 or later to build
- Optional, for System mode: [BlackHole 2ch](https://github.com/ExistentialAudio/BlackHole) (a free virtual audio device)

### Build and run

1. Open `EntropyPlayer.xcodeproj` in Xcode.
2. Select the **EntropyPlayer** scheme and press **Run** (⌘R).

Debug builds compile with optimization (`-O`) on purpose: the DSP runs on the real-time audio thread, and unoptimized Swift is too slow for it.

### Playing music

- **Open** a folder of audio files; play in **Alphabetical** or **Shuffle** order, or search tracks from the top bar.
- **System mode** processes everything your Mac plays (Spotify, YouTube, games…):
  1. Set your Mac's sound output to **BlackHole 2ch**.
  2. In EMP press **System**, then choose BlackHole as **IN** and your headphones/DAC as **OUT**.
  3. Grant microphone access when asked (macOS treats any audio input that way).

### Window sizes

- **Wide:** the Effects and Emulation pages sit side by side.
- **Medium:** one page at a time, with tabs to switch.
- **Mini** (too narrow for even one full page): both pages shrink to compact boxed knobs (title on top, no range sliders) and sit side by side; the full menu bar wraps onto a few short lines with System and the IN/OUT devices on their own line; the EQ/Tube column is hidden. Ranges, EQ and Tube keep their settings.

### How the controls work

Every effect control is a glass **cylinder** that fills (grey → orange) as you drag it up, with a small icon for its parameter; the slim slider beside it is its **Range**. Each one is a **sensitivity**: how strongly the **Macro** slider drives that effect. Each knob also has a **Range** (min/max) that the macro sweeps through. In **Vibrato** mode the macro drifts slowly on its own (Slow or Fast).

Other controls:

- **4-band EQ** (a column of knobs between Macro and Post-Gain, highs on top): High >2 kHz, High-Mid 500 Hz–2 kHz, Mid 100–500 Hz, Low <100 Hz, ±12 dB each; 12 o’clock is 0 dB. Remembered between launches.
- **Reverb** knob (between the EQ and Tube): adds the selected reverb style to the finished sound, after the final Tube saturator (0.6 → 3 s).
- **Tube** knob (under the EQ): a tube compressor + saturator after the EQ, like a vintage valve compressor. An opto-style compressor (2–4:1, 3 ms attack, fast/slow release, threshold 10 dB above the music's own level; push into it with Pre-Amp) evens out peaks, then a soft, asymmetric tube curve (4× oversampled, drive 0–12 dB, voiced by the selected Saturator Recipe) adds mostly 2nd harmonics, and a low-pass closes from 18 kHz to 7 kHz as the knob rises. Level-independent; "off" bypasses the whole stage.
- **Pre-Amp** and **Post-Gain** sliders: input trim and clean output volume (Post-Gain goes up to +48 dB; the output ceiling still catches peaks).
- **Limiter / Compressor**: the final dynamics stage, with an always-on safety ceiling after it. Just before it, a 24 dB/oct high-pass at 25 Hz removes sub-bass pumping (1–2 Hz wobble, woofer rattle).
- **FX presets**: 40 presets for the Effects page, grouped by vibe (Nostalgic, Calming, Inspiring, Dreamy, Playful), plus **INIT**. They set every Effects-page knob, the saturator recipe, the post Tube amount and the macro, and leave the Emulation page alone. Their saturation was tuned by simulation so bass never distorts much more than the mids.
- **Emulation presets**: 20 presets for Choir, Tape and Tube Amp, grouped by the same vibes, plus **Off**. They combine with any FX preset.
- **Save / Load Settings**: store your knobs, ranges and recipe as JSON.
- **Color** picker: the accent color used by the Listener Report.

### Your session is remembered

EMP saves every knob, range, recipe, preset choice and mode as you go, and opens exactly as you left it, except Post-Gain, which comes back 6 dB lower for safety.

### Effects

Signal flow: **Choir → Blur → Spectral Haze → Temporal Haze (Grain Echo → Reverb → Shimmer → Depth) → Color → Tape → Tube Amp → Grit → EQ → dynamics → output** (the Effects page in EMP_V2's order). Every effect is level-matched, so turning one up doesn't simply make things louder or push the limiter. The Lo-Mid EQ and High Roll-off are the exceptions, since changing tone is their job.

**Color**
| Knob | What it does |
|---|---|
| Lo-Mid EQ | Wide, gentle bell boost at 150 Hz (up to +12 dB) |
| Even Sat | Tube-style saturation biased toward even (2nd/4th) harmonics |
| Odd Sat | Symmetric tanh saturation with odd harmonics, for more edge |
| High Roll | Treble roll-off above 1 kHz, 0–6 dB per octave |

**Spectral Haze**
| Knob | What it does |
|---|---|
| Grp Delay | Low frequencies are delayed more (up to 20 periods: 200 ms at 100 Hz), with per-frequency scatter for a muddy, smeared low end |
| GD Random | Slow random drift of that delay (±50 %, 3–6 s glides) |
| Scatter | Spectral Scatter: each frequency band echoes back at its own delay (30–400 ms, varying smoothly across pitch) with feedback, so the music breaks into cascading, scattered fragments |

**Temporal Haze**
| Knob | What it does |
|---|---|
| Reverb | Convolution reverb; the knob is quadratic for fine control. A dropdown picks its character: Dark Room, Hall, Plate, Cathedral, Memory Fog or Tunnel |
| Shimmer | Octave-down (f/2) feedback glow under the music, arriving ~12 ms after the note |
| Depth | Shimmer's engine pitched further down: a glow of undertones f/3, f/4 … f/8 (Shimmer itself is f/2), high-passed at 25 Hz. The undertones cascade in time: f/3 arrives ~18 ms after the note, down to f/8 at 50 ms. The knob fades the undertones in one at a time; 0 is the original note only |
| Grain Echo | Short detuned grains replayed from the last ≤200 ms, like music echoing from memory |

**Recipes and Tape** (Saturator Recipes on the Effects page; Hysteresis and Tape Sag on Emulation › Tape)
| Control | What it does |
|---|---|
| Saturator Recipes | 20 characters (Sweeten, Thicken, Vintagize, Glow, Velvet… and nostalgic ones like Grandma's Kitchen or Faded Polaroid) that reshape the saturators with emphasis EQ, tube bias and exact harmonic recipes |
| Hysteresis | Tape magnetic "memory": rounded, slightly compressed response with a head bump |
| Tape Sag | Loud passages make the tape dip in level, dull and briefly droop in pitch |
| Wow/Flutter | Transport speed wobble: slow wow (0.4–1.6 Hz, with a once-per-rotation bump) plus fast flutter (6–14 Hz), up to about ±9 cents |
| Self-Erasure | Loud, bright passages squash the treble (above ~3.5 kHz) while the mids stay put, as tape saturates highs first |

**Choir** (Emulation page)
| Knob | What it does |
|---|---|
| Voices | Up to 16 virtual singers, each replaying the music from its own fixed stereo position and distance (farther = quieter, darker, later) |
| Detune | Each singer holds a pitch offset within ±d (up to ±35 cents) around its own fixed "tendency" (−d/2…+d/2), gliding to a new random offset every 10 s |
| Delay | Each singer's delay (up to 60 ms) wanders the same way, with its own tendency |
| Vibrato | Per-singer pitch vibrato up to ±40 cents, at a rate that wanders between 3 and 20 Hz |

**Blur** (bottom row, left): for when you don't want to follow the melody
| Knob | What it does |
|---|---|
| Smear | A dense, short, slowly moving diffusion (0.15 → 1 s) so notes melt into each other, with no spectral processing |
| Wash | The melody dissolves into a wide, pitched cloud of the last ~1.5 s of harmony |
| Smoke | Blurs across pitch and time into textured, pitchless fog |
| Underwater | Dark and muffled: lows linger for seconds, highs fade fast and bloom in slowly, treble dipped up to 8 dB |
| Swell | Rounds and slows note attacks, from softened onsets to full pad blooms (10 → 400 ms) |
| Diffuse | Stereo diffusion: the sound loses its location and surrounds you (bass stays centred) |

Blur runs right after the Choir, before the Effects page. It adds a constant ~140 ms of latency (three spectral stages).

**Grit** (bottom row, right)
| Knob | What it does |
|---|---|
| Bit Depth | 10 → 3 bits relative to the music's own level, with the quantization error filtered to ~150 Hz–2.5 kHz: sandy grit, no hiss, silent silences |
| Soft Clip | Asymmetric (warm, even-harmonic) soft clipping of the 100 Hz–1.2 kHz band, auto-gained so it always bites |
| Grain | Sparse dust/film-grain crackle (200 Hz–5 kHz) that follows the music's level, so silences stay clean |
| Rattle | A buzz on bass peaks, like a loose part on an old speaker (up to about −24 dB) |
| Corpus | A mix of a wooden-body resonator (up to about −10 dB) (ten broad, slowly swaying modes, so nothing settles into a standing tone) |

**Tube Amp** (Emulation page)
| Knob | What it does |
|---|---|
| Fuzz | Transformer saturation on magnetic flux, so low notes fuzz far more than high ones (40 Hz much more than 200 Hz); the fuzz alone is low-passed like a speaker cabinet (4.5 → 3 kHz) to stay round and woolly |
| Bloom | Each bass hit briefly dips the level, then it blooms back over 100–300 ms (stronger and slower as the knob rises); the mids take about a third of the dip, so the amp breathes with the kick |
| Wobble | The even saturator's bias drifts to a random point over 20–100 s; as the bias rises, a low-pass closes (down to ~2.5 kHz). Needs Even Sat turned up |
| Fur | After loud bass the fuzz bias drifts, so decays crackle softly; higher is louder and more frequent |

### Listener Report

**Listener Report** saves a shareable PNG card in your chosen color. It includes:

- **Score:** total harmonic distortion at 100 Hz and 1 kHz, measured through your current Color chain.
- **More measurements:** THD+N, 5-tone intermodulation, and time smear (clarity C50 and centre time).
- **Every setting as engineering values**, in signal-flow order: Choir, Spectral Haze, Temporal Haze, Color, Tape, Tube Amp and gain staging, in dB, Hz, ms and cents.
- **Both presets** (FX and Emulation) on the card.
- **For fun:** a listener "archetype" (now including the Choir Conductor and the Valve Hoarder), a Cozy Index, and "Sounds like…" comparisons, which are vibes, not science.

### Listening-level meter

The bar at the bottom estimates how loud the sound at your ears is, in **dB(A)**, and tracks your exposure against the WHO safe-listening guideline (80 dB(A) for 40 hours a week).

- Enter your **headphone sensitivity** (dB SPL per volt), your **DAC's full-scale output** (Vrms) and your **system volume**.
- It shows a 1-minute level, today's time, this week, last week, and a rolling 7-day dose.
- History is saved locally (`Application Support/EntropyPlayer/listening_history.json`, inside the app's sandbox container) and survives restarts, sleep and unplugging.

It's an estimate; it's only as accurate as the sensitivity and voltage you enter.

### Project layout

```
EntropyPlayer/
  AudioEngine.swift          audio graph, real-time render chain, System mode (raw HAL units)
  AppState.swift             UI state, macro/vibrato, presets, settings
  ContentView.swift          main interface
  GroupDelay.swift           1/f group delay with spectral smear
  SpectralScatter.swift      per-band spectral delay (Spectral Scatter)
  GrainEcho.swift            granular memory haze
  ConvolutionReverb.swift    darkening noise-convolution reverb
  Shimmer.swift              octave-down feedback glow
  PartitionedConvolver.swift shared FFT convolution engine
  CustomSaturator.swift      even/odd saturators
  SaturatorRecipes.swift     recipe definitions and shaping stage
  Tape.swift                 tape hysteresis and sag
  TubeAmp.swift              transformer fuzz, bass bloom, bias-shift fur
  MelodyBlur.swift           Blur section (smear, wash, soften, distance)
  Grit.swift                 Grit section (bit depth, soft clip, grain)
  Session.swift              saves/restores the session
  Choir.swift                ensemble of detuned, delayed, panned singers
  Depth.swift                undertones (subharmonics) of the upper band
  CustomEQ.swift             lo-mid bell, high roll-off, subsonic filter
  CustomDynamics.swift       limiter/compressor
  Presets.swift              FX and Emulation presets
  ListenerReport.swift       report card
  ReportMeasurements.swift   offline THD / intermod / smear measurements
  ListeningMeter.swift       dB(A) meter and exposure history
```

### Listen responsibly

EMP's effects don't add loudness, but darker presets can tempt you to turn up the volume. Keep an eye on the listening meter, take breaks, and rest your ears if they ring or feel dull after listening.

---

## Web edition

`entropy_player_1.html` is the original browser prototype, a single file with no build step. Open it in a modern browser (Chrome works best) and load your MP3s.

It has the core idea in a smaller form: Macro slider, Reverb, Lo-Mid EQ and Saturator knobs with sensitivity and range, Limiter/Compressor, Vibrato, Shuffle, and settings import/export. Example settings files: `entropy_settings_1.json`, `entropy_settings_aug.json`.

The web edition is no longer actively developed. New effects, presets, System mode, the Listener Report and the listening meter are desktop-only.
