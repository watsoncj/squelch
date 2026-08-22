import XCTest

/// Tests that push a full 120 s WSPR slot through the decoder take minutes
/// each in a debug build, which makes a plain `swift test` painful. Gate
/// them behind SQUELCH_SLOW=1 (same idiom as WSPR_SWEEP/WSPR_SLOT_RAW):
///
///     SQUELCH_SLOW=1 swift test -c release
///
/// runs everything at a usable speed. Run this before shipping a build
/// that touched the decoders.
func skipUnlessSlowTests() throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["SQUELCH_SLOW"] == "1",
                      "full-slot decode — run with SQUELCH_SLOW=1 swift test -c release")
}
