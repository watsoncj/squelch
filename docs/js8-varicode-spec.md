# JS8Call "Varicode" Frame Protocol — Clean-Room Specification

Status: derived by behavioural analysis of JS8Call-improved (GPLv3) sources on 2026-09-01.
This document describes *behaviour, constants and formats only*. It contains no source code
and is intended to let an engineer who has never seen the JS8Call sources implement a
byte-exact compatible encoder/decoder (e.g. in Swift).

Everything in this document that is a table of constants (alphabets, command codes, Huffman
codes, group names, CRC parameters, JSC parameters and table excerpts) is transcribed
exactly; those are protocol facts. Where a behaviour could not be pinned down with certainty
it is marked **UNVERIFIED**.

---

## 0. Conventions used in this document

* **Bit strings** are written MSB-first, left to right. "Concatenate A(3) ‖ B(50)" means A
  occupies the 3 most significant positions followed by B.
* `value(64)` / `rem(8)`: every frame is ultimately a 72-bit string. In the reference
  implementation this is handled as a 64-bit unsigned integer ("value", the first 64 bits)
  followed by an 8-bit integer ("rem", the last 8 bits). Frame-type layouts are drawn as
  `[..][..],[..][..]` where the comma marks the 64/8 split. **The split is purely an
  implementation artefact: the wire format is the plain 72-bit string.**
* Integers are unsigned unless stated. Division `/` on integers truncates toward zero
  (C semantics); `%` is the C remainder.
* "Frame string" or "12-char string" = the 12-character representation of the 72 bits using
  the 64-symbol modem alphabet (§1.2). This is the unit that is handed to / received from the
  modem.
* Character strings are Unicode; wherever they are turned into bytes for hashing the encoding
  is noted (UTF-8 for the checksums, Latin-1 for the JSC word tables).
* All text handled by the protocol is **upper case**. The reference UI upper-cases user
  text before any of the algorithms below run; lowercase letters are *not* in any of the
  code tables and their behaviour is undefined/non-terminating in places. An implementation
  MUST upper-case before encoding.

---

## 1. The 72-bit frame payload and the modem interface

### 1.1 Modem message structure (context only)

The JS8 modem (an 8-FSK, 79-symbol LDPC(174,87) waveform derived from FT8 v1) carries an
**87-bit** message per transmission:

```
+----------------------+-----------------+-------------------+
| 72 bits  frame       | 3 bits  i3      | 12 bits  CRC-12   |
| (12 x 6-bit symbols) | transmission    | of the 75 bits    |
|                      | type            |                   |
+----------------------+-----------------+-------------------+
bit 0 ............ 71 | 72 .. 74        | 75 ............ 86
```

* The 72 data bits are the 12 characters of the frame string, each converted to its 6-bit
  index in the modem alphabet (§1.2), character 0 first, MSB of each 6-bit word first.
