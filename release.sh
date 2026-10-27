#!/bin/zsh
# Pubblica su GitHub la versione scritta nel file VERSION: compila, crea lo zip e la release.
# Prima di lanciarlo: aggiorna VERSION, fai commit e push.
set -e
cd "$(dirname "$0")"
V=$(cat VERSION)
[[ -z "$(git status --porcelain)" ]] || { echo "Ci sono modifiche non committate."; exit 1; }
./build.sh
ZIP="Genuzzu-$V.zip"
rm -f "$ZIP"
ditto -c -k --keepParent Genuzzu.app "$ZIP"
gh release create "v$V" "$ZIP" --title "Genuzzu $V" --notes "${1:-Versione $V}"
rm -f "$ZIP"
echo "Release v$V pubblicata."
