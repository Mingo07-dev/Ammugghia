#!/bin/bash
# Prepara un DMG firmato con Developer ID e notarizzato da Apple, pronto da
# pubblicare. Non pubblica nulla: l'upload nelle Release resta un passo a parte.
#
# Uso: ./release.sh <versione>        es. ./release.sh 1.8.0
#
# Serve, una volta sola, il profilo di notarizzazione nel portachiavi:
#   xcrun notarytool store-credentials "ammugghia-notary" \
#       --apple-id <email> --team-id <TEAM ID>
#
# Variabili (facoltative):
#   SIGN_IDENTITY   identità di firma (predefinita: il primo «Developer ID Application»)
#   NOTARY_PROFILE  profilo del portachiavi (predefinito: ammugghia-notary)
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:?Uso: ./release.sh <versione>, es. ./release.sh 1.8.0}"
APP_NAME="Ammugghia"
APP="dist/$APP_NAME.app"
DMG="dist/$APP_NAME-$VERSION.dmg"
NOTARY_PROFILE="${NOTARY_PROFILE:-ammugghia-notary}"
SIGN_IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}"

fail() { echo "✗ $*" >&2; exit 1; }
step() { echo; echo "▸ $*"; }

[[ -n "$SIGN_IDENTITY" ]] || fail "Nessun certificato «Developer ID Application» nel portachiavi."
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || fail "Profilo di notarizzazione «$NOTARY_PROFILE» assente o non valido (vedi l'intestazione dello script)."
# Una Release deve corrispondere esattamente al codice pubblicato.
[[ -z "$(git status --porcelain --untracked-files=no)" ]] \
    || fail "Ci sono modifiche non salvate in git: fai prima il commit."

echo "Ammugghia $VERSION — firma: $SIGN_IDENTITY"

step "Autotest delle protezioni"
swift build -c release >/dev/null
"$(swift build -c release --show-bin-path)/$APP_NAME" --selftest >/dev/null \
    || fail "--selftest non superato: niente rilascio."
Tools/check-localization.sh >/dev/null || fail "Traduzioni inglesi incomplete."

step "Compilazione universale e bundle"
AMMUGGHIA_VERSION="$VERSION" UNIVERSAL=1 ./build.sh >/dev/null
lipo -info "$APP/Contents/MacOS/$APP_NAME"

step "Firma con Developer ID (hardened runtime, timestamp)"
# Prima l'eseguibile, poi il bundle: un solo binario, nessun framework annidato.
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP/Contents/MacOS/$APP_NAME"
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

step "Autotest dall'app firmata (l'hardened runtime non deve cambiare nulla)"
"$APP/Contents/MacOS/$APP_NAME" --selftest >/dev/null || fail "--selftest non superato dall'app firmata."

notarize() {
    local file="$1"
    local log; log="$(mktemp)"
    xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json | tee "$log"
    if ! grep -q '"status" *: *"Accepted"' "$log"; then
        local id; id="$(sed -n 's/.*"id" *: *"\([^"]*\)".*/\1/p' "$log" | head -1)"
        [[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE"
        fail "Notarizzazione rifiutata per $file"
    fi
}

step "Notarizzazione dell'app"
ZIP="dist/$APP_NAME-$VERSION-notarize.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
notarize "$ZIP"
rm -f "$ZIP"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl -a -vvv -t exec "$APP" 2>&1 | tee /dev/stderr | grep -q "Notarized Developer ID" \
    || fail "Gatekeeper non riconosce l'app come notarizzata."

step "Immagine disco"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

step "Firma e notarizzazione del DMG"
# Anche l'immagine va firmata e notarizzata: altrimenti Gatekeeper avvisa
# sul DMG anche se l'app dentro è a posto.
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl -a -vvv -t open --context context:primary-signature "$DMG" 2>&1 | tee /dev/stderr \
    | grep -q "Notarized Developer ID" || fail "Gatekeeper non riconosce il DMG come notarizzato."

step "Impronta"
( cd dist && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256" )
cat "$DMG.sha256"

echo
echo "✓ Pronto: $DMG"
echo "  Per pubblicarlo: gh release create v$VERSION \"$DMG\" \"$DMG.sha256\" …"
