#!/bin/bash
# Compila Ammugghia e assembla un bundle .app avviabile con doppio clic.
# Uso: ./build.sh [--install]
#   --install  copia l'app in /Applications al posto di ./dist
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Ammugghia"
BUNDLE_ID="it.ammugghia"
VERSION="1.0"

# L'icona è disegnata da uno script Swift: si rigenera solo se manca o se il
# disegno è stato modificato dopo l'ultima generazione.
ICON="Resources/AppIcon.icns"
if [[ ! -f "$ICON" || "Tools/MakeIcon.swift" -nt "$ICON" ]]; then
    echo "▸ Generazione dell'icona…"
    swift Tools/MakeIcon.swift Resources/Ammugghia.iconset
    iconutil -c icns Resources/Ammugghia.iconset -o "$ICON"
fi

echo "▸ Compilazione in modalità release…"
swift build -c release

BIN="$(swift build -c release --show-bin-path)/$APP_NAME"
if [[ ! -x "$BIN" ]]; then
    echo "✗ Eseguibile non trovato in $BIN" >&2
    exit 1
fi

DEST="dist"
APP="$DEST/$APP_NAME.app"
echo "▸ Assemblaggio del bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>       <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>        <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>        <string>$BUNDLE_ID</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key>           <string>$VERSION</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSHumanReadableCopyright</key>  <string>Strumento di pulizia locale. Nessun dato lascia il Mac.</string>
    <!-- L'app non è in sandbox: deve poter leggere le cache degli altri
         programmi. Per alcune aree protette da macOS serve comunque
         «Accesso completo al disco». -->
    <key>NSAppleEventsUsageDescription</key>
    <string>Serve a eseguire con privilegi di amministratore le operazioni sulle cartelle di sistema, mostrando prima il comando esatto.</string>
    <key>NSSystemAdministrationUsageDescription</key>
    <string>Serve a rimuovere cache di sistema come quella dei simulatori iOS.</string>
</dict>
</plist>
PLIST

# Firma ad-hoc: senza, macOS 15+ rifiuta di avviare un bundle assemblato a mano.
echo "▸ Firma ad-hoc…"
codesign --force --deep --sign - "$APP" 2>/dev/null || \
    echo "  (firma non riuscita: al primo avvio usa clic destro → Apri)"

if [[ "${1:-}" == "--install" ]]; then
    echo "▸ Installazione in /Applications…"
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP" /Applications/
    echo "✓ Installata: /Applications/$APP_NAME.app"
    open "/Applications/$APP_NAME.app"
else
    echo "✓ Pronta: $(pwd)/$APP"
    echo "  Avvia con:  open '$(pwd)/$APP'"
    echo "  Installa con: ./build.sh --install"
fi
