#!/bin/bash
# Baut tools/headset-check: die Kerne für „Auf dieser Brille“ als Kommando für den Mac, aus denselben Quellen wie
# die App (Standalone/Engine, der Signierer aus Standalone/Signer). Damit lässt sich am Mac prüfen, was sonst nur
# auf der Brille läuft: aus Vorlage und Spielteilen die App eines auf dem Mac gebauten Spiels zusammensetzen,
# signieren und packen – und messen, wie lange das dauert und wie viel Speicher es braucht.
#
#   tools/headset-check/build.sh [Ausgabeordner]      (ohne Angabe: build/headset-check)
#
# Braucht Xcode und Rust. Nichts davon geht in die App; der Signierer wird hier für den Mac gebaut, nicht für die
# Brille (tools/build-engine.sh).
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="${1:-build/headset-check}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
( cd Standalone/Signer && CARGO_TARGET_DIR="$OUT/signer" cargo build --release --quiet --lib )
swiftc -O -I Standalone/Vendor/include/Signer \
    Standalone/Engine/Zip.swift Standalone/Engine/FinishCommon.swift Standalone/Engine/FinishMacho.swift \
    Standalone/Engine/SignCore.swift Standalone/Engine/AppleAPI.swift Standalone/Shared/Hashing.swift \
    Standalone/App/BuiltGames.swift tools/headset-check/shim.swift tools/headset-check/checks.swift tools/headset-check/main.swift \
    "$OUT/signer/release/libprobe_sign.a" -lbz2 -liconv -framework Security -framework CoreFoundation -framework SystemConfiguration \
    -o "$OUT/headset-check"
echo "$OUT/headset-check"