* i3 (bits 72..74, MSB first) is the **transmission type** (§1.3).
* CRC-12: the 75 bits are laid into an 11-byte (88-bit) buffer, MSB-first, followed by 13
  zero bits. A CRC-12 with generator polynomial 0xC06
  (x^12 + x^11 + x^3 + x^2 + x + 1), zero initial value, no reflection, computed in
  "augmented" fashion over all 88 bits (i.e. the plain polynomial remainder of the 88-bit
  message), is then XORed with 42 (0x02A). The 12-bit result is stored MSB-first at bits
  75..86. (This is the same CRC as WSJT-X's original 75-bit FT8.) On receive, the decoder
  extracts the 12 CRC bits, zeroes them in the buffer and recomputes. **The modem layer
  itself (Costas arrays, LDPC, tone mapping) is out of scope here.**

### 1.2 The 64-symbol modem alphabet

Index 0..63, in this exact order:

```
0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-+
```

| Index range | Symbols |
|---|---|
| 0–9 | `0`…`9` |
| 10–35 | `A`…`Z` |
| 36–61 | `a`…`z` |
| 62 | `-` |
| 63 | `+` |

A frame string is exactly 12 of these symbols. Any other character is an error. (The
Varicode layer keeps an extended 67-symbol table `0-9 A-Z a-z - + / ? .` for its own
lookups; only indices 0..63 are ever produced, so the two tables agree.)

### 1.3 Transmission type (i3) and its relationship to the in-frame header

i3 is a 3-bit **flag set**, not an enumeration:

| Flag | Value | Meaning |
|---|---|---|
| (none) | 0 | "JS8Call": an intermediate frame of a multi-frame message |
| First | 1 | this is the first frame of a message |
| Last | 2 | this is the last frame of a message |
| Data | 4 | "fast data" frame: the 72 bits contain *no* frame-type header; the entire 72 bits are JSC-compressed text (§2.7) |

Combinations are ordinary bit-ORs: a single-frame message is sent with i3 = 3 (First|Last);
the last frame of a fast-data message is 6 (Data|Last); a lone fast-data frame is 7.

Relationship to the in-frame header bits: for every frame *without* the Data flag, the first
bits of the 72-bit payload identify the frame type (§2.1). When the Data flag is set the
receiver must **not** look at header bits; it treats all 72 bits as JSC payload. The Data
flag is used only by the "fast" submodes (Fast/Turbo/Slow/Ultra); the Normal submode never
sets it and instead uses the in-frame `1x` data header (§2.6). A decoder should accept both
regardless of submode, dispatching solely on the Data flag.

The transmitter derives First/Last as follows: the message builder (§10) marks the first
frame of a message First and the last frame Last; the transmit loop additionally clears
First on any frame after the first one actually sent and forces Last on the frame at which
the queue becomes empty (so if a message is cut short, the final transmitted frame still
carries Last).

### 1.4 The 72-bit pack/unpack convention (pack72bits / unpack72bits)

Given `value` (64-bit) and `rem` (8-bit):

* Conceptually form the 72-bit string `value(64) ‖ rem(8)`.
* Split into twelve 6-bit groups; group k (k = 0..11, from the most significant end) becomes
  character k using the alphabet of §1.2.

Equivalently (this is how the reference does it): character 11 = alphabet[rem & 63];
character 10 = alphabet[((value & 15) << 2) | (rem >> 6)]; then for i = 0..9 character
(9−i) = alphabet[(value >> (4 + 6·i)) & 63].

Unpack is the exact inverse: value = Σ_{i=0..9} idx(c_i) << (58 − 6i) | idx(c_10) >> 2;
rem = ((idx(c_10) & 3) << 6) | idx(c_11).

All frame-type decoders first require: string length ≥ 12 and **no space characters**;
otherwise the frame is rejected.

---

## 2. Frame types and bit layouts

### 2.1 Frame-type header

The first bits of the 72-bit payload (only meaningful when i3.Data is clear):

| Header bits | Type code | Name | Notes |
|---|---|---|---|
| `000` | 0 | Heartbeat | also carries CQ (see "alt" flag) |
| `001` | 1 | Compound | a compound/non-standard callsign, optionally with grid |
| `010` | 2 | CompoundDirected | a compound callsign plus a directed command |
| `011` | 3 | Directed | FROM, TO, command, optional number |
| `10`  | 4 | Data (Huffman) | 2-bit header; text is Huffman coded |
| `11`  | 6 | DataCompressed (JSC) | 2-bit header; text is JSC coded |

Type codes 4 and 6 are the numeric names used for the 3-bit-shaped enumeration
(`10x`/`11x` with the low bit dropped); on the wire they are two bits. The value 255 is used
internally as "unknown" and never transmitted.

A receiver classifies a non-Data-flag frame in this order and stops at the first success:
(1) if first bit is `1` → data frame (§2.6); (2) else try heartbeat (header must be `000`);
(3) else try compound/compound-directed (`001`/`010`); (4) else try directed (`011`).
Headers `101`,`110`,`111` cannot occur as compound frames because bit 0 = 1 is claimed by
data first.

### 2.2 Common "compound frame" layout (used by Heartbeat, Compound, CompoundDirected)

```
 bit:  0   2 3                                              52 53        63 | 64     68 69  71
      +-----+------------------------------------------------+------------+-+--------+------+
      |type |            callsign50 (packAlphaNumeric50)     | num[15:5]  | | num[4:0]|bits3 |
      | 3   |                     50                          |    11      | |   5     |  3   |
      +-----+------------------------------------------------+------------+-+--------+------+
                      value(64)                                             |     rem(8)
```

* `type` = 0, 1 or 2 (3 and 4 are refused by the packer/unpacker of this layout).
* `callsign50` = the 50-bit alphanumeric packing of the callsign (§3.4). A packed value of 0
  (which is what an empty/invalid input packs to) aborts encoding.
* `num` is a 16-bit quantity split as: the upper 11 bits (`num >> 5`) occupy bits 53..63 of
  the frame, the low 5 bits occupy bits 64..68. Bits 69..71 are `bits3`.
  On unpack: `num = (upper11 << 5) | low5`, `bits3 = rem & 7`.

The meaning of `num` and `bits3` depends on the type:

#### 2.2.1 Heartbeat (type 000)

* `num` bit 15 = **alt flag**: 0 = heartbeat ("HB"), 1 = CQ.
* `num` bits 14..0 = 15-bit grid (§3.5); 32767 (all ones) = "no grid".
* `bits3` = CQ variant number when alt = 1 (§5.1 `cqString`), HB variant number when alt = 0
  (§5.2 `hbString`). The current transmitter always sends bits3 = 0 for HB.
* Decoded text (see §9.5): `"<CALL>: @ALLCALL <cqString(bits3)> <GRID> "` for alt, or
  `"<CALL>: @HB HEARTBEAT <GRID> "` for non-alt (when the grid is absent the text still
  contains the two spaces around an empty grid, i.e. `"<CALL>: @HB HEARTBEAT  "`).

#### 2.2.2 Compound (type 001)

* `num` ≤ 32400: a grid (§3.5); text becomes `" <GRID>"`.
* 32410 ≤ `num` < 32767: a packed command (`num − 32410` decoded via unpackCmd, §3.8); this is
  how a *CompoundDirected* frame carries its command; in a type-001 frame the packer only
  ever puts a grid or 32767.
* `num` = 32767: nothing (no grid).
* Other values (32401..32409): nothing appended.
* `bits3` = 0 always (transmitter); ignored by the receiver.
* Decoded text: `"<CALL>: "`. The grid is kept separately as the "extra" field.

#### 2.2.3 CompoundDirected (type 010)

Same layout; `num = 32410 + packCmd(cmd, num)` (§3.8); `bits3 = 0`.
Decoded as a directed message with FROM = `<....>` (placeholder), TO = the compound
callsign, CMD = the command string, and, for SNR-carrying commands, a 4th element with the
formatted SNR. Display text: `"<CALL><CMD>[ <SNR>] "` (no colon).

### 2.3 Directed (type 011)

```
 bit:  0   2 3                          30 31                         58 59   63 | 64 65 66    71
      +-----+----------------------------+----------------------------+-------+-+-+-+--------+
      | 011 |     from28 (packCallsign)  |      to28 (packCallsign)   | cmd5  | |P|Q|  num6  |
      |  3  |            28              |             28             |   5   | |1|1|   6    |
      +-----+----------------------------+----------------------------+-------+-+-+-+--------+
                              value(64)                                       |    rem(8)
```

* `from28`, `to28`: §3.3. Either packing to 0 aborts encoding.
* `cmd5` = command code modulo 32 (§4). Codes are 0..31; the "faux" commands with code −1
  are never packed.
* `P` (rem bit 7) = FROM callsign carried a `/P` suffix. `Q` (rem bit 6) = TO carried `/P`.
* `num6` (rem bits 5..0) = packNum result (§3.6): 0 = no number, else n+31 for n ∈ [−30,31].
* Decode: parts = [FROM, TO, CMD]; if num6 ≠ 0 a 4th part is added: for SNR commands
  (codes 25 and 29) `formatSNR(num6 − 31)`, otherwise the plain decimal `num6 − 31`.
  Display text: `"FROM: TO<CMD> "` or `"FROM: TO<CMD> <NUM> "` (CMD strings begin with
  their own leading space; see §4).

### 2.4 Data, Huffman (header `10`)

```
 bit: 0 1 2                                                                     71
     +-+-+---------------------------------------------------------------------+
     |1|0|                 Huffman code bits (§6) then padding                  |
     +-+-+---------------------------------------------------------------------+
```

### 2.5 Data, compressed (header `11`)

```
 bit: 0 1 2                                                                     71
     +-+-+---------------------------------------------------------------------+
     |1|1|                 JSC code bits (§7) then padding                      |
     +-+-+---------------------------------------------------------------------+
```

### 2.6 Filling and padding rule for data frames (both kinds)

1. Start with the header bits (`10` or `11`; nothing for fast data).
2. Take the code units (one Huffman code per character; one JSC codeword per token) in
   order. Append each unit **only if `current_length + unit_length < 72`** (strictly less).
   Stop at the first unit that does not fit. Count the characters consumed.
3. Padding: `pad = 72 − current_length` (always ≥ 1 because of the strict inequality).
   Append one `0` followed by `pad − 1` ones.
4. Emit as a 72-bit frame (§1.4).

Unpadding on receive: locate the **last `0` bit** in the 72 bits; everything from that bit
onward is padding. For a `1x` header frame: drop bit 0 (the data flag), read bit 1 as the
"compressed" flag, and the payload is bits 2 .. (last-zero − 1). For a fast-data frame the
payload is bits 0 .. (last-zero − 1). Then decode with §6 or §7.

The "n consumed characters" returned by the packer drives the transmit splitter (§10): the
next frame starts at `text[n:]`.

### 2.7 Fast data (i3.Data set; used by all submodes except Normal)

No header. The 72 bits = JSC code bits + padding (same padding rule). Huffman is never
used for fast data. The Normal submode never produces fast-data frames; every other submode
produces *only* fast-data frames for free text.

### 2.8 The `bits3` extra field — summary

| Frame | bits3 meaning |
|---|---|
| Heartbeat, alt=1 (CQ) | index into the CQ string table (§5.1) |
| Heartbeat, alt=0 (HB) | index into the HB string table (§5.2) — all entries currently display as `HEARTBEAT` |
| Compound / CompoundDirected | unused, transmitted as 0 |

---

## 3. Field encodings

### 3.1 Alphabets

| Name | Content (exact order) | Size |
|---|---|---|
| modem alphabet (§1.2) | `0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-+` | 64 |
| base-41 alphabet ("alphabet") | `0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ+-./?` | 41 |
| alphanumeric (callsign/grid alphabet) | `0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ /@` | 39 |

In the 39-symbol alphanumeric alphabet: digits 0..9, letters 10..35, space = 36,
`/` = 37, `@` = 38.

### 3.2 Base-41 string helpers (pack5bits / pack6bits / pack16bits / pack32bits / pack64bits)

Uses the 41-symbol base-41 alphabet `0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ+-./?`.

* pack5bits(v): one character, alphabet[v mod 32]. unpack: index of the character.
* pack6bits(v): one character, alphabet[v mod 41]. unpack: index of the character.
* pack16bits(v), v ∈ [0, 65535] → exactly three characters `c0 c1 c2` with
  `c0 = alphabet[v / 1681]`, `c1 = alphabet[(v − 1681·(v/1681)) / 41]`, `c2 = alphabet[v mod 41]`
  (1681 = 41²). Because 65535/1681 = 38, three characters always suffice; the highest
  possible first character is `.` (index 38).
  unpack16bits: `1681·i0 + 41·i1 + i2`; if the result exceeds 65535 the result is **0**
  (e.g. `???` = 68920 → 0).
* pack32bits(v): pack16bits(v >> 16) ‖ pack16bits(v & 0xFFFF) (6 characters).
  unpack: left 3 chars are the high half, right 3 chars the low half.
* pack64bits(v): pack32bits(high 32) ‖ pack32bits(low 32) (12 characters).

These are used by the checksums (§8) only. (pack72bits uses the 64-symbol modem alphabet,
§1.4, not base-41.)

### 3.3 packCallsign (28-bit) / unpackCallsign

Input: a callsign string. Output: 28-bit value and a `portable` flag.

1. Upper-case and trim.
2. If the string is one of the **base calls / group names** (§5.3) return that table's fixed
   value (`NBASECALL + k`); the portable flag is left untouched (false).
3. If it ends in `/P`: remove the suffix, set portable = true.
4. Prefix work-arounds (so the 6-character form fits the pattern):
   * starts with `3DA0` → replace with `3D0` (Eswatini/Swaziland).
   * starts with `3X` followed by a letter A–Z → replace `3X` with `Q` (Guinea).
5. Let L = length. If L < 2 or L > 6 → **fail (return 0)**.
6. Build candidate 6-character forms by padding with spaces:
   * L = 6: the string itself.
   * L = 5: `S`, `␠S`, `S␠`
   * L = 4: `S`, `␠S␠`, `S␠␠`
   * L = 3: `S`, `␠S␠␠`, `S␠␠␠`
   * L = 2: `S`, `␠S␠␠␠`
   Each candidate is searched (unanchored) for the regular expression
   `([0-9A-Z ])([0-9A-Z])([0-9])([A-Z ])([A-Z ])([A-Z ])` i.e. the standard 6-slot form
   *prefix-char, prefix-char, digit, suffix, suffix, suffix*; the **last** candidate (in the
   order listed) that matches wins; the matched 6 characters are used. No match, or a match
   shorter than 6 characters → fail (0).
7. With `i(c)` = index in the 39-symbol alphanumeric alphabet (space = 36):
   ```
   v = i(c0)
   v = 36·v + i(c1)
   v = 10·v + i(c2)
   v = 27·v + (i(c3) − 10)
   v = 27·v + (i(c4) − 10)
   v = 27·v + (i(c5) − 10)
   ```
   Note the first slot has radix 37 (0–9, A–Z, space → 0..36), the second radix 36 (space is
   not allowed by the pattern), the third 10, the last three radix 27 (A–Z → 0..25,
   space → 26). NBASECALL = 37·36·10·27·27·27 = **262,177,560**; all standard calls pack
   below it; the group/base-call values `NBASECALL + 1 .. NBASECALL + 54` sit above it and
   below 2^28 = 268,435,456.

unpackCallsign(v, portable):
1. If v equals one of the base-call table values, return that name.
2. Otherwise peel off in reverse: `c5 = A[v mod 27 + 10]; v /= 27; c4 = A[v mod 27 + 10];
   v /= 27; c3 = A[v mod 27 + 10]; v /= 27; c2 = A[v mod 10]; v /= 10; c1 = A[v mod 36];
   v /= 36; c0 = A[v]` (A = alphanumeric alphabet).
3. Undo the work-arounds: leading `3D0` → `3DA0`; leading `Q` followed by a letter → `3X` +
   rest.
4. If portable, trim and append `/P`. Return the trimmed string.

Worked values: `KN4CRD` → 146,325,342 (matched form `KN4CRD`); `W0CJW` → 261,391,963
(matched form `␠W0CJW`: the 5-letter call is right-aligned because the 3rd slot must be the
digit); `KN4CRD/P` → 146,325,342 with portable = true; `3DA0ABC` → 23,816,459 (form
`3D0ABC`); `@ALLCALL` → 262,177,562; `<....>` → 262,177,561; `@HB` → 262,177,605.

**Validation of "standard" callsigns** (isValidCallsign): a callsign is a valid *standard*
call if it matches, in its entirety, `\b(?<base>([0-9A-Z])?([0-9A-Z])([0-9])([A-Z])?([A-Z])?([A-Z])?)(?<portable>[/][P])?\b`
and is longer than 2 characters and contains a digit adjacent to a letter
(`[0-9][A-Z]|[A-Z][0-9]`). Base-call/group names in §5.3 are always valid (and *not*
compound). Otherwise it may be a valid **compound** callsign (§3.4).

### 3.4 packAlphaNumeric50 (compound callsigns, 50 bits) / unpackAlphaNumeric50

Encodes up to 10 alphanumerics plus up to two `/` separators in an 11-slot mixed-radix
word. Slot layout (weights from the most significant slot):

```
slot:   0     1     2     3     4     5     6     7     8     9    10
radix: 39    38    38     2    38    38    38     2    38    38    38
        K     N     4     ␠     C     R     D     /     Q     R     P      "KN4CRD/QRP"
        V     E     3     /     L     B     9     ␠     Y     H     X      "VE3/LB9YHX"
        @     R     A     ␠     C     E     S     ␠     ␠     ␠     ␠      "@RACES"
```

Packing:
1. Remove every character not in `A–Z 0–9 space / @`.
2. If length > 3 and character 3 is not `/`, insert a space at index 3.
3. If length > 7 and character 7 is not `/`, insert a space at index 7.
4. Right-pad with spaces to 11 characters.
5. With `i(c)` = alphanumeric index (space 36, `/` 37, `@` 38) and `s(c)` = 1 if c is `/`
   else 0:
   ```
   v = i(w0)
   v = 38·v + i(w1)
   v = 38·v + i(w2)
   v = 2·v  + s(w3)
   v = 38·v + i(w4)
   v = 38·v + i(w5)
   v = 38·v + i(w6)
   v = 2·v  + s(w7)
   v = 38·v + i(w8)
   v = 38·v + i(w9)
   v = 38·v + i(w10)
   ```
   Maximum value ≈ 6.6 × 10^14 < 2^50. Slot 0 may be `@` (index 38); slots 1,2,4,5,6,8,9,10
   must not be `@` (the packer does not check; the result would be non-invertible).
   Slots 3 and 7 are single bits: `/` or space.
6. A result of 0 (the word `00000000000`) is treated as failure by callers — but note it
   also means an all-zero callsign string is unencodable.

Unpacking: peel slots 10 down to 0 with the radices above (slot 3 and 7 → `/` if 1 else
space; slot 0 uses `mod 39`); then **remove all spaces** from the 11-character result.

Worked values: `KN4CRD` → word `KN4 CRD    ` → 358,399,795,381,724
(50-bit `01010001011111011001110100011111011100010111011100`); `KN4CRD/P` →
`KN4 CRD/P  ` → 358,399,795,420,712; `VE3/LB9YHX` → `VE3/LB9 YHX` → 545,579,025,695,551.

**Compound callsign validity** (isValidCompoundCallsign), applied after the string matches
`^(?:[@]?|\b)(?<extended>[A-Z0-9\/@][A-Z0-9\/]{0,2}[\/]?[A-Z0-9\/]{0,3}[\/]?[A-Z0-9\/]{0,3})\b`
in its entirety:
* more than 9 characters excluding `/` → invalid;
* contains `/` → valid iff the text before the first `/` is not a base-call/group name;
* starts with `@` → valid (this is how *custom* groups not in §5.3 are sent);
* else valid iff length > 2 and it contains a digit adjacent to a letter.

### 3.5 packGrid (15-bit) / unpackGrid

Input: a Maidenhead locator; only the first 4 characters `A1 A2 D1 D2` (two letters A–R, two
digits) are used. Shorter than 4 characters after trimming → 32767 ("no grid").

The reference computes via floating point (grid → degrees, west-positive longitude, then
truncation toward zero). The exact integer-equivalent procedure is:

```
lonField = A1 − 'A'          (0..17)
latField = A2 − 'A'          (0..17)
lonSq    = D1 − '0'          (0..9)
latSq    = D2 − '0'          (0..9)
K        = 180 − 20·lonField − 2·lonSq
ilong    = K − 2   if K ≥ 2,  else K − 1      (result of truncating K − 1.041666…)
ilat     = 10·latField + latSq                  (result of truncating lat+90 = ilat + 0.5208…)
packed   = ((ilong + 180) / 2) · 180 + ilat     (integer division)
```

Values range 0..32399; NBASEGRID = 180·180 = 32400 is the "grid" upper bound used by the
compound-frame decoder (values ≤ 32400 are grids; 32410..32766 are commands; 32767 empty).

unpackGrid(v): if v > 32400 → empty string. Otherwise
```
lat  = v mod 180 − 90
lon  = (v / 180)·2 − 180 + 2
nlong = 12·(180 − lon)          n1 = nlong / 240   n2 = (nlong − 240·n1) / 24
nlat  = 24·(lat + 90)           m1 = nlat / 240    m2 = (nlat − 240·m1) / 24
grid = chr('A'+n1) chr('A'+m1) chr('0'+n2) chr('0'+m2)
```
(The reference derives these with `int(60·(180−lon)/5)` and `int(60·(lat+90)/2.5)`, which
are exact for integer inputs.) Round-trip of all 32,400 4-character grids has been verified.

Worked values: `EM73` → 23,883; `DM79` → 25,689; `JO22` → 15,802; `AA00` → 32,220;
`RR99` → 179.

### 3.6 packNum

Input: a decimal string (optionally signed). Empty → not ok, value 0. Otherwise parse as
integer, clamp to [−30, 31], and return `n + 31`; the packed range is therefore 1..62 with 0
reserved for "absent". Unpack: `n = packed − 31`.

### 3.7 SNR representation (formatSNR)

`formatSNR(n)`: empty string if n < −60 or n > 60; otherwise a sign character `+` for
n ≥ 0 (nothing extra for negative, the minus sign comes from the number) and the number
zero-padded to width 2 (non-negative) or 3 including the sign (negative):
`-5 → "-05"`, `0 → "+00"`, `10 → "+10"`, `31 → "+31"`, `-30 → "-30"`.

On the wire an SNR travels as packNum (6 bits, −30..+31). In text it is parsed by
`(?<num>(?<=SNR)\s?[-+]?(?:3[01]|[0-2]?[0-9]))?` — only directly after the letters `SNR`.

### 3.8 packCmd / unpackCmd (compound-directed frames; 8-bit value added to 32410)

packCmd(cmd, num):
* If cmd is an SNR command (codes 25 ` SNR` or 29 ` HEARTBEAT SNR`):
  `value = 1<<7 | (cmd == " HEARTBEAT SNR" ? 1 : 0) << 6 | (num & 63)`; i.e. bit 7 = 1,
  bit 6 = "heartbeat-SNR" flag, bits 5..0 = packNum value.
* Otherwise `value = cmd & 127` (bit 7 = 0), no number.

unpackCmd(value): if bit 7 is set → command 25 (` SNR`), or 29 (` HEARTBEAT SNR`) if bit 6
is also set, number = bits 5..0. Else command = value & 127, number = 0. The decoder then
appends `formatSNR(num − 31)` for the SNR commands. (Non-SNR numbers cannot be carried in a
compound-directed frame.)

### 3.9 packAlphaNumeric22 and packPwr (declared but not used on the wire)

`packAlphaNumeric22(word, flag)`: strip anything outside `A–Z 0–9 / space`, pad to 4 chars
with spaces, `v = 38³·i(w0) + 38²·i(w1) + 38·i(w2) + i(w3)`, then `packed = (v << 1) | flag`
(22 bits: 21 + flag). Unpack peels the flag then four `mod 38` digits. **No current frame
type uses this field**; it is legacy. `packPwr` / `formatPWR` are declared with no
implementation in this fork; the dBm↔mW table
`{0:1, 3:2, 7:5, 10:10, 13:20, 17:50, 20:100, 23:200, 27:500, 30:1000, 33:2000, 37:5000,
40:10000, 43:20000, 47:50000, 50:100000, 53:200000, 57:500000, 60:1000000}` exists only for
display helpers.

---

## 4. The directed command table

Command strings are stored **with their leading space** (except `?` and `>`), and the
canonical unpacked string is the one shown in the "canonical" column (when several strings
share a code, the receiver always produces the canonical one: it is the alphabetically first
key, where space sorts before all printable characters and a shorter string sorts before a
longer one with the same prefix).

| Code | Strings mapped to this code | Canonical unpack string | Buffered | Checksum | Auto-reply | SNR-num | Notes |
|---|---|---|---|---|---|---|---|
| −1 | ` HEARTBEAT`, ` HB`, ` CQ` | ` CQ` | yes* | – | no | no | pseudo-commands used only for internal processing of heartbeats/CQs; **never packed** |
| 0 | ` SNR?`, `?` | ` SNR?` | yes* | – | **yes** | no | query SNR |
| 1 | ` DIT DIT` | ` DIT DIT` | yes* | – | no | no | two bits |
| 2 | ` NACK` | ` NACK` | yes* | – | **yes** | no | negative acknowledge |
| 3 | ` HEARING?` | ` HEARING?` | yes* | – | **yes** | no | query stations heard |
| 4 | ` GRID?` | ` GRID?` | yes* | – | **yes** | no | query grid |
| 5 | `>` | `>` | **yes** | 16 | no | no | relay message |
| 6 | ` STATUS?` | ` STATUS?` | yes* | – | **yes** | no | query status |
| 7 | ` STATUS` | ` STATUS` | yes* | – | no | no | my status |
| 8 | ` HEARING` | ` HEARING` | yes* | – | no | no | stations I hear |
| 9 | ` MSG` | ` MSG` | **yes** | 16 | **yes** | no | complete message |
| 10 | ` MSG TO:` | ` MSG TO:` | **yes** | 16 | **yes** | no | store message at a station |
| 11 | ` QUERY` | ` QUERY` | **yes** | 16 | **yes** | no | generic query |
| 12 | ` QUERY MSGS`, ` QUERY MSGS?` | ` QUERY MSGS` | **yes** | 16 | **yes** | no | any stored messages? |
| 13 | ` QUERY CALL` | ` QUERY CALL` | **yes** | 16 | **yes** | no | can you ping callsign? |
| 14 | ` ACK` | ` ACK` | yes* | – | **yes** | no | acknowledge (was reserved in 2.1) |
| 15 | ` GRID` | ` GRID` | **yes** | 0 (none) | no | no | my grid |
| 16 | ` INFO?` | ` INFO?` | yes* | – | **yes** | no | query info |
| 17 | ` INFO` | ` INFO` | yes* | – | no | no | my info |
| 18 | ` FB` | ` FB` | yes* | – | no | no | fine business |
| 19 | ` HW CPY?` | ` HW CPY?` | yes* | – | no | no | how copy? |
| 20 | ` SK` | ` SK` | yes* | – | no | no | end of contact |
| 21 | ` RR` | ` RR` | yes* | – | no | no | roger roger |
| 22 | ` QSL?` | ` QSL?` | yes* | – | no | no | do you copy? |
| 23 | ` QSL` | ` QSL` | yes* | – | no | no | I copy |
| 24 | ` CMD` | ` CMD` | **yes** | 16 | no | no | command |
| 25 | ` SNR` | ` SNR` | yes* | – | no | **yes** | I heard you at SNR |
| 26 | ` NO` | ` NO` | yes* | – | no | no | negative |
| 27 | ` YES` | ` YES` | yes* | – | no | no | affirmative |
| 28 | ` 73` | ` 73` | yes* | – | no | no | best regards |
| 29 | ` HEARTBEAT SNR` | ` HEARTBEAT SNR` | yes* | – | no | **yes** | heartbeat acknowledgement with SNR (was ACK in 2.1) |
| 30 | ` AGN?` | ` AGN?` | yes* | – | **yes** | no | repeat |
| 31 | ` `, `  ` (two spaces) | ` ` | yes* | – | no | no | free text follows |

Sets (protocol facts):

* **allowed**: every code −1 and 0..31 (nothing is disallowed in this version).
* **auto-reply** commands: {0, 2, 3, 4, 6, 9, 10, 11, 12, 13, 14, 16, 30}.
* **buffered** commands (explicit set): {5, 9, 10, 11, 12, 13, 15, 24}.
  **However** the "is buffered" test is: *the command string contains a space* **or** its
  code is in the explicit set. Since every command string except `?` and `>` begins with a
  space, and `>` is in the set, **every command except `?` is treated as buffered**
  (rows marked "yes*"). The practical meaning of "buffered" is given in §9: a directed frame
  without the Last flag opens a buffer that collects the following data frames.
* **SNR-number** commands (a number in the frame is displayed as an SNR): {25, 29}.
* **checksummed** commands and their CRC width: 5→16, 9→16, 10→16, 11→16, 12→16, 13→16,
  15→0 (explicitly none), 24→16. No command uses the 32-bit checksum in this version
  (checksum32 exists and the receive side supports it; see §8).
  Exception: when the destination is `@APRSIS` and the command is ` MSG` or ` MSG TO:`, no
  checksum is appended by the transmitter.

### 4.1 Parsing directed text (transmit side)

A line is a directed message if it matches, at its start:

```
^(?<callsign>[@]?[A-Z0-9/]+)(?<cmd>\s?(?:AGN[?]|QSL[?]|HW CPY[?]|MSG TO[:]|SNR[?]|INFO[?]|GRID[?]|STATUS[?]|QUERY MSGS[?]|HEARING[?]|(?:(?:STATUS|HEARING|QUERY CALL|QUERY MSGS|QUERY|CMD|MSG|NACK|ACK|73|YES|NO|HEARTBEAT SNR|SNR|QSL|RR|SK|FB|INFO|GRID|DIT DIT)(?=[ ]|$))|[?> ]))?(?<num>(?<=SNR)\s?[-+]?(?:3[01]|[0-2]?[0-9]))?
```

Observations that matter for compatibility:
* The `cmd` group is optional in the regex, but a message with an **empty cmd is not
  directed** (it falls through to a data frame). A bare space after the callsign matches
  `[?> ]` and yields cmd ` ` = code 31 (free text), so `W0CJW HELLO` is a directed frame
  (cmd 31) followed by data frames carrying `HELLO`.
* The captured cmd (with its leading space, if any) is looked up in the table; if that fails
  the trimmed string is looked up (this is how `?` and `>` are found). The string actually
  found is what determines the code.
* The `num` group only matches immediately after the letters `SNR`.
* `to` must differ from the sender's own callsign and must be a valid standard or compound
  callsign (§3.3, §3.4).
* The consumed length `n` is the length of the whole match; the remainder of the line
  becomes the buffered text (§10).

---

## 5. Heartbeat / CQ variants and groups

### 5.1 CQ strings (`cqString(n)`, used when the heartbeat alt flag = 1; n = bits3)

| n | string |
|---|---|
| 0 | `CQ CQ CQ` |
| 1 | `CQ DX` |
| 2 | `CQ QRP` |
| 3 | `CQ CONTEST` |
| 4 | `CQ FIELD` |
| 5 | `CQ FD` |
| 6 | `CQ CQ` |
| 7 | `CQ` |

Any other n → empty string (cannot happen with 3 bits).

### 5.2 HB strings (`hbString(n)`, alt flag = 0)

All eight entries n = 0..7 are the string `HB` (historically 0 HB, 1 HB AUTO, 2 HB AUTO
RELAY, 3 HB AUTO RELAY SPOT, 4 HB RELAY, 5 HB RELAY SPOT, 6 HB SPOT, 7 HB AUTO SPOT — the
status flags were deprecated in 2.2 and every value now renders identically). The display
layer replaces `HB` with `HEARTBEAT`, so a received heartbeat always reads
`<CALL>: @HB HEARTBEAT <GRID> `.

### 5.3 Heartbeat text parsing (transmit side)

A line is a heartbeat/CQ if it matches at its start:

```
^\s*(?<callsign>[@](?:ALLCALL|HB)\s+)?(?<type>CQ CQ CQ|CQ DX|CQ QRP|CQ CONTEST|CQ FIELD|CQ FD|CQ CQ|CQ|HB|HEARTBEAT(?!\s+SNR))(?:\s(?<grid>[A-R]{2}[0-9]{2}))?\b
```

* The optional leading `@ALLCALL ` / `@HB ` is accepted and ignored.
* `type` beginning with `CQ` → alt = 1 and bits3 = the CQ table index of the exact string
  (unknown → 0). Otherwise alt = 0 and bits3 = the HB table index of the string (`HB` → 0;
  `HEARTBEAT` is not in the table → 0).
* A 4-character grid matching `[A-X]{2}[0-9]{2}` is packed (§3.5); otherwise num = 32767.
  When alt = 1, bit 15 of num is set (`num |= 0x8000`).
* The frame is a compound-layout frame (§2.2) of type 000 with the **sender's own callsign**
  packed with packAlphaNumeric50 — so a heartbeat can carry any compound call directly.
* Consumed length = the length of the whole match.

### 5.4 Group callsigns (base calls) and their 28-bit values

`NBASECALL = 262,177,560`. Each entry packs (§3.3) to `NBASECALL + k`:

| k | name | k | name | k | name |
|---|---|---|---|---|---|
| 1 | `<....>` (incomplete/placeholder callsign) | 19 | `@GROUP/5` | 37 | `@ARES` |
| 2 | `@ALLCALL` | 20 | `@GROUP/6` | 38 | `@MARS` |
| 3 | `@JS8NET` | 21 | `@GROUP/7` | 39 | `@AMRRON` |
| 4 | `@DX/NA` | 22 | `@GROUP/8` | 40 | `@RACES` |
| 5 | `@DX/SA` | 23 | `@GROUP/9` | 41 | `@RAYNET` |
| 6 | `@DX/EU` | 24 | `@COMMAND` | 42 | `@RADAR` |
| 7 | `@DX/AS` | 25 | `@CONTROL` | 43 | `@SKYWARN` |
| 8 | `@DX/AF` | 26 | `@NET` | 44 | `@CQ` |
| 9 | `@DX/OC` | 27 | `@NTS` | 45 | `@HB` |
| 10 | `@DX/AN` | 28 | `@RESERVE/0` | 46 | `@QSO` |
| 11 | `@REGION/1` | 29 | `@RESERVE/1` | 47 | `@QSOPARTY` |
| 12 | `@REGION/2` | 30 | `@RESERVE/2` | 48 | `@CONTEST` |
| 13 | `@REGION/3` | 31 | `@RESERVE/3` | 49 | `@FIELDDAY` |
| 14 | `@GROUP/0` | 32 | `@RESERVE/4` | 50 | `@SOTA` |
| 15 | `@GROUP/1` | 33 | `@APRSIS` | 51 | `@IOTA` |
| 16 | `@GROUP/2` | 34 | `@RAGCHEW` | 52 | `@POTA` |
| 17 | `@GROUP/3` | 35 | `@JS8` | 53 | `@QRP` |
| 18 | `@GROUP/4` | 36 | `@EMCOMM` | 54 | `@QRO` |

Packing of groups:
* As the TO (or FROM) of a **directed frame** (§2.3): the fixed 28-bit value above. Groups
  not in this table (e.g. `@FOO`) are *compound* callsigns: the directed frame carries
  `<....>` (k = 1) in the TO slot and the group name is sent in a separate compound frame
  (§10.3) via packAlphaNumeric50, where `@` is index 38 in slot 0.
* In heartbeat/compound frames callsigns are always packAlphaNumeric50; the table is not
  involved.
* For destination validation (`isValidCallsign`, the only check applied to TO) a group
  name that is in the table is always a *valid, non-compound* callsign, so it goes in the
  28-bit slot; everything else starting with `@` is compound and goes the compound route.
  (A separate helper used only on the *sender's own* callsign would classify `@` names as
  compound; it never sees a group name in practice.)

### 5.5 `isGroupAllowed`

A group may be joined/used by the local station unless it is one of the **disallowed**
groups: `@APRSIS`, `@JS8NET`. Everything else (including custom `@…` names) is allowed.

### 5.6 `@ALLCALL` / `@HB` semantics on receive

* A received heartbeat (alt = 0) is processed as if it were the directed command
  ` HEARTBEAT` from CALL to `@HB`; a CQ (alt = 1) as ` CQ` from CALL to `@ALLCALL`.
* "All-call included" means the TO text contains `@ALLCALL` or `@HB`. "Group call included"
  means TO is one of the groups the local station has joined (`@HB` is auto-joined when
  heartbeating is enabled).
* The heartbeat acknowledgement reply is the text `"<CALL> HEARTBEAT SNR <formatSNR> [extra]"`
  (e.g. `KN4CRD HEARTBEAT SNR +10`), which packs as a directed frame with command 29 and the
  SNR in num6. Heartbeat frames are sent with the text `"<MYCALL>: HEARTBEAT <GRID4>"`, CQ
  frames with `"CQ CQ CQ <GRID4>"` (or a user-configured CQ message).

---

## 6. Huffman text coding (Normal-submode data frames with header `10`)

### 6.1 The default table (character → code), complete

| Char | Code | Char | Code | Char | Code |
|---|---|---|---|---|---|
| space | `01` | `M` | `101011` | `X` | `1010100` |
| `E` | `100` | `W` | `001011` | `0` | `0010101` |
| `T` | `1101` | `F` | `001001` | `J` | `0010100` |
| `A` | `0011` | `G` | `000101` | `1` | `0010001` |
| `O` | `11111` | `Y` | `000011` | `Q` | `0010000` |
| `I` | `11100` | `P` | `1111011` | `2` | `0001001` |
| `N` | `10111` | `B` | `1111001` | `Z` | `0001000` |
| `S` | `10100` | `.` | `1110100` | `3` | `0000101` |
| `H` | `00011` | `V` | `1100101` | `5` | `0000100` |
| `R` | `00000` | `K` | `1100100` | `4` | `11110101` |
| `D` | `111011` | `-` | `1100001` | `9` | `11110100` |
| `L` | `110011` | `+` | `1100000` | `8` | `11110001` |
| `C` | `110001` | `?` | `1011001` | `6` | `11110000` |
| `U` | `101101` | `!` | `1011000` | `7` | `11101011` |
|     |          | `"` | `1010101` | `/` | `11101010` |

44 symbols; the code is prefix-free (verified). There is no end-of-text symbol in the
table (an EOT character U+0004 is referenced by the decoder but never present in the table,
so it has no effect).

### 6.2 Which text may be Huffman coded

Every character of the input (after upper-casing) must be a table key; otherwise Huffman
packing of that frame fails (returns 0 consumed characters) and the JSC alternative is used.
There is no escaping inside Huffman frames.

### 6.3 Encoding a frame

Sequence of codes, one per character, filled per §2.6 with a 2-bit header `10`. The
consumed-character count is the number of characters whose codes were appended.

### 6.4 Decoding

After unpadding (§2.6) decode the bit string as an ordinary prefix code from the table,
left to right, until the remaining bits do not start with any code (the remainder is
discarded). Since the code is prefix-free the result is unique.

### 6.5 Extended characters and escaping (text layer, both codings)

The **extended character set** (`extendedChars`) is defined as the first byte of every
JSC `prefix` entry whose count is 1 (§7.5, Appendix A.3), i.e. the ASCII characters
`! " # $ % & ( ) * + , / 0 ; > ? @ \ [ ] ^ _ ` { | } ~`, space, newline, 0x1A, and the
Latin-1 letters `¡ ¿ À Á Â Ã Ä Å Æ Ç È É Ê Ë Ì Í Î Ï Ð Ñ Ò Ó Ô Õ Ö Ø Ù Ú Û Ü Ý Þ`.
The UI uses this set to decide which non-alphanumeric characters may be typed. Characters
outside the Huffman table (§6.1) can be sent only in JSC frames; the Latin-1 letters listed
are the only non-ASCII characters that have their own JSC entries.

Any other non-ASCII character (code point ≥ 0x80) is **escaped** before coding as the 6
ASCII characters `\U` followed by the 4-digit lower-case hexadecimal code unit
(e.g. `é` → `\U00e9`). On receive, the sequences `\Uxxxx`, `\uxxxx`, `U+xxxx`, `u+xxxx`
(4 hex digits, any case) are replaced by the character. (An alternative form using the
substitute character 0x1A instead of `\U` exists behind a compile-time switch and is *not*
the shipped behaviour.) Escaping is done by the UI before the text reaches the frame
builder; the frame builder itself only sees the escaped text.

---

## 7. JSC — (s,c)-dense word-index compression

### 7.1 Parameters

* Word table size **N = 262,144** entries (indices 0..262143).
* Codeword parameters: `b = 4` (nibble size), `s = 7` (number of *stopper* values),
  `c = 2^b − s = 9` (number of *continuer* values).
* Nibble values 0..6 are stoppers, 7..15 are continuers.

### 7.2 Codeword for (index, separator)

Let `q = index / 7`, `r = index mod 7`.

1. The final unit is 5 bits: the 4-bit nibble `r` followed by one **separator bit**
   (1 = "a space follows this token", 0 = no space).
2. Before it come zero or more 4-bit continuer nibbles encoding `q` in *bijective base 9*
   (digits 1..9 represented as nibble value 7..15), most significant digit first:
   ```
   x = q
   while x > 0:
       x = x − 1
       prepend nibble (x mod 9) + 7
       x = x / 9
   ```
3. Codeword = continuer nibbles ‖ stopper nibble ‖ separator bit.

Length is 5 bits for indices 0..6, 9 bits for 7..69, 13 bits for 70..636, 17 bits for
637..5739, 21 bits for 5740..51666, 25 bits for 51667..262143.

Examples: index 0 → `0000 0`; index 6 with separator → `0110 1`; index 7 → `0111 0000 0`;
index 69 → `1111 0110 0`; index 70 → `0111 0111 0000 0`; index 637 → `0111 0111 0111 0000 0`;
index 6571 (`HELLO`) with separator → `0111 1000 1011 1000 0101 1`.

### 7.3 Decoding a bit string

```
base[0] = 0; base[1] = 7; base[k] = base[k−1] + 7·9^(k−1)   (k = 2..7)
  → base = [0, 7, 70, 637, 5740, 51667, 465010, 4185097]
```

1. Tokenise: read 4 bits at a time; if fewer than 4 remain, stop. Append the nibble to the
   list. If the nibble is < 7 (a stopper) **and at least one more bit remains**, read one
   more bit; if it is 1 record "separator after this nibble". (If a stopper is the very last
   thing and no separator bit remains, it is still a valid stopper with no separator.)
2. Walk the nibble list: starting at position `start`, accumulate continuers
   `j = j·9 + (nibble − 7)` for k consecutive nibbles ≥ 7; if `j ≥ N` stop decoding; if the
   list ends before a stopper is found stop decoding. Then `index = j·7 + stopper + base[k]`;
   if `index ≥ N` stop. Output the word `map[index]` (the **full NUL-terminated string** of
   the entry, see §7.6 on the two entries whose recorded size differs), then output a single
   space if a separator was recorded for this stopper's position. Advance `start` by k+1.
3. Concatenate all outputs.

### 7.4 Compressing text

Input: the (upper-case, escaped) text. Output: a list of (codeword, consumed-char-count).

1. Split the text on single spaces, **keeping empty parts** (so `A  B` → `A`, ``, `B` and a
   trailing space yields a final empty part).
2. For each part i:
   * If the part is empty and it is **not the last part**, replace it with a single space
     and mark "isSpaceCharacter". (An empty *last* part — i.e. text ending in a space, or an
     empty text — produces nothing; the trailing space is instead expressed by the separator
     bit of the previous token.)
   * While the part is non-empty: look up the **longest table entry that is a prefix** of
     the remaining part (§7.5). If nothing matches, abandon the rest of this part (the
     characters are silently dropped and *not* counted — an implementation should reject
     such input beforehand; all printable ASCII, `\n`, `\x1A`, `\` and the Latin-1 letters of
     §6.5 always match as single characters). Remove the matched entry's *recorded size*
     characters from the part. `isLast` = the part is now empty.
     `separator = isLast AND NOT isSpaceCharacter AND NOT (this is the last part)`.
     Emit `codeword(index, separator)` with consumed count = entry size + (1 if separator).
3. Because parts are re-split from the original text in the frame builder, a codeword that
   does not fit in a frame is simply re-generated for the next frame from `text[consumed:]`,
   so words can straddle frames (a word split mid-way yields tokens with separator 0 and the
   continuation starts the next frame).

Space handling summary: a space between two words is *not* a token — it is the separator
bit of the last token of the preceding word. Consecutive spaces and a leading space are sent
as explicit space tokens (index 67, entry `" "`). A trailing space is the separator bit on
the final token.

Case: the tables are upper-case only; there is no case information on the wire.

### 7.5 Lookup (longest-prefix match) and the three tables

There are three tables, all derived from one word list:

* **map[N]** — indexed by *rank* (0 = most frequent). Entry = (string, size, index) where
  index == position. This is what the decoder uses (index → word) and what the encoder
  uses to know the size of a matched entry.
* **list[N]** — the same entries sorted **in descending byte order of the string**
  (`~` first, `!` last; e.g. `ZZZZ` before `ZZZ` before `ZZ`), each carrying its rank index.
  This ordering guarantees that when scanning forward, a longer string is met before any
  of its own prefixes, so the first prefix-match found is the longest one.
* **prefix[103]** — one entry per possible first byte: (string of 1 char, count, start)
  meaning "entries of `list` whose string begins with this byte occupy positions
  start .. start+count−1". Entries with count 1 are treated specially.

Lookup of an input word `w` (Latin-1 bytes):
1. Scan `prefix` in order for the first entry whose first byte equals `w[0]`.
   No entry → not found.
2. If that entry's count is 1 → found: return the index of `list[start]` **without comparing
   the rest** (this short-circuit means, e.g., the 8-character table entry `@ALLCALL` is
   unreachable: the `@` prefix entry has count 1 and always yields the single-character `@`
   entry).
3. Otherwise scan `list[start .. start+count−1]` in order and return the index of the first
   entry E such that the first `E.size` bytes of `w` equal the first `E.size` bytes of `E`
   (C `strncmp(w, E.str, E.size) == 0` semantics: a NUL in `w`, i.e. `w` being shorter than
   `E.size`, is a mismatch).
4. Nothing matched → not found. (This cannot happen for a first byte present in the prefix
   table because every such range ends with the single-character entry.)

The full tables are **~7 MB of source each** (`JSC_list.cpp`, `JSC_map.cpp`,
`JSC::prefix` is at the end of `JSC_list.cpp`). They are protocol data: a compatible
implementation **must obtain them verbatim** from the JS8Call sources (they are licensed
GPLv3 as part of JS8Call; the word list itself is data — check licensing before embedding)
or regenerate an identical file and validate it with the excerpts in Appendix A (first 200
and last 20 entries of `list`, the complete `prefix` table, and the first 120 entries of
`map`). Suggested validation: N = 262,144; `map[i].index == i` for all i; the rank indices
in `list` are a permutation of 0..N−1; SHA-256 of the sequence of (string,size) pairs in
`map` order compared with a value computed from a known-good copy.

### 7.6 Data quirks that must be preserved

* `list` is in descending byte order **except** for five misplacements which affect the
  prefix ranges (a space entry at list position 8 between `]` and `[`; `\x1A` before
  `JSQCALL`; `\n` before `\`; `Þ` after `BO92`; `@ALLCALL` inside the `A` range). The
  prefix table has 103 entries whose counts sum to 262,179 (ranges overlap by a few
  entries); 36 positions inside declared ranges start with a different byte and simply
  never match. Do not "fix" the ordering — port the tables byte-for-byte and implement the
  lookup exactly as in §7.5.
* `map[81]` = `@ALLCALL` has recorded size **7** (not 8); `map[262143]` = `ROSIDS` has
  recorded size **1**. The decoder outputs the full string; the encoder cannot reach
  index 81 (see step 2 above) and reaches 262143 only for the input `R`-prefixed… never in
  practice (`R` alone matches rank 8). Preserve the recorded sizes anyway.
* Common English function words such as `THE`, `TH`, `HI`, `AN`, `IN`, `OK` are **not** in
  the table (they compress as single letters, e.g. `THE` → `T`,`H`,`E`), while
  `THIS`, `HIHI`, `QSL`, `TEST`, `MSG`, `SNR`, `CQ`, `DE`, `73`, `GM`… are.
* All 95 printable ASCII characters, `\n` (rank 69), `\` (rank 68), `\x1A` (rank 72),
  space (rank 67) and the 32 Latin-1 letters listed in §6.5 exist as single-character
  entries. Lowercase letters do not exist.
* Word length distribution: 103 one-char, 119 two-char, 5,957 three-char, 102,643
  four-char, … up to 26 characters (2 entries).

### 7.7 "Checker" and "map" roles

The *map* table is the rank-indexed table used for decoding and for reading an entry's
size. The *checker* is not part of the wire protocol: it is a UI spell-checker that
underlines a word if `lookup(word)` does not return an entry whose size equals the word
length (words shorter than 4 characters, numerics and valid callsigns are always "correct"),
and offers suggestions ranked by table index among 1-edit-distance candidates. The
encoder's choice between Huffman and JSC is not made by the checker but by comparing
consumed character counts (§10.2).

---

## 8. Checksums

### 8.1 checksum16

* Input string → bytes in the local 8-bit encoding (UTF-8 on all modern platforms; the
  text is escaped ASCII by this point, so this is moot in practice).
* CRC-16/KERMIT (a.k.a. CRC-16/CCITT-TRUE): polynomial 0x1021, initial value 0x0000,
  input and output reflected, final XOR 0x0000. Check value for `123456789` = 0x2189.
* Result → pack16bits (§3.2) → exactly 3 base-41 characters. (A rule pads with spaces to 3
  characters if shorter; it can never trigger.)
* Validation: recompute and compare the 3-character strings exactly.

Worked: `checksum16("HELLO WORLD")`: CRC = 0x236F = 9071 → 9071/1681 = 5 → `5`;
(9071 − 8405)/41 = 16 → `G`; 9071 mod 41 = 10 → `A` ⇒ **`5GA`**.
`checksum16("123456789")` = 0x2189 = 8585 → `54G`. `checksum16("HELLO")` = 0x1502 = 5378
→ **`387`**.

### 8.2 checksum32

* CRC-32/BZIP2: polynomial 0x04C11DB7, initial value 0xFFFFFFFF, **no** reflection, final
  XOR 0xFFFFFFFF. Check value for `123456789` = 0xFC891918.
* Result → pack32bits → exactly 6 base-41 characters (pad rule to 6 never triggers).

Worked: `checksum32("123456789")` = 0xFC891918 → high 0xFC89 = 64649 → `.IX`, low 0x1918 =
6424 → `3XS` ⇒ **`.IX3XS`**. `checksum32("HELLO WORLD")` = 0x96FB9F29 → `M?TO9W`;
`checksum32("HELLO")` → `HM17Q+`.

### 8.3 Where checksums go

Transmit (§10.4): for a directed command that is checksummed, the trailing text `T` is
left-stripped and becomes `T + " " + checksum16(T)` (or checksum32). The checksum is over
the text *without* the separating space and without the command.

Receive (§9.4): after concatenating the buffered data-frame texts and right-stripping,
left-strip; the checksum is the last 3 (or 6) characters, the message is everything before
the last 4 (or 7) characters (i.e. also dropping the separating space); validate; a
mismatch discards the whole buffered message.

---

## 9. Multi-frame message assembly on receive

### 9.1 Inputs per decoded frame

For each successfully decoded transmission the receiver has: the 12-character frame string,
i3 (the "bits": First/Last/Data flags), the submode, the audio frequency offset (Hz), SNR,
time offset and a UTC timestamp. It first classifies and unpacks the frame (§2.1 order,
honouring the Data flag) into a `DecodedText` with: frame type; `message` (display text);
`isCompound` (a compound-layout frame — heartbeat, compound, compound-directed);
`isHeartbeat`, `isAlt`; `compoundCall` (the callsign from the 50-bit field); `extra` (grid
or command text); and `directed` = the list [FROM, TO, CMD, (NUM)] for directed and
compound-directed frames (`isDirectedMessage` ⇔ list has more than 2 elements).

### 9.2 De-duplication

A frame is ignored if an identical (submode, frame-string) pair was seen less than half a
transmission period ago (periods: Normal 15 s, Fast 10 s, Turbo 6 s, Slow 30 s, Ultra 4 s).

### 9.3 Buffers keyed by frequency offset

A **message buffer** exists per audio offset and holds:
* `cmd` — one directed command detail (FROM, TO, CMD, extra/NUM, bits, timestamp, …), set
  when a directed frame that requires buffering arrives;
* `compound` — a FIFO of compound-call details (callsign, grid, bits, timestamp) from
  Compound frames;
* `msgs` — the ordered list of buffered data-frame details (text, bits, timestamp).

Offset matching ("hasExistingMessageBuffer"): an incoming frame at offset f matches an
existing buffer at f exactly, or any buffer at f±R where R is the submode's **rx threshold**:
Normal 10 Hz, Fast 16, Turbo 32, Slow 10, Ultra 50. When matched with the *drift* option
(used by the decode path) the buffer is **re-keyed** to the new offset f. Band-activity
history is re-keyed the same way.

### 9.4 Processing order for one decoded frame

1. (Band activity) If the frame has the **First** flag and a buffer exists at (or near) this
   offset → **delete** that buffer (a new message has started on this offset).
2. If a buffer exists at (or near) this offset **and** the frame is neither compound nor
   directed (i.e. it is a data frame) → append it to `buffer.msgs` (flag it "buffered").
   Whether buffered or not, the frame is also appended to the per-offset band-activity
   history (max 10 entries) and to the rx-activity queue (§9.6).
3. If the frame is **compound and not directed** (heartbeat or plain compound):
   * heartbeat, alt = 1 → synthesize command FROM=call, TO=`@ALLCALL`, CMD=` CQ`, grid =
     extra → command queue (§9.7);
   * heartbeat, alt = 0 → synthesize FROM=call, TO=`@HB`, CMD=` HEARTBEAT` → command queue;
   * plain compound (type 001) → *buffer it*: append the call detail (callsign, grid, bits,
     timestamp) to `buffer.compound` at this offset (creating the buffer if needed, merging
     a nearby one).
4. If the frame **is directed** (standard or compound-directed): FROM, TO, CMD, EXTRA =
   parts[3..] joined by spaces (the SNR/number if present).
   * If `(isCommandBuffered(CMD) and Last flag is NOT set)` **or** FROM is `<....>` **or**
     TO is `<....>`: **buffer it** — merge any nearby buffer to this offset, set
     `buffer.cmd` = this command and **clear `buffer.msgs`**. (If neither FROM nor TO is
     a placeholder the sender is logged as heard immediately.)
   * Otherwise (complete single-frame command) → command queue immediately.

Remember from §4 that every command except `?` counts as "buffered", so effectively: a
directed frame that is not the last frame of its transmission opens a buffer for the
text frames that follow it.

### 9.5 Completing buffers

Two periodic passes run over all buffers (after each decode cycle):

**Compound completion** (`processCompoundActivity`), for buffers with a non-empty `compound`
queue:
* The buffered `cmd` must have valid bits (0, or any of First/Last/Data set) — else skip.
* If both FROM and TO are `<....>`, two compound calls are needed; if one is, one is
  needed; skip until enough have arrived.
* Fill FROM first (dequeue → FROM = call, grid = that grid), then TO (dequeue → TO = call).
  If the dequeued compound frame carried the Last flag, adopt its bits as the command's bits.
  The command timestamp becomes the minimum of all involved timestamps.
* If the command still lacks the Last flag → skip (its text is still arriving).
* Otherwise → command queue; delete the buffer; remember this offset as the "last closed
  buffer offset".

**Buffered-text completion** (`processBufferedActivity`), for every buffer:
* age = now − latest timestamp among cmd / last compound / last msg.
  If age > 60 s and there are msgs → treat the last msg as if it had the Last flag.
  If age > 90 s → delete the buffer, done.
* No msgs → skip. Last msg lacks the Last flag → skip (still arriving).
* `message` = concatenation of all `msgs[i].text` in arrival order, right-stripped.
* If `isCommandBuffered(cmd.CMD)`: with checksum width w = isCommandChecksumed(CMD):
  w = 32 → left-strip, checksum = last 6 chars, message = message minus last 7 chars,
  validate checksum32; w = 16 → same with 3 / 4 and checksum16; w = 0 → valid.
  Not buffered → valid.
* Valid → `cmd.bits |= Last`, `cmd.text = message`, mark "buffered" → command queue.
  Invalid → discard (log). Either way delete the buffer and record the offset as last closed.

Note the ordering subtlety: the directed frame is delivered *only* when its text has been
completed by a Last-flagged data frame (or the 60 s timeout); a directed frame that itself
carried Last was delivered immediately in §9.4.

### 9.6 Display of incremental (unbuffered or in-progress) activity

Each decoded frame also goes to the rx-activity queue whose consumer decides what to print
in the main text area:
* A frame is shown if its offset is within R Hz of the operator's own offset, **or** it
  belongs to a buffer whose `cmd.TO` is the local callsign (or a joined group) — in which
  case, if the buffer holds a compound call, the text is prefixed with `"<CALL>: "`.
* Partial directed frames (text containing `<....>`) are not shown; heartbeat-like texts
  (`": HB "`, `": @ALLCALL HB"`) are handled elsewhere.
* First-flag data frames whose text starts with `"<CALL>:"` cause `<CALL>` to be logged as
  heard.
* Display rule: if the frame has the **Last** flag the shown text is
  `rstrip(text) + " " + EOT + " "`, where EOT is the user-configurable end-of-transmission
  marker, default **`♢` (U+2662)**. Frames are appended to the same output line ("block")
  as previous frames from the same offset (offset matched exactly, or rounded down/up to a
  multiple of 10 Hz) until a line containing the EOT marker is seen; a First-flagged frame
  always starts a new line.
* Idle marker: if the newest activity at an offset has no Last flag and is older than 1.5
  periods, a "missing frame indicator" text is inserted, default **`……`** (two U+2026),
  and also appended to an open buffer's `msgs` at that offset (so it appears inside the
  assembled message when frames are lost).

### 9.7 Command delivery and final text

When a command detail (possibly with buffered text) is dequeued:
* Commands with `<....>` still in FROM/TO are dropped; disallowed commands dropped.
* `baseText = TO + CMD` (CMD includes its leading space), then `" " + EXTRA` if non-empty,
  then `" " + TEXT` if non-empty. If the Last flag is set:
  `baseText = rstrip(baseText) + " " + EOT + " "`.
* Displayed/logged text = `FROM + ": " + baseText`.

Examples of final display text (default EOT):
* `KN4CRD: W0CJW SNR? ♢ `
* `KN4CRD: W0CJW SNR -05 ♢ `
* `KN4CRD: W0CJW MSG HELLO ♢ ` (after checksum validation and removal of ` 387`)
* `KN4CRD: @HB HEARTBEAT EM73 ♢ `
* `KN4CRD: @ALLCALL CQ CQ CQ EM73 ♢ `
* A free-text data-only transmission of two frames `THE QUICK BROWN ` + `FOX JUMPS` is
  shown as one line `THE QUICK BROWN FOX JUMPS ♢ ` (the second frame is appended to the
  first frame's line; the EOT is added when the Last frame arrives).

There is no explicit " + " continuation marker in this version; continuation is expressed
by appending to the same line, and an interrupted message shows the `……` indicator.

The receiver only auto-replies (§4 auto-reply set) when TO is the local call, a joined
group, or an all-call; with rate limiting per sender for all-calls (15 minutes), a
whitelist/blacklist, and never while a buffer addressed to the local station is open.

---

## 10. Message building on transmit (buildMessageFrames)

Inputs: MYCALL, MYGRID (first 4 chars), SELECTEDCALL (may be empty), TEXT (one line),
`forceIdentify`, `forceData`, submode. Output: an ordered list of (frame string, i3 flags).

### 10.1 Line preparation

1. If `forceData` (typeahead continuation of a message already in progress): set
   `forceIdentify = false` and `hasData = true` (everything becomes data frames).
2. **Auto-remove own call**: if the line starts with `MYCALL:` or `MYCALL ` remove that
   prefix and left-strip.
3. **Auto-prepend the selected call**: if SELECTEDCALL is non-empty and the line does not
   start with it, does not start with a backtick, and this is not forced data: unless the
   line starts with `@ALLCALL`, or with a CQ string, or with an HB string, or with a valid
   standard callsign longer than 3 characters (as found by the callsign parser), prepend
   `SELECTEDCALL` + (a space unless the line already begins with one).

### 10.2 Frame loop

While the line is non-empty, try the packers **in this order** on the current line and use
the first that applies:

| Order | Packer | Applies when | i3 | Consumes |
|---|---|---|---|---|
| 1 | heartbeat/CQ (§5.3) | matches and no directed/data frame has been emitted yet | 0 | match length |
| 2 | compound (§10.3, line starts with a backtick) | matches and no directed/data yet | 0 | match length |
| 3 | directed (§4.1) | matches and no directed/data yet | 0 | match length |
| 4 | data | Normal submode: the better of Huffman (`10`) and JSC (`11`) by consumed characters, JSC wins ties; other submodes: JSC without header ("fast data") | Normal: 0; others: Data (4) | the consumed count |

After a directed frame `hasDirected = true`; after a data frame `hasData = true`; either
forces all subsequent frames to be data frames. Heartbeat and compound frames do not set
either flag.

**Forced identification**: before packing a data frame, if `forceIdentify` and this would be
the first frame of the message, no call is selected, the line is not directed, and neither
the heartbeat nor the compound packer matched, and the line does not already contain
MYCALL, the line is rewritten to `"MYCALL: " + line` (so plain free text always starts with
the sender's call, which receivers use to spot the sender, §9.6).

If a data packer consumes 0 characters (unencodable text) the loop would not progress —
implementations should guard against this (the reference relies on the UI sanitising text).

### 10.3 Directed messages with compound callsigns

When the directed packer matched with command CMD, destination TO and number NUM:

* **Case 0** — neither MYCALL nor TO is compound: emit the single **Directed** frame.
* **Cases 1–3** — MYCALL is compound and/or TO is compound: emit instead
  1. a **Compound** frame (type 001) built from the text `` `MYCALL MYGRID `` (callsign =
     MYCALL via packAlphaNumeric50, num = grid), then
  2. a **CompoundDirected** frame (type 010) built from `` `TO CMD NUM `` (callsign = TO,
     which may itself be a standard call, num = 32410 + packCmd(CMD, NUM)).
  The standard directed frame (which would have contained `<....>` placeholders) is **not**
  sent in this version, although receivers still accept placeholder frames from older
  versions.
  (If the directed packer had to handle a compound TO it packs `<....>` in the TO slot
  internally — that frame is discarded in these cases.)

Compound packer text grammar (also usable directly by the operator with a leading
backtick): `` ^\s*[`](?<callsign>[@]?[A-Z0-9/]+)(?<extra>(?<grid>\s?[A-R]{2}[0-9]{2})?<cmd-group as in §4.1><num-group as in §4.1>) `` —
a command (allowed, in the table) makes it CompoundDirected with num = 32410 + packCmd;
otherwise a grid, if present, is packed; otherwise num = 32767.

