#!/bin/zsh
# Crea Genuzzu-Installer.zip (app pronta da condividere). Ricompila solo se il sorgente è più nuovo dell'app.
set -e
cd "$(dirname "$0")"
if [[ ! -d Genuzzu.app || OrdinaCartelle.swift -nt Genuzzu.app || VERSION -nt Genuzzu.app ]]; then ./build.sh; fi
rm -f Genuzzu-Installer.zip
ditto -c -k --norsrc --keepParent Genuzzu.app Genuzzu-Installer.zip
echo "Installer aggiornato: $PWD/Genuzzu-Installer.zip"
