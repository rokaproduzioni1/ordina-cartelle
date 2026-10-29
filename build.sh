#!/bin/zsh
# Compila Genuzzu.app (richiede i Command Line Tools di Xcode)
set -e
cd "$(dirname "$0")"
APP="Genuzzu.app"
VERSION=$(cat VERSION)
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp AppIcon.icns "$APP/Contents/Resources/"
swiftc -O -swift-version 5 -parse-as-library OrdinaCartelle.swift -o "$APP/Contents/MacOS/Genuzzu"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Genuzzu</string>
<key>CFBundleDisplayName</key><string>Genuzzu</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleExecutable</key><string>Genuzzu</string>
<key>CFBundleIdentifier</key><string>local.genuzzu</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>$VERSION</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSDesktopFolderUsageDescription</key><string>Genuzzu cerca e mette in ordine i file nella cartella Scrivania.</string>
<key>NSDocumentsFolderUsageDescription</key><string>Genuzzu cerca e mette in ordine i file nella cartella Documenti.</string>
<key>NSDownloadsFolderUsageDescription</key><string>Genuzzu cerca e mette in ordine i file nella cartella Download.</string>
<key>NSRemovableVolumesUsageDescription</key><string>Genuzzu cerca i file nei dischi esterni collegati.</string>
<key>NSNetworkVolumesUsageDescription</key><string>Genuzzu cerca i file nei dischi di rete collegati.</string>
</dict></plist>
PLIST
# Requisito di firma legato al nome dell'app e non all'impronta del file: così macOS
# riconosce Genuzzu come la stessa app anche dopo ricompilazioni e aggiornamenti
# e chiede il consenso alle cartelle una volta sola.
codesign --force --sign - -r='designated => identifier "local.genuzzu"' "$APP"
echo "Creata: $PWD/$APP"

# DMG con collegamento ad Applicazioni
STAGE="build-dmg"; rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Genuzzu" -srcfolder "$STAGE" -ov -format UDZO "Genuzzu.dmg" >/dev/null
rm -rf "$STAGE"
echo "Creato: $PWD/Genuzzu.dmg"
