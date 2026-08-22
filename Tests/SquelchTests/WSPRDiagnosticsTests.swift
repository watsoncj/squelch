import XCTest
@testable import Squelch

/// The "signals heard, none decode" warning: strong sync structure slot
/// after slot with zero spots means something upstream (radio DSP) is
/// mangling the audio.
final class WSPRDiagnosticsTests: XCTestCase {
    func testSuspectAfterThreeStrongUndecodedSlots() {
        let c = DecodeController()
        c.noteWSPRSlot(spotCount: 0, strongestSync: 2.1)
        c.noteWSPRSlot(spotCount: 0, strongestSync: 1.9)
        XCTAssertFalse(c.wsprAudioSuspect, "two slots isn't a pattern yet")
        c.noteWSPRSlot(spotCount: 0, strongestSync: 2.4)
        XCTAssertTrue(c.wsprAudioSuspect)
    }

    func testAnyDecodeClearsTheWarning() {
        let c = DecodeController()
        for _ in 0..<4 {
            c.noteWSPRSlot(spotCount: 0, strongestSync: 2.0)
        }
        XCTAssertTrue(c.wsprAudioSuspect)
        c.noteWSPRSlot(spotCount: 1, strongestSync: 2.0)
        XCTAssertFalse(c.wsprAudioSuspect)
    }

    func testNarrowFilterDetectedFromClusteredDecodes() {
        let c = DecodeController()
        // 60 decodes all inside 750–1250 Hz — today's FT-891 WIDTH incident
        c.noteDecodedFrequencies((0..<60).map { 750 + Float($0 % 50) * 10 })
        XCTAssertNotNil(c.narrowFilterSpan)
        if let span = c.narrowFilterSpan {
            XCTAssertLessThan(span.hi - span.lo, 900)
        }
        // The band opens up — decodes spread out, warning clears
        c.noteDecodedFrequencies((0..<120).map { 300 + Float($0 % 60) * 40 })
        XCTAssertNil(c.narrowFilterSpan)
    }

    func testFewDecodesNeverTriggerFilterWarning() {
        let c = DecodeController()
        c.noteDecodedFrequencies((0..<20).map { _ in Float(1000) })
        XCTAssertNil(c.narrowFilterSpan, "a handful of decodes isn't evidence")
    }

    func testWeakSyncNeverTriggers() {
        let c = DecodeController()
        for _ in 0..<10 {
            c.noteWSPRSlot(spotCount: 0, strongestSync: 1.3) // noise-level candidates
        }
        XCTAssertFalse(c.wsprAudioSuspect, "a quiet band is not mangled audio")
    }
}

