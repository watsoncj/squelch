# Squelch

A map-first FT8/FT4/WSPR station for macOS. Native SwiftUI — decode, log,
and work the world from an edge-to-edge propagation map. Verified on the
Yaesu FT-891 (with a Digirig) and the FT-991; adaptable to similar setups.

![Squelch decoding 20m FT8 — a Tennessee station working Saudi Arabia,
with the great-circle path drawn across the Atlantic](docs/screenshot.png)

## Install

Grab the notarized zip from
[Releases](https://github.com/watsoncj/squelch/releases), unzip, and drag
**Squelch.app** to Applications. Requires macOS 15 or later.

To build from source:

```sh
Scripts/make_app.sh      # builds release + creates Squelch.app
open Squelch.app
```

For development: `swift build`, `swift test`, or open `Package.swift` in
Xcode. `Scripts/make_release.sh` is the sign/notarize/staple pipeline.

## Supported hardware

Verified stations:

- **Yaesu FT-891** + Digirig Mobile (DR-891 cable set) — audio, CAT, and PTT.
  Setting it up from scratch? Read [the FT-891 digital setup guide](docs/ft891-digital-setup.md)
  first — the radio has several factory-state sharp edges (WIDTH,
  DNR, band-stacks, tuner memories) that silently kill weak-signal RX.
- **Yaesu FT-991** — its built-in USB audio + CAT bridge is all you need;
  no external interface

In general: any radio with a USB audio path (built in, or through an
interface like the Digirig) can decode. CAT speaks the Yaesu ASCII
protocol, so close relatives of the verified rigs are likely to work;
PTT keys via CAT or serial RTS. Without CAT everything else still runs —
set the dial by hand and pick the matching frequency in the app.

## Hardware setup (FT-891 + Digirig)

1. Connect the Digirig to the Mac by USB and to the radio per the Digirig
   docs (the DR-891 kit is a single USB cable; the radio's own CAT bridge
   passes through).
2. FT-891 settings for FT8 receive:
   - Mode: **DATA-USB** (FT8/FT4/WSPR are always upper sideband)
   - Menu **08-05 DATA PTT SELECT** per your wiring (see PTT below)
3. In Squelch: set your callsign, grid square, and license class in
   Settings (⌘,) — the Digirig input is auto-selected when present — and
   press **Start** (⌘R).
4. Settings → Audio Input has a live level meter: adjust the radio volume /
   Digirig RX level so it sits mid-scale, not pinned red.

Decodes appear at the end of each slot (15 s FT8, 7.5 s FT4, 2 min WSPR).
Keep the Mac's clock synced — these modes depend on it.

## Features

- **Map**: stations light up their Maidenhead grid square, aging red
  (heard < 2 min) → orange (< 10 min) → fading gray, and drop off after an
  hour — the map shows *current propagation*; the log keeps history. Click
  a lit square or a feed row to open its station card. Map modes: standard,
  hybrid, satellite, and a fully **offline** vector world (bundled
  coastlines, nothing streamed).
- **Feed**: a chronological sidebar of decodes as readable rows — flag,
  callsign, SNR, and a plain-English summary ("Calling CQ from EN53 ·
  WI, USA · 620 mi"). Searchable; rows calling you are highlighted; your
  station's position comes from the grid in Settings (Location Services is
  only touched by the explicit "Use My Location" button).
- **Station card**: distance, great-circle bearing, SNR, first/last heard,
  worked-before badge from your QSO log, the raw message thread (exact
  times, DT, audio frequency), a keyless HamDB operator lookup (US/Canada),
  and a QRZ link.
- **Waterfall**: floating spectrogram panel; double-click (or right-click)
  to move your TX offset. Signals paint on glass — silence is transparent.
- **QSO log** (⌘L): sortable, searchable, with resolved state/country per
  contact and manual add/edit for off-app QSOs. Persists to
  `~/Library/Application Support/Squelch/qsos.jsonl` (decodes to
  `decodes.jsonl` alongside).

## Transmit (Reply / CQ)

TX audio goes out the Digirig; PTT keys via **CAT** (`TX1;`/`TX0;`) when
connected, or serial RTS as a fallback. A hard guard blocks TX unless the
dial is inside the data privileges of the license class set in Settings
(None/receive-only, Technician, General, Amateur Extra — the frequency
picker's "Receive only" section follows the same setting), TX is blocked
until a callsign is set, and a watchdog force-drops PTT no matter what.

- **Reply**: click an answerable row (context menu or the station card's
  Reply button) — the app answers in the correct alternate slot and runs
  the standard exchange automatically: grid → R±NN → 73.
- **Call CQ**: transmits `CQ <your call> <grid>` on the quieter slot
  parity, answers whoever comes back, then resumes CQing. Auto-stops after
  10 unanswered calls. Auto-answer of stations calling you is always
  countdown-gated with a visible Cancel.
- **Halt TX**: spacebar (or the Halt button on the red status chip) kills
  everything instantly.

### PTT wiring options

- **Radio USB (this station's setup)**: the FT-891's USB port enumerates a
  CP2105 dual bridge → two ports. `cu.usbserial-…0` (Enhanced) is CAT;
  `cu.usbserial-…1` (Standard) is RTS PTT. With CAT connected, menu
  **08-05 DATA PTT SELECT = DAKY** and CAT keying just work.
- **Digirig serial**: single `cu.usbserial-…` port; select it as the PTT
  port and set **08-05 DATA PTT SELECT = DAKY**.

### First on-air TX checklist

1. Dial 28.074 MHz (10 m FT8), mode DATA-USB, power low (5–10 W).
2. Settings → Transmit: Digirig as audio output; PTT port or CAT connected.
3. Arm the WSPR beacon with "TX next window" (or call one CQ) and watch
   the radio's ALC: set the Mac's output volume so ALC barely moves.
4. 5–25 W is plenty for FT8/WSPR — and the FT-891 runs hot on 100%-duty
   digital modes above that anyway.

## WSPR (receive + beacon)

Pick a WSPR frequency from the frequency picker (e.g. 10 m WSPR,
28.1246 MHz). Slots become 2 minutes; spots appear in the feed and light
up the map — a live propagation view of who can hear whom.

The **Beacon** button (replaces CQ in WSPR mode) transmits
`<your call> <grid> <power>` for 110.6 s in a configurable fraction of
windows (duty cycle in Settings → WSPR Beacon). With CAT connected the
advertised power **follows the radio's actual power setting** (read-only —
the app never changes the radio); without CAT, set the reported dBm
manually. The usual guards apply.

**WSPRnet integration**: opt in to uploading every received spot to
[wsprnet.org](https://wsprnet.org) under your callsign (Settings → WSPR
Beacon — off by default, nothing leaves the app until you enable it).
While your beacon is armed, a "Heard your beacon" card docks in the
sidebar showing who's receiving you — reporter, grid, SNR, distance —
refreshed from the WSPRnet database every few minutes, and reporters
light up as purple grid squares on the map alongside the red/orange
heard-station cells: your coverage against current propagation at a
glance.

## CAT control & modes

- **CAT (FT-891)**: Settings → CAT Control, pick the radio's *Enhanced*
  serial port. Baud defaults to **Auto** — Squelch sweeps the rates the
  radio supports and remembers the winner (or pin it to menu 05-06). Once
  connected: the app's dial follows the radio's VFO, the frequency picker
  QSYs the radio (and flips it to DATA-USB before TX), and an orange
  toolbar light appears only when something's wrong (CAT offline, or the
  radio wandered off DATA-USB).
- **Modes**: FT8/FT4/WSPR travel with the frequency presets — picking
  "28.1800 MHz · FT4 · 10m" switches both. Mode changes while decoding
  stop the decoder; press Start again.

## Known issues & workarounds

- **Built-in trackpad goes sluggish during high-power TX** — system-wide,
  not just in Squelch. This is RF interference with the trackpad's
  capacitive sensor (common-mode current on the USB/feedline near the
  desk), not software: it appears at high power (observed at 75 W),
  vanishes at 5 W, and wired mice are immune. Workarounds: transmit at
  lower power (25–40 W is plenty for digital modes), use a wired mouse, and
  fix the RF at the source — mix-31 ferrite chokes on the USB run to the
  Digirig and a common-mode choke on the feedline.
- **FT-891 power gotcha**: data modes use the radio's **HF PWR / 50M PWR**
  menu setting — *not* "HF SSB PWR", which applies to voice only. The
  power Squelch reads via CAT (and the WSPR beacon advertises) is the
  operative data-mode value.
- **Offline map mode** intentionally hides streamed imagery; it renders
  identically with or without a network.
- **WSPR type-2/3 messages** (compound callsigns like `W0CJW/P`,
  6-character locators) are not decoded — the clean-room decoder handles
  standard type-1 spots, which are the overwhelming majority.

## Project layout

- `Sources/CFT8/` — vendored ft8_lib + `glue.c` (FT8/FT4) with kiss_fft.
- `Sources/Squelch/Audio/` — CoreAudio capture, waterfall DSP.
- `Sources/Squelch/Decoder/` — slot-aligned buffering, decode
  orchestration, and the clean-room Swift WSPR codec + decoder.
- `Sources/Squelch/Parsing/` — FT8 message grammar, Maidenhead math,
  callsign→country table.
- `Sources/Squelch/Store/` — decode/QSO persistence, station aggregation,
  HamDB lookups.
- `Sources/Squelch/Transmit/` — encoder, QSO sequencer, CAT, PTT, audio out.
- `Sources/Squelch/Views/` — the SwiftUI map, feed, station card, panels.

## Ideas for later

- Multi-caller queue when a CQ gets a pileup (currently first heard wins).
- ADIF export of qsos.jsonl for LoTW / QRZ logging.

## License

MIT (see `LICENSE`). FT8/FT4 decoding uses
[ft8_lib](https://github.com/kgoba/ft8_lib) (MIT) with kiss_fft (BSD),
vendored under `Sources/CFT8/`. WSPR encoding and decoding are a
clean-room Swift implementation written from the public protocol
specification (G4JNT, "The WSPR Coding Process") — Squelch contains no
WSJT-X/wsprd code.