### 10.4 Text after a directed command (buffered commands)

After emitting the directed frame(s), `line = line[n:]`. If `isCommandBuffered(CMD)` (all
commands except `?`) and the remainder is non-empty:
1. left-strip the remainder;
2. if the command is checksummed (§4; not for `@APRSIS` + ` MSG`/` MSG TO:`) append
   `" " + checksum16(remainder)` (or checksum32 — unused);
3. the remainder is then packed by the data packers in subsequent iterations.

Returned metadata (`dirTo`, `dirCmd`, `dirNum`) lets the UI disable typeahead for
checksummed commands (adding text after the checksum would invalidate it).

### 10.5 Flags

Finally, the first frame of the list gets `|= First (1)` and the last gets `|= Last (2)`.
Data frames in non-Normal submodes carry `Data (4)` in addition. The transmit loop (§1.3)
re-derives First/Last at send time.

### 10.6 Typeahead / appending

When the operator adds text while a transmission is in progress and the last frame sent
did not carry Last, the new text is built with `forceData = true` (all data frames, no
identification, no auto-prepend) and appended to the queue, continuing the same message.
If the last sent frame did carry Last, a newline is inserted in the local echo and a new
message starts.

### 10.7 Local echo

The transmitter shows what it sent by *decoding its own frames* (the same
`DecodedText` path as receive) and concatenating the per-frame `message` texts, appending
`" " + EOT + " "` after the last frame.

