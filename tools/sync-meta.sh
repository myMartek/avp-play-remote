#!/bin/bash
# Diese Dateien unter Standalone/Shared gehören AVP Play (core/Sources/AVPPlayCore) und werden hier unverändert
# geführt, wie Sources/Shared/RemoteProtocol.swift: Alle Abfragen an Meta und an die Seiten des Stores stehen an
# einer Stelle, mit den Regeln, unter denen sie gestellt werden; und was ein Rezept ist, welche seiner Dateien
# gebraucht werden und wohin sie auf dem Gerät gehören, entscheidet derselbe Code wie am Mac.
#   tools/sync-meta.sh <Ordner von AVP Play>           kopiert die Dateien her
#   tools/sync-meta.sh --check <Ordner von AVP Play>   prüft nur, ob sie gleich sind
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK=0
if [ "${1:-}" = "--check" ]; then CHECK=1; shift; fi
ROOT="${1:?Ordner von AVP Play fehlt}/core/Sources/AVPPlayCore"
STATUS=0
for NAME in MetaClient.swift StoreArt.swift Recipe.swift FetchPlan.swift StagePlan.swift AssetFiles.swift ContentStore.swift \
            Hashing.swift; do
    SOURCE="$ROOT/$NAME"
    TARGET="Standalone/Shared/$NAME"
    [ -f "$SOURCE" ] || { echo "nicht gefunden: $SOURCE" >&2; exit 1; }
    if [ "$CHECK" = 1 ]; then
        cmp -s "$SOURCE" "$TARGET" && echo "$NAME ist gleich" || { echo "$NAME weicht ab" >&2; STATUS=1; }
    else
        cp "$SOURCE" "$TARGET"
        echo "$NAME übernommen"
    fi
done
exit $STATUS
