#!/bin/bash
# Download JS8Call's decoder test recordings (media/tests in the JS8Call
# repository) for JS8CodecTests.testJS8CallFixtureRecordings. They are
# recordings, not code, but they live in a GPL repository so they are not
# vendored here. Usage:
#
#     Scripts/fetch_js8_fixtures.sh            # into ~/Library/Caches/Squelch/js8-fixtures
#     JS8_FIXTURES=~/Library/Caches/Squelch/js8-fixtures swift test --filter JS8CodecTests
set -euo pipefail
DIR="${1:-$HOME/Library/Caches/Squelch/js8-fixtures}"
BASE="https://raw.githubusercontent.com/JS8Call-improved/JS8Call-improved/HEAD/media/tests"
mkdir -p "$DIR"
for f in A_1_4 A_2_1 A_2_3 A_2_5 A_2_6 A_2_9 A_3_3 E_1_1 E_2_1; do
    [ -s "$DIR/$f.wav" ] || curl -sfL -o "$DIR/$f.wav" "$BASE/$f.wav"
done
ls -l "$DIR"
echo "export JS8_FIXTURES=$DIR"