---

## 11. Worked examples (bit-exact)

All frame strings below were produced by an independent re-implementation of the rules in
this document and cross-checked structurally; the heartbeat and directed examples were
additionally verified by hand (§11.1–11.2). Groups of six bits are shown to make the
character mapping visible.

### 11.1 Heartbeat: `KN4CRD: @HB HEARTBEAT EM73`

Transmit text `KN4CRD: HEARTBEAT EM73` → own call removed → `HEARTBEAT EM73` → heartbeat
match (type `HEARTBEAT`, grid `EM73`), alt = 0, bits3 = 0, callsign = KN4CRD.

* callsign50 (`KN4 CRD    `): slots K=20, N=23, 4=4, ␠→0, C=12, R=27, D=13, ␠→0, ␠=36, ␠=36, ␠=36
  → 358,399,795,381,724 = `01010001011111011001110100011111011100010111011100`
* num = packGrid(EM73) = 23,883 = `0101110101001011` (bit 15 = 0: heartbeat, not CQ);
  upper 11 = `01011101010` (746), low 5 = `01011` (11)
* rem = low5 ‖ bits3 = `01011` ‖ `000` = 0x58

72 bits: `000` ‖ callsign50 ‖ `01011101010` ‖ `01011` ‖ `000`

```
000010 100010 111110 110011 101000 111110 111000 101110 111000 101110 101001 011000
  2      Y      -      p      e      -      u      k      u      k      f      O
```

