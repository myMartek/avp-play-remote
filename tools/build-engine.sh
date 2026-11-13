#!/bin/bash
# Baut die Bibliotheken für „Auf dieser Brille“ (project-standalone.yml) nach Standalone/Vendor/lib/xros. Sie sind
# nicht eingecheckt.
#
#   tools/build-engine.sh                       die Geräte-Bibliothek und den Signierer
#   tools/build-engine.sh translator <Ordner>   den Übersetzer aus einer Klepton-Toolchain
#   tools/build-engine.sh package               packt Geräte-Bibliothek und Signierer als Datei für ein Release
#
# Geräte-Bibliothek und Signierer hängen an keiner Toolchain: Sie werden einmal je Fassung der App gebaut und
# hängen am Release (AVP Play lädt sie von dort und prüft sie gegen Standalone/Vendor/libs.json). Der Übersetzer
# gehört zu genau einer Toolchain – was er übersetzt, lädt nur die Laufzeit derselben Toolchain –, deshalb baut ihn
# AVP Play auf dem Mac des Nutzers aus der Toolchain, die dort installiert ist.
#
# Braucht Xcode und Rust mit dem Ziel aarch64-apple-ios (rustup target add aarch64-apple-ios). Rust hat für
# visionOS kein fertiges Ziel; gebaut wird für iOS, und tools/retag-platform.py setzt die Plattform der Objekte um.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=Standalone/Vendor/lib/xros
WORK=build/deps

# Was hier entsteht, wird veröffentlicht: Die Pfade dieses Macs (Rusts Paketordner, dieser Ordner) stehen sonst in
# Fehlermeldungen und Debug-Angaben der Bibliotheken. `package` prüft, dass keiner geblieben ist.
export RUSTFLAGS="--remap-path-prefix=$HOME=/build --remap-path-prefix=$PWD=/src"
export CFLAGS_aarch64_apple_ios="-ffile-prefix-map=$HOME=/build -ffile-prefix-map=$PWD=/src"

# Die Geräte-Bibliothek: github.com/jkcoxson/idevice (MIT), auf einen Stand festgelegt. Nur die Teile, die die App
# braucht: Dateidienst, Datenordner anderer Apps, Installationsdienst, der Tunnel zu den Diensten und das Koppeln.
IDEVICE_REPO=https://github.com/jkcoxson/idevice.git
IDEVICE_COMMIT=89702099f4d7552f704f93b4526756abda319ceb
IDEVICE_FEATURES=ring,afc,house_arrest,installation_proxy,rsd,remote_pairing,tunnel_tcp_stack

device() {
    mkdir -p "$WORK" "$OUT"
    [ -d "$WORK/idevice/.git" ] || git clone --quiet "$IDEVICE_REPO" "$WORK/idevice"
    git -C "$WORK/idevice" fetch --quiet origin
    git -C "$WORK/idevice" checkout --quiet --detach "$IDEVICE_COMMIT"
    ( cd "$WORK/idevice/ffi" && IPHONEOS_DEPLOYMENT_TARGET=17.0 cargo build --release --quiet --lib --target aarch64-apple-ios \
        --no-default-features --features "$IDEVICE_FEATURES" )
    python3 tools/retag-platform.py "$WORK/idevice/target/aarch64-apple-ios/release/libidevice_ffi.a" "$OUT/libidevice_ffi.a" xros
    # Die Kopfdatei, die der Bau erzeugt, gehört zu genau diesem Stand.
    cp "$WORK/idevice/ffi/idevice.h" Standalone/Vendor/include/idevice/idevice.h
}

# Der Signierer (Standalone/Signer, auf apple-codesign): wie die Geräte-Bibliothek Rust, und beide bringen Rusts
# Laufzeit mit. Zwei Kopien davon stoßen beim Linken an, deshalb wird der Signierer ein einziges Objekt, das nur
# seine zwei Funktionen zeigt.
signer() {
    mkdir -p "$WORK" "$OUT"
    ( cd Standalone/Signer && IPHONEOS_DEPLOYMENT_TARGET=17.0 cargo build --release --quiet --lib --target aarch64-apple-ios )
    python3 tools/retag-platform.py Standalone/Signer/target/aarch64-apple-ios/release/libprobe_sign.a "$WORK/libprobe_sign.a" xros
    # -S: keine Debug-Angaben, sonst stünde der Pfad der Bibliothek je Objekt darin.
    xcrun --sdk xros ld -r -S -arch arm64 -platform_version xros 2.0 "$(xcrun --sdk xros --show-sdk-version)" -all_load \
        "$WORK/libprobe_sign.a" -exported_symbol _probe_sign_new_key -exported_symbol _probe_sign_app -o "$OUT/probe_sign.o"
    echo "$OUT/probe_sign.o"
}

