#!/bin/zsh
# Crea Genuzzu-Installer.zip (DMG pronto da condividere). Ricompila solo se il sorgente è più nuovo del DMG.
set -e
cd "$(dirname "$0")"
if [[ ! -f Genuzzu.dmg || OrdinaCartelle.swift -nt Genuzzu.dmg || VERSION -nt Genuzzu.dmg || build.sh -nt Genuzzu.dmg ]]; then ./build.sh; fi
rm -f Genuzzu-Installer.zip
ditto -c -k --norsrc Genuzzu.dmg Genuzzu-Installer.zip
echo "Installer aggiornato: $PWD/Genuzzu-Installer.zip"