Frame string: **`2Y-pe-ukukfO`**, i3 = 3 (First|Last). Receiver display: `KN4CRD: @HB HEARTBEAT EM73 ♢ `.

The same with `CQ CQ CQ EM73` (alt bit 15 set → num = 56,651, bits3 = 0): **`2Y-pe-ukvkfO`**, displayed `KN4CRD: @ALLCALL CQ CQ CQ EM73 ♢ `. With `CQ DX EM73` (bits3 = 1): `2Y-pe-ukvkfP`.


### 11.2 Directed: `KN4CRD: W0CJW SNR?`

Line `W0CJW SNR?` → directed match: TO = `W0CJW`, cmd ` SNR?` = code 0, no number.

* from28 = packCallsign(KN4CRD) = 146,325,342 = `1000101110001011111101011110`
* to28 = packCallsign(W0CJW) (matched form `␠W0CJW`) = 261,391,963 = `1111100101001000011001011011`
* cmd5 = `00000`; rem = P=0 ‖ Q=0 ‖ num6=000000 = `00000000`

```
011100 010111 000101 111110 101111 011111 001010 010000 110010 110110 000000 000000
  S      N      5      -      l      V      A      G      o      s      0      0
```

Frame string: **`SN5-lVAGos00`**, i3 = 3. Display: `KN4CRD: W0CJW SNR? ♢ `.