# Der Übersetzer: Kleptons tools/klepton_ld.c als Bibliothek, mit umbenanntem main und exit, damit
# Standalone/Translator/klepton_ld_run.c ihn aufrufen kann und ein Aufgeben übersteht.
translator() {
    local klepton="${1:?Ordner der Klepton-Toolchain fehlt}" objects=() source object
    [ -f "$klepton/tools/klepton_ld.c" ] || { echo "kein Klepton-Ordner: $klepton" >&2; exit 1; }
    mkdir -p "$WORK/translator" "$OUT"
    for source in "$klepton/tools/klepton_ld.c" "$klepton/runtime/kl_x18.c" "$klepton/runtime/kl_env.c" \
                  "$klepton/runtime/guest/kl_guestpatch.c" Standalone/Translator/klepton_ld_run.c; do
        object="$WORK/translator/$(basename "${source%.c}").o"
        if [ "$source" = Standalone/Translator/klepton_ld_run.c ]; then
            xcrun --sdk xros clang -target arm64-apple-xros2.0 -O1 -IStandalone/Vendor/include/KleptonLD -c "$source" -o "$object"
        else
            xcrun --sdk xros clang -target arm64-apple-xros2.0 -O1 -w -I"$klepton/runtime" -I"$klepton/runtime/jni" \
                -I"$klepton/runtime/libc" -I"$klepton/runtime/gfx" -I"$klepton/runtime/xr" -I"$klepton/runtime/guest" \
                -Dmain=klepton_ld_main -Dexit=klepton_ld_exit -c "$source" -o "$object"
        fi
        objects+=("$object")
    done
    xcrun --sdk xros libtool -static -o "$OUT/libkleptonld.a" "${objects[@]}"
    echo "$OUT/libkleptonld.a"
}

# Geräte-Bibliothek und Signierer als eine Datei, und ihre Prüfsumme dorthin, wo AVP Play sie nachschlägt.
package() {
    local version archive sum
    version="$(sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([0-9.]*\)"\{0,1\} *$/\1/p' project.yml | head -1)"
    [ -n "$version" ] || { echo "MARKETING_VERSION nicht gefunden" >&2; exit 1; }
    for file in libidevice_ffi.a probe_sign.o; do
        [ -f "$OUT/$file" ] || { echo "$OUT/$file fehlt: zuerst tools/build-engine.sh" >&2; exit 1; }
        # Keine Pfade dieses Macs in dem, was veröffentlicht wird.
        if LC_ALL=C grep -a -q "/Users/" "$OUT/$file"; then echo "$OUT/$file nennt Pfade dieses Macs" >&2; exit 1; fi
    done
    archive="build/avp-play-remote-headset-libs-$version.zip"
    mkdir -p build
    rm -f "$archive"
    ( cd "$OUT" && zip -q -X "../../../../$archive" libidevice_ffi.a probe_sign.o )
    sum="$(shasum -a 256 "$archive" | cut -d' ' -f1)"
    printf '{\n  "asset": "%s",\n  "sha256": "%s",\n  "idevice": "%s"\n}\n' "$(basename "$archive")" "$sum" "$IDEVICE_COMMIT" \
        > Standalone/Vendor/libs.json
    echo "$archive ($(stat -f %z "$archive") Bytes), Prüfsumme in Standalone/Vendor/libs.json"
}

case "${1:-libs}" in
    libs) device; signer ;;
    device) device ;;
    signer) signer ;;
    translator) translator "${2:-}" ;;
    package) package ;;
    *) echo "unbekannt: $1 (libs, device, signer, translator <Ordner>, package)" >&2; exit 1 ;;
esac
