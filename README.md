# RadioFun

Native macOS FT8 receive monitor for W0CJW. Decodes FT8 from a Digirig
audio interface connected to a Yaesu FT-891, plots heard stations on a map,
and keeps a persistent decode log.

Decoding uses [ft8_lib](https://github.com/kgoba/ft8_lib) (MIT), vendored
under `Sources/CFT8/`.

## Build & run

```sh
Scripts/make_app.sh      # builds release + creates RadioFun.app
open RadioFun.app
```

For development: `swift build`, `swift test`, or open `Package.swift` in Xcode.

## Hardware setup (FT-891 + Digirig)

1. Connect the Digirig to the Mac by USB and to the radio's rear **DATA** port.
2. FT-891 settings for FT8 receive:
   - Mode: **DATA-USB** (upper sideband; FT8 is always USB)
   - Tune to an FT8 frequency, e.g. **28.074 MHz** (10 m — within Technician
     data privileges if you later transmit). Others: 21.074 (15 m),
     14.074 (20 m), 7.074 (40 m) — receive is fine on any band.
   - Menu `08-01 GM DISPLAY`… not needed; the relevant ones are
     `11-06 SSB PORT SELECT = USB` only matters for CAT/TX. For RX only,
     no menu changes are required.
3. In RadioFun, pick the Digirig input (it shows up as "USB Audio Device" /
   "USB PnP Sound Device") and press **Start** (⌘R).
4. Watch the input level meter in the status bar: adjust the radio's volume /
   Digirig RX level so it sits mid-scale, not pinned red.

Decodes appear at the end of each 15-second FT8 slot (:00/:15/:30/:45 UTC —
keep the Mac's clock synced; FT8 depends on it).

## Features

- **Map**: every station heard with a grid square gets a pin (red = heard in
  the last 2 min, orange = 10 min, gray = older). Blue dot is your station —
  from Location Services, or the grid square set in Settings as a fallback.
  Hover a pin for grid, distance, and SNR.
- **Log**: UTC time, SNR, time offset, audio frequency, message, grid, and
  distance for every decode. Filter to CQ calls, messages calling W0CJW, or
  messages with grids; free-text search. Messages mentioning your call are
  highlighted. The log persists to
  `~/Library/Application Support/RadioFun/decodes.jsonl`.
- **Settings** (⌘,): callsign, fallback grid square, dial frequency (for band
  logging), audio input device.

## Project layout

- `Sources/CFT8/` — vendored ft8_lib + `glue.c`, a small C API
  (`cft8_feed` / `cft8_decode`) that Swift calls.
- `Sources/RadioFun/Audio/` — CoreAudio device enumeration and AVAudioEngine
  capture, resampled to the decoder's 12 kHz mono.
- `Sources/RadioFun/Decoder/` — slot-aligned buffering and decode
  orchestration (`DecodeController`) plus the Swift wrapper (`FT8Decoder`).
- `Sources/RadioFun/Parsing/` — FT8 message parsing and Maidenhead grid math.
- `Sources/RadioFun/Store/` — decode log, station aggregation, persistence.
- `Sources/RadioFun/Views/` — SwiftUI map, log table, status bar, settings.

## Transmit (Reply / CQ / Tune)

TX works through the same Digirig: FT8 audio out its speaker side, PTT keyed
via RTS on its serial port (`cu.usbserial-…`, auto-detected in Settings).
A hard guard blocks TX unless the dial frequency is within Technician data
privileges (28.000–28.300 MHz or 50 MHz+), and a 16 s watchdog force-drops
PTT no matter what. Completed QSOs are logged to
`~/Library/Application Support/RadioFun/qsos.jsonl`.

- **Reply**: select a CQ row (toolbar button or right-click) — the app
  answers in the correct alternate slot and runs the standard exchange
  automatically: grid → R±NN → 73.
- **Call CQ**: transmits `CQ W0CJW <grid>` on the quieter slot parity,
  answers whoever comes back (report → RR73), then resumes CQing.
  Auto-stops after 10 unanswered calls.
- **Tune**: steady tone for setting drive level.
- **Halt TX** (spacebar on the red banner) kills everything instantly.

### PTT wiring options

- **Radio USB (this station's setup)**: the FT-891's USB port enumerates a
  CP2105 dual bridge → two ports. `cu.usbserial-…0` (Enhanced) is CAT;
  `cu.usbserial-…1` (Standard) is PTT. Select the `…1` port and set menu
  **08-05 DATA PTT SELECT = RTS**.
- **Digirig serial**: single `cu.usbserial-…` port; select it and set
  **08-05 DATA PTT SELECT = DAKY** (audio and PTT both via the DATA jack).

### First on-air TX checklist

1. Dummy load on, dial 28.074 MHz, mode DATA-USB.
2. FT-891 menu **08-05 DATA PTT SELECT** per the wiring above (RTS here).
3. Settings → Transmit: Digirig as audio output; PTT port per above.
4. Press **Tune**: radio should key and show power. Set Mac output volume so
   ALC barely moves (start low!). Power ≤ 25 W; 5–10 W is plenty for FT8.
5. Antenna back on, find a clear audio offset, work someone.

## WSPR (receive + 10m beacon)

Switch the mode control to **WSPR** (or pick "10m WSPR — 28.1246" from the
frequency menu, which sets both). Slots become 2 minutes; spots appear in
the log as `WSPR CALL GRID PdBm` rows and light up the map like any other
station — a live propagation view of who can hear whom.

The **Beacon** button (replaces Reply/CQ in WSPR mode) transmits
`W0CJW <grid> <power>` for 110.6 s in a fraction of the 2-minute windows
(duty cycle and reported power in Settings → WSPR Beacon; set the reported
power to your actual TX power). Transmissions use a random offset in the
WSPR sub-band. The usual guards apply: Technician-legal dial, deterministic
unkey at audio end, demo mode never keys.

Decoding uses the `wsprd` chain (K1JT/K9AN, via VA2GKA's standalone port,
GPL v3) vendored under `Sources/CFT8/wspr/` with kiss_fft substituted for
FFTW. The encoder implements standard WSPR packing as the exact inverse of
wsprd's unpackers, verified by loopback tests.

## CAT control & modes

- **CAT (FT-891)**: Settings → CAT Control, pick the radio's *Enhanced* USB
  serial port (`cu.usbserial-…0`) and the baud from menu 05-06 (factory
  4800). Once connected, the app's dial frequency follows the radio's VFO,
  and the toolbar frequency menu QSYs the radio directly (and flips it to
  DATA-USB). The status bar shows the radio's current mode.
- **FT4**: the toolbar FT8/FT4 switch changes mode (7.5 s slots, ~2.5× faster
  QSOs, same message format). The frequency menu's presets carry the right
  mode — picking "10m FT4 — 28.180" switches both. Mode changes while
  decoding stop the decoder; press Start again.

## Ideas for later

- Multi-caller queue when a CQ gets a pileup (currently first heard wins).
- ADIF export of qsos.jsonl for LoTW / QRZ logging.
- Waterfall display with click-to-set TX offset.