Related single-frame directed messages:

| Text | cmd | rem | Frame |
|---|---|---|---|
| `KN4CRD: W0CJW SNR -05` | 25 | num6 = −5+31 = 26 → `00011010` | `SN5-lVAGotaQ` |
| `W0CJW: KN4CRD HEARTBEAT SNR +10` (HB ack) | 29 | num6 = 41 → `00101001` | `VoaCjnSNwzqf` |
| `KN4CRD: W0CJW MSG` (header frame of a buffered MSG, see §11.4) | 9 | 0 | `SN5-lVAGosa0` |


### 11.3 Data frame: `HELLO WORLD` (single frame, Normal submode)

Huffman candidate (header `10`): H `00011` E `100` L `110011` L `110011` O `11111`
␠ `01` W `001011` O `11111` R `00000` L `110011` D `111011` → 2 + 55 = 57 bits, pad
`0` + 14×`1`; 11 characters consumed.

```
100001 110011 001111 001111 111010 010111 111100 000110 011111 011011 111111 111111
→ `XpFFwNy6VR++`
```

JSC candidate (header `11`): tokens `HELLO` (rank 6571, separator 1 because a space follows,
6 chars consumed) → `0111 1000 1011 1000 0101 1` and `WORLD` (rank 907, separator 0, 5 chars)
→ `0111 1011 1001 0100 0`; 2 + 21 + 17 = 40 bits, pad `0` + 31×`1`; 11 characters.

