#!/bin/bash
# Estrae le chiavi di traduzione con il compilatore e le confronta con
# l'inglese. Uso: Tools/check-localization.sh [--missing]
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=".build/l10n-strings"
rm -rf "$OUT" .build/l10n && mkdir -p "$OUT"
# Cartella di build separata e sempre vuota: con una compilazione
# incrementale i file non modificati non produrrebbero il loro .stringsdata,
# e il controllo vedrebbe zero chiavi.
swift build -c release --build-path .build/l10n \
    -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$PWD/$OUT" >/dev/null
swift Tools/CheckLocalization.swift "$OUT" Resources/Localization/en.lproj/Localizable.strings "$@"
