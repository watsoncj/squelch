#!/bin/bash
# Fetch the JS8 word table (JSC_map.cpp from the JS8Call-improved repository)
# into Squelch's Application Support directory. Squelch converts it to its
# compact js8-words.txt on first use. The table is JS8Call data (GPLv3 as
# part of that project) and is deliberately not vendored in this repo.
#
#     Scripts/fetch_js8_dictionary.sh
set -euo pipefail
DIR="${1:-$HOME/Library/Application Support/Squelch}"
URL="https://raw.githubusercontent.com/JS8Call-improved/JS8Call-improved/HEAD/JS8_JSC/JSC_map.cpp"
mkdir -p "$DIR"
echo "Downloading JSC_map.cpp (~7 MB)…"
curl -fL --progress-bar -o "$DIR/JSC_map.cpp" "$URL"
rm -f "$DIR/js8-words.txt"
ls -l "$DIR/JSC_map.cpp"
echo "Installed. Squelch will convert it the first time JS8 text is decoded."
