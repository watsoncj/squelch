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
