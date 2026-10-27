#!/bin/zsh
# Compila OrdinaCartelle.app (richiede i Command Line Tools di Xcode)
set -e
cd "$(dirname "$0")"
APP="OrdinaCartelle.app"
VERSION=$(cat VERSION)
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp AppIcon.icns "$APP/Contents/Resources/"
swiftc -O -swift-version 5 -parse-as-library OrdinaCartelle.swift -o "$APP/Contents/MacOS/OrdinaCartelle"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Ordina Cartelle</string>
<key>CFBundleDisplayName</key><string>Ordina Cartelle</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleExecutable</key><string>OrdinaCartelle</string>
<key>CFBundleIdentifier</key><string>local.ordinacartelle</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>$VERSION</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "Creata: $PWD/$APP"
