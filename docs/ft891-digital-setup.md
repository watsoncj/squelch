# FT-891 from factory reset to working FT8/WSPR

Every item here was found the hard way: a factory reset silently reverted
a working digital-mode station, and each setting below was rediscovered by
recording audio slots, comparing spectra, and cross-checking against a
reference decoder. Symptoms are listed with each item so you can work
backward from what you're seeing. Written for Squelch + Digirig on the
rear DATA port, but the radio-side items apply to any digital software.

## Why factory state bites

Three properties of the FT-891 make a fresh reset treacherous:

1. **Per-band, per-mode memory (band-stacks).** Mode, WIDTH/NAR state, and
   more are remembered *per band*. Fixing a setting on 20m fixes 20m only —
   QSY to 40m and yesterday's state (or factory state) is back. If digital
   suddenly went deaf after changing bands, suspect this first.
2. **DSP that silently destroys weak signals.** DNR, DNF (auto-notch), and
   CONTOUR all mangle or delete the steady faint tones that WSPR and weak
   FT8 are made of — with no indicator that decodes are being lost. Voice
   sounds fine; data dies.
3. **The WIDTH trap — the day's most expensive lesson.** WDH "disabled"
   does NOT mean wide open: it means the mode's *default* filter applies,
   and DATA mode's default is a narrow ~1600 Hz passband. The 3000 Hz you
   dialed in only exists while the WIDTH function is ENABLED. Set WDH to
   3000 and **leave it enabled** — disabling it afterward silently
   reinstates the narrow default while the menu still displays "3000".
   Verified empirically: identical 400–1600 Hz noise floor on two
   different bands with WDH "3000 (disabled)"; flat 400–2800 Hz the
   moment it was re-enabled.

## The checklist (menu numbers from the Advance Manual)

### Menu group 08 — the complete DATA recipe

These five items together took the station from zero to its first live
WSPR decode. Defaults in parentheses; every one of them ships wrong for
FT8/WSPR. (Independently confirmed by
[TheModernHam's FT-891 digital settings guide](https://themodernham.com/ft-891-the-ultimate-digital-settings-menu-guide-for-digital-modes/),
which is excellent and covers the TX side too.)

- **08-01 DATA MODE = OTHERS** (default PSK) — PSK engages the radio's
  own PSK audio handling on the DATA jack; OTHERS is the clean
  pass-through digital software needs.
- **08-03 OTHER DISP = 1500 Hz** (default 0).
- **08-04 OTHER SHIFT = 1500 Hz** (default 0) — sets the DATA passband's
  carrier point. **At the default 0, the receive passband is centered in
  the wrong place** (~1000 Hz instead of 1500), so even a 3000 Hz WIDTH
  passes roughly 400–1600 Hz and starves everything above — the exact
  crushed-spectrum signature chased for hours in this saga.
- **08-05 DATA LCUT FREQ = OFF** (default 300 Hz).
- **08-07 DATA HCUT FREQ = OFF** (default 3000 Hz).
- **08-12 DAT BFO = USB.**

### Mode & sideband
- **Mode: DATA-USB on every band you'll use.** Set it per band — the
  band-stack remembers. Digital is USB even on 40/80/160 m where voice is
  LSB. Wrong sideband = inverted spectrum = zero decodes with
  normal-sounding band noise.
- **08-12 DAT BFO = USB** — makes DATA mode select the upper sideband.
- **RTTY BFO = LSB is correct** (RTTY convention); it does not affect
  DATA mode. Don't "fix" it.

### IF & AF filtering — the decode killers
- **WIDTH (WDH) = 3000 in DATA mode, ENABLED and left enabled**, *per
  band*. Disabled = narrow default (see trap #3 above). Symptom of narrow:
  decodes cluster in one slice of audio (e.g. only 750–1250 Hz) while the
  rest of the passband is silent. WSPR (1400–1600 Hz) starves completely.
- **No NAR indicator** on the display.
- **SHIFT (SFT) = 0.**
- **08-05 DATA LCUT FREQ = OFF and 08-07 DATA HCUT FREQ = OFF** (see the
  menu-08 recipe above).
- **DNR OFF, DNF OFF, CONTOUR OFF, NB OFF** for data modes. DNF hunts and
  kills steady carriers — a WSPR tone *is* a steady carrier.

### Gain chain
- **CLAR off** (no offset indicator).
- **ATT off; try AMP1** on 20/40 m with a modest antenna.
- **RF/SQL knob**: check which function the menu assigns this knob. If RF
  gain, keep it fully clockwise; if squelch, fully open. A turned-down RF
  gain quietly desensitizes the receiver.
- **AGC = AUTO/SLOW** — FAST lets strong neighbors pump weak signals.

### Audio level to the computer
- The rear DATA jack's RX level is fixed (AF volume irrelevant), but
  **DATA OUT LEVEL** (menu 08 group) sets it. Combined with the OS input
  slider for the USB codec, target band noise around −35…−25 dBFS on the
  software's meter — healthy headroom, no clipping. (A working station
  can limp at −50 dBFS, but you're throwing away dynamic range.)

### Antenna match — check before blaming any menu
- **Run a fresh tune cycle on every band after a factory reset** (or after
  the tuner loses power). Auto-tuner per-band memories can vanish along
  with the radio's settings, leaving one band matched and another at
  SWR 3+ with no visible indication. The symptom is brutal and misleading:
  the mismatched band sounds like pure local noise (feedline pickup
  dominates), TX folds back to a fraction of a watt, and no menu setting
  explains it. Check the SWR meter during a TX on *each* band you use —
  a band your antenna can't load explains "deaf receiver" better than any
  filter setting.

### After it works
- **Back up the configuration.** The FT-891 has no memory-card slot; use
  Yaesu's ADMS-11 programming software (or a third-party CAT backup tool)
  so the next reset or firmware update is a restore, not a scavenger hunt.

Waterfall screenshots of the broken and fixed states are in
[wdh-experiment-notes.md](wdh-experiment-notes.md).

## Verifying empirically (how this list was built)

Squelch's status chips catch several of these live: "Radio in \<mode\>"
(CAT connected but not DATA-USB), "RX filter looks narrow" (decodes
bunched in one audio slice), "Signals heard, none decode" (WSPR-shaped
sync present but nothing verifies — DSP mangling), "Audio input clipping",
and "No audio". Beyond the chips:

- **Spectrum check**: record ~2 min of RX audio and look at the average
  spectrum. Band noise should be roughly flat from ~300–2800 Hz. A cliff
  or hump is a filter or wrong sideband, whatever the menus claim.
- **Decode-frequency histogram**: if FT8 decodes exist only inside one
  narrow band of audio frequencies, the passband is narrow.
- **Reference cross-check**: WSJT-X's `wsprd` run on the same recorded
  audio separates "my decoder/settings" problems from "nothing decodable
  arrived" (propagation/antenna) — the question menus can't answer.