/// The wrong-input warning: capture quietly landing on the built-in mic
/// after a Digirig replug (a USB port move changes the device UID, so
/// an exact-UID lookup finds nothing).
final class InputMismatchTests: XCTestCase {
    private let mic = AudioDevice(id: 51, uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone")
    private let digirig = AudioDevice(id: 72, uid: "AppleUSBAudioEngine:C-Media Electronics Inc.:USB PnP Sound Device:14100000:1", name: "USB PnP Sound Device")
    /// Same hardware after a USB port move: new location ID, new HAL ID.
    private let movedDigirig = AudioDevice(id: 90, uid: "AppleUSBAudioEngine:C-Media Electronics Inc.:USB PnP Sound Device:14300000:1", name: "USB PnP Sound Device")

    func testBoundToMicMismatches() {
        let mismatch = DecodeController.inputMismatch(
            boundID: mic.id, attachedInputs: [mic], defaultInput: mic,
            wantedUID: digirig.uid, wantedName: digirig.name, audioFlowing: true)
        XCTAssertEqual(mismatch?.actualName, "MacBook Pro Microphone")
        XCTAssertEqual(mismatch?.wantedName, "USB PnP Sound Device")
    }

    /// Field false positive (2026-08-22): the stored UID was stale, Start
    /// fell back to the default input — which WAS the Digirig under its
    /// new-port UID. Decoding worked; the chip must stay quiet.
    func testSameHardwareUnderNewPortUIDIsClean() {
        XCTAssertNil(DecodeController.inputMismatch(
            boundID: movedDigirig.id, attachedInputs: [mic, movedDigirig], defaultInput: movedDigirig,
            wantedUID: digirig.uid, wantedName: nil, audioFlowing: true))
    }

    /// Field false negative (2026-08-22): after the port move the engine's
    /// device property still reports the vanished ID, while the HAL feeds
    /// the decoder the default mic. Audio flowing + binding resolving to
    /// nothing attached = warn, naming the default input.
    func testStaleBindingWithAudioFlowingWarns() {
        let mismatch = DecodeController.inputMismatch(
            boundID: digirig.id, attachedInputs: [mic, movedDigirig], defaultInput: mic,
            wantedUID: digirig.uid, wantedName: digirig.name, audioFlowing: true)
        XCTAssertEqual(mismatch?.actualName, "MacBook Pro Microphone")
    }

    func testStaleBindingWithoutAudioIsTheSilentChipsJob() {
        XCTAssertNil(DecodeController.inputMismatch(
            boundID: digirig.id, attachedInputs: [mic], defaultInput: mic,
            wantedUID: digirig.uid, wantedName: digirig.name, audioFlowing: false))
    }

    func testMatchingBindingIsClean() {
        XCTAssertNil(DecodeController.inputMismatch(
            boundID: digirig.id, attachedInputs: [mic, digirig], defaultInput: mic,
            wantedUID: digirig.uid, wantedName: digirig.name, audioFlowing: true))
    }

    func testDefaultInputByChoiceNeverWarns() {
        XCTAssertNil(DecodeController.inputMismatch(
            boundID: mic.id, attachedInputs: [mic], defaultInput: mic,
            wantedUID: "", wantedName: nil, audioFlowing: true),
            "no stored device means the default input is intentional")
    }

    func testPortMoveHealsAtStart() {
        let resolved = AudioDevices.resolveInput(storedUID: digirig.uid, inputs: [mic, movedDigirig])
        XCTAssertEqual(resolved?.device.id, movedDigirig.id)
        XCTAssertEqual(resolved?.healed, true)
    }

    func testExactUIDResolvesWithoutHealing() {
        let resolved = AudioDevices.resolveInput(storedUID: digirig.uid, inputs: [mic, digirig])
        XCTAssertEqual(resolved?.device.id, digirig.id)
        XCTAssertEqual(resolved?.healed, false)
    }

    func testUnpluggedDigirigResolvesToNothing() {
        XCTAssertNil(AudioDevices.resolveInput(storedUID: digirig.uid, inputs: [mic]),
                     "the mic must never be silently adopted as the radio input")
    }

    // FT-991: split-duplex PCM2903 — input and output are separate
    // CoreAudio devices whose UIDs differ only in the engine index, which
    // normalizedUID strips. Safe here because these paths only ever look
    // at INPUT devices, where the output sibling cannot appear.
    private let ft991In = AudioDevice(
        id: 40,
        uid: "AppleUSBAudioEngine:Burr-Brown from TI:USB Audio CODEC:14200000:2",
        name: "USB Audio CODEC"
    )
    private let movedFT991In = AudioDevice(
        id: 95,
        uid: "AppleUSBAudioEngine:Burr-Brown from TI:USB Audio CODEC:14600000:2",
        name: "USB Audio CODEC"
    )

    func testFT991PortMoveHealsAtStart() {
        let resolved = AudioDevices.resolveInput(storedUID: ft991In.uid, inputs: [mic, movedFT991In])
        XCTAssertEqual(resolved?.device.id, movedFT991In.id)
        XCTAssertEqual(resolved?.healed, true)
    }

    func testFT991UnderNewPortUIDIsClean() {
        XCTAssertNil(DecodeController.inputMismatch(
            boundID: movedFT991In.id, attachedInputs: [mic, movedFT991In], defaultInput: movedFT991In,
            wantedUID: ft991In.uid, wantedName: nil, audioFlowing: true))
    }

    func testFT991FallbackToMicWarns() {
        let mismatch = DecodeController.inputMismatch(
            boundID: mic.id, attachedInputs: [mic], defaultInput: mic,
            wantedUID: ft991In.uid, wantedName: ft991In.name, audioFlowing: true)
        XCTAssertEqual(mismatch?.actualName, "MacBook Pro Microphone")
        XCTAssertEqual(mismatch?.wantedName, "USB Audio CODEC")
    }

    /// Dead capture (engine died after the device vanished): the slot
    /// timer keeps firing with zero samples, which must raise the silent
    /// chip — `append`-based level detection never runs again.
    func testTwoEmptySlotsRaiseSilence() {
        let c = DecodeController()
        c.noteSlotFill(empty: true)
        XCTAssertFalse(c.inputSilent, "one empty slot can happen right after Start")
        c.noteSlotFill(empty: true)
        XCTAssertTrue(c.inputSilent)
    }

    func testAudioResumingResetsTheStreak() {
        let c = DecodeController()
        c.noteSlotFill(empty: true)
        c.noteSlotFill(empty: false)
        c.noteSlotFill(empty: true)
        XCTAssertFalse(c.inputSilent, "the streak must restart after a full slot")
    }
}
