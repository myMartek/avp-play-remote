#!/bin/sh
# Holt die gemeinsame Protokolldatei aus einem AVP-Play-Checkout – oder prüft mit --check, dass beide gleich sind.
# Die Datei gehört AVP Play (core/Sources/AVPPlayCore/RemoteProtocol.swift); hier liegt nur eine Kopie.
#
#   tools/sync-protocol.sh <avp-play-checkout>          # kopieren
#   tools/sync-protocol.sh --check <avp-play-checkout>  # nur vergleichen
set -eu
check=0
if [ "${1:-}" = "--check" ]; then check=1; shift; fi
src="${1:?Pfad zum AVP-Play-Checkout fehlt}/core/Sources/AVPPlayCore/RemoteProtocol.swift"
dst="$(dirname "$0")/../Sources/Shared/RemoteProtocol.swift"
[ -f "$src" ] || { echo "nicht gefunden: $src" >&2; exit 2; }
if [ $check = 1 ]; then
  cmp -s "$src" "$dst" && echo "gleich" || { echo "verschieden – tools/sync-protocol.sh $1 gleicht an" >&2; exit 1; }
else
  cp "$src" "$dst" && echo "kopiert"
fi
