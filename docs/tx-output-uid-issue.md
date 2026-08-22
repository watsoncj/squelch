# TX blocked: stale/mismatched TX audio output UID — fallback path never works on FT-991 built-in codec

## Summary

User on an FT-991 (built-in USB Audio CODEC, no Digirig) hit the toast:

> TX blocked: the selected TX audio output device was no…

Thrown as `AudioCaptureError.outputDeviceUnavailable` from `AudioOutput.prepareUnit()` (`Sources/Squelch/Transmit/AudioOutput.swift:98`) when the resolved output UID matches nothing in `AudioDevices.outputDevices()`.

## Root causes (two related bugs)

### 1. Stale UID after a USB topology change, and it never self-heals

macOS USB audio device UIDs embed the USB location ID (e.g. `AppleUSBAudioEngine:…:14200000:2`). Plugging the radio/interface into a different port or hub changes the UID, so the persisted `audioOutputUID` no longer matches any enumerated device.

The auto-select in `SettingsView.onAppear` (`Sources/Squelch/Views/SettingsView.swift:295`) only runs when `audioOutputUID.isEmpty`:

```swift
if audioOutputUID.isEmpty, let digirig = AudioDevices.likelyDigirig(in: outputDevices) {
    audioOutputUID = digirig.uid
}
```

Once a UID goes stale it stays stale forever — TX fails every session until the user manually re-picks the device.

### 2. The input-UID fallback is structurally broken for the FT-991

`TransmitController.outputDeviceUID` (`Sources/Squelch/Transmit/TransmitController.swift:219`) falls back to the RX **input** UID:

```swift
private var outputDeviceUID: String {
    let explicit = UserDefaults.standard.string(forKey: SettingsKeys.audioOutputUID) ?? ""
    if !explicit.isEmpty { return explicit }
    return UserDefaults.standard.string(forKey: SettingsKeys.audioDeviceUID) ?? ""
}
```

This works on a Digirig because the CM108 enumerates as one duplex CoreAudio device (input and output share a UID). The FT-991's Burr-Brown PCM2903 enumerates as **two separate CoreAudio devices** — "USB Audio CODEC" input and "USB Audio CODEC" output — with **different UIDs**. The input UID never appears in `outputDevices()`, so on the FT-991 the fallback path always throws `outputDeviceUnavailable`.

## Repro

1. FT-991 connected via USB (built-in codec), or any rig whose codec enumerates input/output as separate devices.
2. Leave Settings → Transmit → Audio output unset (or set it, then move the USB cable to a different port).
3. Attempt any TX (Reply / CQ / WSPR beacon).
4. Toast: "TX blocked: the selected TX audio output device was not found — check Settings → Transmit."

## Proposed fix

In the UID-resolution path (either `TransmitController.outputDeviceUID` or `AudioOutput.prepareUnit` before throwing), add a healing cascade when the exact UID isn't found:

1. **Name match with location ID stripped**: compare the persisted UID's device-name portion against current `outputDevices()` UIDs/names, ignoring the `:<locationID>` segments — recovers from USB port changes.
2. **Heuristic fallback**: `AudioDevices.likelyDigirig(in: AudioDevices.outputDevices())` — the existing keyword list (`"usb audio"` etc., `Sources/Squelch/Audio/AudioDevices.swift:47`) already matches the FT-991's "USB Audio CODEC".
3. **Write the recovered UID back** to `SettingsKeys.audioOutputUID` so it self-repairs, and surface a non-blocking toast like "TX output re-selected: USB Audio CODEC".
4. Only throw `outputDeviceUnavailable` if all of the above fail.

Also fix the input-UID fallback in `outputDeviceUID`: if the RX input UID isn't present in `outputDevices()`, resolve the input device's **name** and pick the output device with the matching name (handles split-duplex codecs like the PCM2903), rather than returning a UID that can't succeed.

### Secondary hardening

- `SettingsView.onAppear`: re-run auto-select not just when empty, but when the stored UID doesn't match any current output device.
- The Settings picker should visibly flag a stale selection (currently a stale UID likely renders as no selection with no explanation).

## Acceptance criteria

- [ ] FT-991 (split-duplex codec) with no explicit TX output set: TX audio routes to the codec's output device, no error.
- [ ] Moving the interface to a different USB port: next TX self-heals, updates the stored UID, and notifies the user.
- [ ] Genuinely absent device (unplugged): still fails safely with the existing toast — never falls through to system default (preserve the "TX audio can't end up on the Mac speakers" guarantee in the `outputDeviceUID` doc comment).
- [ ] Unit tests for the UID-healing logic (location-ID stripping, name matching, split-duplex input→output resolution).
