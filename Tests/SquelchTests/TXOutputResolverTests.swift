import XCTest
@testable import Squelch

/// UID-healing for the TX output device: USB port moves change macOS
/// device UIDs, and split-duplex codecs (FT-991's PCM2903) enumerate
/// input and output as separate devices with different UIDs.
final class TXOutputResolverTests: XCTestCase {
    // Digirig CM108: one duplex device, input and output share the UID
    private let digirig = AudioDevice(
        id: 50,
        uid: "AppleUSBAudioEngine:C-Media Electronics Inc.:USB Audio Device:14100000:1",
        name: "USB Audio Device"
    )
    // FT-991 codec: split duplex, sibling devices with different UIDs
    private let ft991In = AudioDevice(
        id: 60,
        uid: "AppleUSBAudioEngine:Burr-Brown from TI:USB Audio CODEC:14200000:2",
        name: "USB Audio CODEC"
    )
    private let ft991Out = AudioDevice(
        id: 61,
        uid: "AppleUSBAudioEngine:Burr-Brown from TI:USB Audio CODEC:14200000:1",
        name: "USB Audio CODEC"
    )
    private let macSpeakers = AudioDevice(
        id: 70, uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers"
    )

    // MARK: - normalizedUID

    func testNormalizedUIDStripsLocationAndEngineIndex() {
        XCTAssertEqual(
            AudioDevices.normalizedUID(digirig.uid),
            "appleusbaudioengine:c-media electronics inc.:usb audio device"
        )
        // Same device on a different USB port normalizes identically
        let moved = "AppleUSBAudioEngine:C-Media Electronics Inc.:USB Audio Device:14400000:1"
        XCTAssertEqual(AudioDevices.normalizedUID(moved), AudioDevices.normalizedUID(digirig.uid))
        // A split-duplex pair normalizes to the same identity
        XCTAssertEqual(AudioDevices.normalizedUID(ft991In.uid), AudioDevices.normalizedUID(ft991Out.uid))
        // Non-numeric segments survive
        XCTAssertEqual(AudioDevices.normalizedUID("BuiltInSpeakerDevice"), "builtinspeakerdevice")
    }

    // MARK: - Explicit output UID

    func testExactExplicitMatchIsNotHealed() {
        let result = AudioDevices.resolveTXOutput(
            storedOutputUID: digirig.uid, storedInputUID: "",
            outputs: [macSpeakers, digirig], inputs: []
        )
        XCTAssertEqual(result, TXOutputResolution(device: digirig, healed: false))
    }

    func testStaleLocationIDHealsToMovedDevice() {
        let stale = "AppleUSBAudioEngine:C-Media Electronics Inc.:USB Audio Device:14620000:1"
        let result = AudioDevices.resolveTXOutput(
            storedOutputUID: stale, storedInputUID: "",
            outputs: [macSpeakers, digirig], inputs: []
        )
        XCTAssertEqual(result, TXOutputResolution(device: digirig, healed: true))
    }

    func testNormalizedMatchWinsOverHeuristic() {
        // Both the moved FT-991 codec and a Digirig are present: the stored
        // identity should win over the "looks like a Digirig" guess
        let stale = "AppleUSBAudioEngine:Burr-Brown from TI:USB Audio CODEC:11111111:1"
        let result = AudioDevices.resolveTXOutput(
            storedOutputUID: stale, storedInputUID: "",
            outputs: [digirig, ft991Out], inputs: []
        )
        XCTAssertEqual(result, TXOutputResolution(device: ft991Out, healed: true))
    }

    func testUnrecognizedStaleUIDFallsBackToHeuristic() {
        let stale = "AppleUSBAudioEngine:Long Gone Corp:Old Interface:11111111:1"
        let result = AudioDevices.resolveTXOutput(
            storedOutputUID: stale, storedInputUID: "",
            outputs: [macSpeakers, ft991Out], inputs: []
        )
        XCTAssertEqual(result, TXOutputResolution(device: ft991Out, healed: true))
    }

    // MARK: - RX-input fallback (no explicit output set)

    func testDuplexInputUIDMatchesOutputDirectly() {
        let result = AudioDevices.resolveTXOutput(
            storedOutputUID: "", storedInputUID: digirig.uid,
            outputs: [macSpeakers, digirig], inputs: [digirig]
        )
        XCTAssertEqual(result, TXOutputResolution(device: digirig, healed: false))
    }

    func testSplitDuplexInputResolvesToOutputSiblingByName() {
        let result = AudioDevices.resolveTXOutput(
            storedOutputUID: "", storedInputUID: ft991In.uid,
            outputs: [macSpeakers, ft991Out], inputs: [ft991In]
        )
        XCTAssertEqual(result, TXOutputResolution(device: ft991Out, healed: true))
    }

    func testSplitDuplexInputResolvesViaNormalizedUIDWhenInputMoved() {
        // Stored input UID is from the old USB port, so it's absent from the
        // current input list too — the identity match still finds the output
        let staleInput = "AppleUSBAudioEngine:Burr-Brown from TI:USB Audio CODEC:14620000:2"
        let result = AudioDevices.resolveTXOutput(
            storedOutputUID: "", storedInputUID: staleInput,
            outputs: [macSpeakers, ft991Out], inputs: [ft991In]
        )
        XCTAssertEqual(result, TXOutputResolution(device: ft991Out, healed: true))
    }

    func testNothingStoredUsesHeuristic() {
        let result = AudioDevices.resolveTXOutput(
            storedOutputUID: "", storedInputUID: "",
            outputs: [macSpeakers, ft991Out], inputs: []
        )
        XCTAssertEqual(result, TXOutputResolution(device: ft991Out, healed: true))
    }

    // MARK: - Fail-safe: never fall through to Mac speakers

    func testGenuinelyAbsentDeviceReturnsNil() {
        XCTAssertNil(AudioDevices.resolveTXOutput(
            storedOutputUID: digirig.uid, storedInputUID: "",
            outputs: [macSpeakers], inputs: []
        ))
        XCTAssertNil(AudioDevices.resolveTXOutput(
            storedOutputUID: "", storedInputUID: ft991In.uid,
            outputs: [macSpeakers], inputs: []
        ))
        XCTAssertNil(AudioDevices.resolveTXOutput(
            storedOutputUID: "", storedInputUID: "",
            outputs: [macSpeakers], inputs: []
        ))
    }
}