```
110111 100010 111000 010110 111101 110010 100001 111111 111111 111111 111111 111111
→ `tYuMzoX+++++`
```

Both consume 11 characters; ties go to JSC, so the transmitted frame is **`tYuMzoX+++++`**, i3 = 3.

In any non-Normal submode the same text is a fast-data frame (no header, same JSC bits): **`UBXRtA7+++++`**, i3 = 7 (Data|First|Last).


Decoding `tYuMzoX+++++`: bit 0 = 1 → data; bit 1 = 1 → JSC; last `0` is at bit 40 → payload
= bits 2..39. Nibbles: 7,8,11,8 (continuers) 5 (stopper) + sep 1 → j = ((1·9+4)·9+1) = 118,
k = 4, index = 118·7 + 5 + base[4]=5740 → 6571 → `HELLO` + space; then 7,11,9 then 4 + sep 0
→ j = (0·9+4)·9+2 = 38, k = 3, index = 38·7 + 4 + 637 = 907 → `WORLD`. Result `HELLO WORLD`.


### 11.4 Buffered directed command with checksum: `KN4CRD: W0CJW MSG HELLO`

1. Directed match: TO `W0CJW`, cmd ` MSG` (code 9, buffered, checksum16), consumed
   `W0CJW MSG` → frame `SN5-lVAGosa0` (i3 = First).
2. Remainder ` HELLO` → left-strip → `HELLO` → checksum16(`HELLO`) = CRC 0x1502 = 5378 →
   `387` → text `HELLO 387`.
3. Data packer (Normal): JSC tokens `HELLO`+sep (6571), `3` (41), `8` (45), `7` (47) →
   2 + 21 + 9 + 9 + 9 = 50 bits, 9 characters consumed → frame `tYuNRCDYd+++` (i3 = Last).

```
110111 100010 111000 010111 011011 001100 001101 100010 100111 111111 111111 111111
```

Receiver: frame 1 is directed, buffered (not Last) → buffer.cmd; frame 2 is data, Last →
buffer.msgs; completion: text `HELLO 387` → checksum `387` over `HELLO` valid → delivered and
shown as **`KN4CRD: W0CJW MSG HELLO ♢ `**.

### 11.5 Multi-frame free text (Normal submode, identification disabled)

`THE QUICK BROWN FOX JUMPS OVER THE LAZY DOG` splits into:

| # | Coding | Text consumed | Frame | i3 |
|---|---|---|---|---|

| 1 | JSC | `THE QUICK BROWN ` | `nE0ETvVbsl++` | 1 |
| 2 | JSC | `FOX JUMPS OVER TH` | `--KzLqTxbOd0` | 0 |
| 3 | JSC | `E LAZY DOG` | `mvjoEdWJ++++` | 2 |

Note the word `THE` is coded letter by letter (`T`,`H`,`E` — it is absent from the word
table) and frame 2 ends inside `THE` (`TH`), frame 3 starting with `E LAZY DOG`; the
receiver concatenates the three texts verbatim. Display: `THE QUICK BROWN FOX JUMPS OVER
THE LAZY DOG ♢ `.

### 11.6 Compound callsign frames

* `` `KN4CRD/P EM73 `` → Compound (type 001), callsign50 word `KN4 CRD/P  ` =
  358,399,795,420,712, num = 23,883, bits3 = 0 → **`AY-pe+BnGkfO`**. Display `KN4CRD/P: `,
  extra ` EM73`.
* `` `W0CJW SNR? `` → CompoundDirected (type 010), num = 32,410 + packCmd(0) = 32,410 →
  **`Jz95VAOyO+JG`**. Decoded as directed [`<....>`, `W0CJW`, ` SNR?`]; display `W0CJW SNR? `.
* `` `W0CJW SNR -05 `` → num = 32,410 + (0b1000_0000 | 26) = 32,564 → **`Jz95VAOyO+cW`**;
  decoded [`<....>`, `W0CJW`, ` SNR`, `-05`].

So the message `KN4CRD/P: W0CJW SNR?` is transmitted as the two frames `AY-pe+BnGkfO`
(i3 = First) then `Jz95VAOyO+JG` (i3 = Last); the receiver buffers the compound call, fills
FROM = `KN4CRD/P` (grid EM73) into the placeholder, and delivers `KN4CRD/P: W0CJW SNR? ♢ `.

---

## 12. Items that could not be pinned down / cautions

* **CRC-12 of the modem message (§1.1)**: transcribed from the encoder's description
  (augmented CRC-12, polynomial 0xC06, XOR 42, over an 11-byte buffer). It is a modem-layer
  fact; validate against a live decode before relying on it. All Varicode-layer facts do
  not depend on it.
* **Text encoding for checksums** uses the platform "local 8-bit" encoding; on macOS/Linux
  this is UTF-8, and the text is ASCII-escaped by then, so the choice cannot matter in
  practice. UNVERIFIED for exotic Windows code pages.
* **packGrid float truncation**: the integer formulation in §3.5 was checked exhaustively
  against both a double-precision and a single-precision (float32) emulation of the
  reference's floating-point computation for all 32,400 grids — no mismatches. It is
  listed here only because the reference relies on float truncation.
* **Fast-data/Huffman**: a compile-time switch would allow Huffman in fast-data frames with a
  1-bit header; it is *off* in the shipped build, so fast data is JSC-only with no header.
* **`\U` escaping** is applied in the UI layer; exactly which characters are escaped
  (everything ≥ U+0080, including the Latin-1 letters that JSC could carry natively) was
  read from the escape helper; whether every text entry path calls it was not audited.
* **Idle marker / EOT strings** are user-configurable (`♢`, `……` are the defaults); they are
  display conventions, not on-air data.
* **Receive-side offset tolerances** (10/16/32/10/50 Hz) and the 60 s / 90 s buffer ageing
  are implementation heuristics of the reference receiver rather than wire-format facts; a
  compatible receiver may tune them.
* The JSC word tables were sampled (first 200 / last 20 of `list`, whole `prefix`, first 120
  of `map`), and structural properties verified on the full files; a compatible
  implementation must still ship the complete 262,144-entry tables.


---

## Appendix A. JSC table excerpts for validation

Format: position: `"string"` size rank-index. Strings are Latin-1; `\n`, `\x1a`, `\\`
and `\"` denote newline, 0x1A, backslash and double-quote.

### A.1 `list` — first 200 entries (positions 0..199)

```
0: "~" 1 66
1: "}" 1 61
2: "|" 1 62
3: "{" 1 60
4: "`" 1 65
5: "_" 1 48
6: "^" 1 64
7: "]" 1 59
8: " " 1 67
9: "[" 1 58
10: "ZZZZ" 4 91474
11: "ZZZ" 3 70901
12: "ZZYY" 4 171515
13: "ZZYW" 4 183602
14: "ZZYT" 4 195566
15: "ZZYS" 4 133423
16: "ZZYP" 4 253527
17: "ZZYO" 4 172771
18: "ZZYL" 4 212405
19: "ZZYI" 4 129011
20: "ZZYH" 4 226963
21: "ZZYG" 4 198689
22: "ZZYF" 4 204648
23: "ZZYD" 4 206269
24: "ZZYC" 4 218635
25: "ZZYB" 4 188415
26: "ZZYA" 4 135438
27: "ZZY" 3 204198
28: "ZZWO" 4 125670
29: "ZZWI" 4 141529
30: "ZZWH" 4 197251
31: "ZZWE" 4 253872
32: "ZZWA" 4 180768
33: "ZZW" 3 205370
34: "ZZV" 3 50324
35: "ZZUT" 4 241579
36: "ZZUR" 4 199524
37: "ZZU" 3 31155
38: "ZZTR" 4 188554
39: "ZZTO" 4 144459
40: "ZZTH" 4 131310
41: "ZZT" 3 7286
42: "ZZST" 4 152201
43: "ZZSO" 4 209673
44: "ZZSI" 4 184603
45: "ZZSE" 4 249107
46: "ZZSC" 4 222846
47: "ZZSA" 4 168719
48: "ZZS" 3 6535
49: "ZZRO" 4 170163
50: "ZZRIL" 5 257997
51: "ZZRE" 4 179216
52: "ZZR" 3 142495
53: "ZZQ" 3 68030
54: "ZZPR" 4 245105
55: "ZZPI" 4 183372
56: "ZZP" 3 30118
57: "ZZOW" 4 159173
58: "ZZOV" 4 252822
59: "ZZOUNDS" 7 118475
60: "ZZOU" 4 142449
61: "ZZOT" 4 149578
62: "ZZOS" 4 108775
63: "ZZOR" 4 148895
64: "ZZOP" 4 189278
65: "ZZOO" 4 258885
66: "ZZON" 4 124188
67: "ZZOM" 4 260438
68: "ZZOL" 4 131547
69: "ZZOI" 4 175062
70: "ZZOH" 4 221929
71: "ZZOF" 4 149973
72: "ZZOD" 4 217699
73: "ZZOC" 4 195567
74: "ZZOB" 4 245106
75: "ZZOA" 4 139687
76: "ZZO" 3 2147
77: "ZZMU" 4 110740
78: "ZZMA" 4 167645
79: "ZZM" 3 8398
80: "ZZLY" 4 109073
81: "ZZLI" 4 58510
82: "ZZLE" 4 40970
83: "ZZLA" 4 244191
84: "ZZL" 3 1181
85: "ZZJ" 3 254362
86: "ZZIW" 4 160879
87: "ZZIT" 4 164560
88: "ZZIS" 4 101738
89: "ZZIPLIB" 7 229604
90: "ZZIO" 4 197568
91: "ZZIN" 4 66925
92: "ZZIM" 4 235769
93: "ZZIL" 4 249767
94: "ZZII" 4 184604
95: "ZZIH" 4 229975
96: "ZZIF" 4 226964
97: "ZZIE" 4 69128
98: "ZZIC" 4 159959
99: "ZZIA" 4 125104
100: "ZZI" 3 1563
101: "ZZHE" 4 261557
102: "ZZHA" 4 156233
103: "ZZH" 3 33488
104: "ZZGU" 4 207720
105: "ZZGR" 4 210477
106: "ZZGL" 4 172754
107: "ZZG" 3 35024
108: "ZZFU" 4 196769
109: "ZZFR" 4 251450
110: "ZZFO" 4 167996
111: "ZZFE" 4 114334
112: "ZZFA" 4 242435
113: "ZZF" 3 7070
114: "ZZET" 4 169989
115: "ZZES" 4 123803
116: "ZZER" 4 74005
117: "ZZEN" 4 148529
118: "ZZEL" 4 140523
119: "ZZE" 3 2560
120: "ZZD" 3 37628
121: "ZZCO" 4 124849
122: "ZZCL" 4 163411
123: "ZZCA" 4 214023
124: "ZZC" 3 8101
125: "ZZBU" 4 236072
126: "ZZBO" 4 261185
127: "ZZBE" 4 196290
128: "ZZBA" 4 100625
129: "ZZB" 3 6792
130: "ZZAW" 4 134177
131: "ZZAT" 4 108439
132: "ZZAS" 4 87280
133: "ZZAR" 4 55321
134: "ZZAO" 4 164887
135: "ZZAN" 4 69406
136: "ZZAM" 4 138576
137: "ZZAL" 4 130964
138: "ZZAK" 4 261937
139: "ZZAI" 4 127735
140: "ZZAH" 4 123100
141: "ZZAG" 4 200545
142: "ZZAF" 4 146764
143: "ZZAD" 4 136505
144: "ZZAC" 4 145673
145: "ZZAB" 4 127483
146: "ZZAA" 4 99625
147: "ZZ" 2 282
148: "ZYZE" 4 133638
149: "ZYZ" 3 241749
150: "ZYY" 3 55882
151: "ZYXEL" 5 75426
152: "ZYX" 3 116509
153: "ZYWO" 4 186269
154: "ZYWI" 4 142736
155: "ZYWH" 4 151529
156: "ZYWE" 4 228964
157: "ZYWALL" 6 178142
158: "ZYWA" 4 156110
159: "ZYW" 3 7308
160: "ZYVEX" 5 222367
161: "ZYV" 3 57002
162: "ZYUGANOV" 8 257960
163: "ZYU" 3 38846
164: "ZYTO" 4 107223
165: "ZYTH" 4 106596
166: "ZYTEL" 5 211854
167: "ZYTE" 4 254211
168: "ZYT" 3 5575
169: "ZYSZ" 4 221021
170: "ZYSU" 4 200546
171: "ZYST" 4 142559
172: "ZYSP" 4 218868
173: "ZYSO" 4 206426
174: "ZYSK" 4 183232
175: "ZYSI" 4 251140
176: "ZYSH" 4 199345
177: "ZYSE" 4 191919
178: "ZYSC" 4 243604
179: "ZYSA" 4 151030
180: "ZYS" 3 4372
181: "ZYRTEC" 6 64654
182: "ZYRI" 4 244192
183: "ZYRE" 4 163580
184: "ZYR" 3 31423
185: "ZYQ" 3 68154
186: "ZYPREXA" 7 82251
187: "ZYPR" 4 196921
188: "ZYPO" 4 210478
189: "ZYPE" 4 168882
190: "ZYPA" 4 224626
191: "ZYP" 3 9756
192: "ZYOU" 4 144764
193: "ZYOS" 4 227706
194: "ZYOR" 4 179870
195: "ZYON" 4 179326
196: "ZYOF" 4 164888
197: "ZYO" 3 7149
198: "ZYNS" 4 92441
199: "ZYNO" 4 222416
```

### A.2 `list` — last 20 entries (positions 262124..262143)

```
262124: "-" 1 24
262125: "," 1 20
262126: "+" 1 25
262127: "*" 1 55
262128: ")" 1 31
262129: "(" 1 32
262130: "'VE" 3 311
262131: "'T" 2 308
262132: "'S" 2 314
262133: "'RE" 3 310
262134: "'M" 2 313
262135: "'LL" 3 312
262136: "'D" 2 309
262137: "'" 1 29
262138: "&" 1 50
262139: "%" 1 52
262140: "$" 1 51
262141: "#" 1 53
262142: "\"" 1 26
262143: "!" 1 28
```

### A.3 `prefix` — all 103 entries (position: first-byte, count, start position in `list`)

```
0: "!" 1 262143
1: "\"" 1 262142
2: "#" 1 262141
3: "$" 1 262140
4: "%" 1 262139
5: "&" 1 262138
6: "'" 8 262130
7: "(" 1 262129
8: ")" 1 262128
9: "*" 1 262127
10: "+" 1 262126
11: "," 1 262125
12: "-" 16 262109
13: "." 3 262106
14: "/" 1 262105
15: "0" 1 262104
16: "1" 8 262096
17: "2" 3 262093
18: "3" 5 262088
19: "4" 3 262085
20: "5" 13 262072
21: "6" 3 262069
22: "7" 4 262065
23: "8" 4 262061
24: "9" 2 262059
25: ":" 8 262051
26: ";" 1 262050
27: "<" 2 262048
28: "=" 3 262045
29: ">" 1 262044
30: "?" 1 262043
31: "@" 1 262042
32: "A" 14867 247175
33: "B" 13306 233869
34: "C" 17608 216261
35: "D" 13749 202512
36: "E" 12403 190109
37: "\\" 1 180060
38: "\n" 1 180059
39: "F" 11252 178857
40: "G" 10672 168185
41: "H" 9060 159125
42: "I" 9503 149622
43: "\x1a" 1 145916
44: "J" 4262 145360
45: "K" 7986 137374
46: "L" 12241 125133
47: "M" 15859 109274
48: "N" 9214 100060
49: "O" 9506 90554
50: "P" 15720 74834
51: "Q" 2412 72422
52: "R" 14534 57888
53: "S" 19054 38834
54: "T" 10883 27951
55: "U" 7461 20490
56: "V" 4632 15858
57: "W" 7447 8411
58: "X" 1799 6612
59: "Y" 4348 2264
60: "Z" 2254 10
61: "[" 1 9
62: " " 1 8
63: "]" 1 7
64: "^" 1 6
65: "_" 1 5
66: "`" 1 4
67: "{" 1 3
68: "|" 1 2
69: "}" 1 1
70: "~" 1 0
71: "\xa1 (¡)" 1 239518
72: "\xbf (¿)" 1 239517
73: "\xc0 (À)" 1 239516
74: "\xc1 (Á)" 1 239515
75: "\xc2 (Â)" 1 239514
76: "\xc3 (Ã)" 1 239513
77: "\xc4 (Ä)" 1 239512
78: "\xc5 (Å)" 1 239511
79: "\xc6 (Æ)" 1 239510
80: "\xc7 (Ç)" 1 239509
81: "\xc8 (È)" 1 239508
82: "\xc9 (É)" 1 239507
83: "\xca (Ê)" 1 239506
84: "\xcb (Ë)" 1 239505
85: "\xcc (Ì)" 1 239504
86: "\xcd (Í)" 1 239503
87: "\xce (Î)" 1 239502
88: "\xcf (Ï)" 1 239501
89: "\xd0 (Ð)" 1 239500
90: "\xd1 (Ñ)" 1 239499
91: "\xd2 (Ò)" 1 239498
92: "\xd3 (Ó)" 1 239497
93: "\xd4 (Ô)" 1 239496
94: "\xd5 (Õ)" 1 239495
95: "\xd6 (Ö)" 1 239494
96: "\xd8 (Ø)" 1 239493
97: "\xd9 (Ù)" 1 239492
98: "\xda (Ú)" 1 239491
99: "\xdb (Û)" 1 239490
100: "\xdc (Ü)" 1 239489
101: "\xdd (Ý)" 1 239488
102: "\xde (Þ)" 1 239487
```

### A.4 `map` — first 120 entries (rank: string size)

```
0: "E" 1
1: "T" 1
2: "A" 1
3: "O" 1
4: "I" 1
5: "N" 1
6: "S" 1
7: "H" 1
8: "R" 1
9: "D" 1
10: "L" 1
11: "C" 1
12: "U" 1
13: "M" 1
14: "W" 1
15: "F" 1
16: "G" 1
17: "Y" 1
18: "P" 1
19: "B" 1
20: "," 1
21: "." 1
22: "V" 1
23: "K" 1
24: "-" 1
25: "+" 1
26: "\"" 1
27: "?" 1
28: "!" 1
29: "'" 1
30: "X" 1
31: ")" 1
32: "(" 1
33: "0" 1
34: "J" 1
35: "1" 1
36: "Q" 1
37: "=" 1
38: "2" 1
39: ":" 1
40: "Z" 1
41: "3" 1
42: "5" 1
43: "4" 1
44: "9" 1
45: "8" 1
46: "6" 1
47: "7" 1
48: "_" 1
49: "/" 1
50: "&" 1
51: "$" 1
52: "%" 1
53: "#" 1
54: "@" 1
55: "*" 1
56: ">" 1
57: "<" 1
58: "[" 1
59: "]" 1
60: "{" 1
61: "}" 1
62: "|" 1
63: ";" 1
64: "^" 1
65: "`" 1
66: "~" 1
67: " " 1
68: "\\" 1
69: "\n" 1
70: "JS8" 3
71: "JS8CALL" 7
72: "\x1a" 1
73: "JSQCALL" 7
74: "JORDAN" 6
75: "KN4CRD" 6
76: "599" 3
77: "559" 3
78: "589" 3
79: "579" 3
80: "569" 3
81: "@ALLCALL" 7
82: "BEACON" 6
83: "CQCQCQ" 6
84: "CPY?" 4
85: "QSL?" 4
86: "AGN?" 4
87: "AGN" 3
88: "ACK" 3
89: "ABT" 3
90: "ARES" 4
91: "APRS" 4
92: "ARL" 3
93: "ARRL" 4
94: "ANS" 3
95: "ANT" 3
96: "B4" 2
97: "BC" 2
98: "BCN" 3
99: "BCNU" 4
100: "BD" 2
101: "BK" 2
102: "BN" 2
103: "BEAM" 4
104: "BEN" 3
105: "BTU" 3
106: "BURO" 4
107: "CALLSIGN" 8
108: "CB" 2
109: "CBA" 3
110: "CFM" 3
111: "CL" 2
112: "CLDY" 4
113: "CLG" 3
114: "CLR" 3
115: "CONDX" 5
116: "CONGRATS" 8
117: "CONTEST" 7
118: "CPI" 3
119: "CPY" 3
```

### A.5 `map` — last 20 entries

```
262124: "ENVIROMENTS" 11
262125: "OIKONOMIAS" 10
262126: "CHILDNODES" 10
262127: "BASSLER" 7
262128: "SPEEDCOM" 8
262129: "MENSE" 5
262130: "CORALLO" 7
262131: "YILDIRIM" 8
262132: "HILTY" 5
262133: "CSID" 4
262134: "BLUECOAT" 8
262135: "BATCO" 5
262136: "MUSICSPACE" 10
262137: "DARKWATER" 9
262138: "TEMPLER" 7
262139: "NONBUILDING" 11
262140: "YANAI" 5
262141: "YOGIBEAR" 8
262142: "UWED" 4
262143: "ROSIDS" 1
```

### A.6 Selected ranks useful for tests

`E`=0 `T`=1 `A`=2 `O`=3 `I`=4 `N`=5 `S`=6 `H`=7 `R`=8 `D`=9 `L`=10 `C`=11 `U`=12 `M`=13
`W`=14 `F`=15 `G`=16 `Y`=17 `P`=18 `B`=19 `,`=20 `.`=21 `V`=22 `K`=23 `-`=24 `+`=25 `"`=26
`?`=27 `!`=28 `'`=29 `X`=30 `)`=31 `(`=32 `0`=33 `J`=34 `1`=35 `Q`=36 `=`=37 `2`=38 `:`=39
`Z`=40 `3`=41 `5`=42 `4`=43 `9`=44 `8`=45 `6`=46 `7`=47 `_`=48 `/`=49 `&`=50 `$`=51 `%`=52
`#`=53 `@`=54 `*`=55 `>`=56 `<`=57 `[`=58 `]`=59 `{`=60 `}`=61 `|`=62 `;`=63 `^`=64
`` ` ``=65 `~`=66 space=67 `\`=68 newline=69 `JS8`=70 `JS8CALL`=71 0x1A=72 `JSQCALL`=73
`JORDAN`=74 `KN4CRD`=75 `599`=76 `@ALLCALL`=81 (unreachable) `CQ`=121 `DE`=125 `MSG`=200
`SNR`=231 `TEST`=240 `QSL`=294 `QRZ`=302 `73`=351 `THIS`=600 `WORLD`=907 `QUICK`=3971
`HELLO`=6571 `HEARTBEAT`=49715.

