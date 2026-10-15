// Confronta le chiavi estratte dal compilatore (`.stringsdata`) con le
// traduzioni inglesi. Uso:
//   swift Tools/CheckLocalization.swift <cartella .stringsdata> <en.lproj/Localizable.strings> [--missing]
// Esce con errore se una chiave non ha traduzione; le traduzioni che non
// corrispondono più a nessuna chiave sono solo segnalate. Con `--missing` stampa le chiavi mancanti
// nel formato `.strings`, pronte da tradurre.
import Foundation

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("uso: CheckLocalization <cartella stringsdata> <Localizable.strings> [--missing]")
    exit(2)
}
let fm = FileManager.default
var keys: [String: String] = [:]   // chiave → posizione
let files = (fm.enumerator(atPath: args[1])?.allObjects as? [String] ?? []).filter { $0.hasSuffix(".stringsdata") }
for file in files.sorted() {
    guard let data = fm.contents(atPath: args[1] + "/" + file),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let tables = json["tables"] as? [String: Any],
          let entries = tables["Localizable"] as? [[String: Any]] else { continue }
    let source = (json["source"] as? String).map { ($0 as NSString).lastPathComponent } ?? file
    for entry in entries {
        guard let key = entry["key"] as? String else { continue }
        let line = (entry["location"] as? [String: Any])?["startingLine"] as? Int ?? 0
        if keys[key] == nil { keys[key] = "\(source):\(line)" }
    }
}

let translations: [String: String]
if let data = fm.contents(atPath: args[2]), !data.isEmpty {
    guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] else {
        print("✗ \(args[2]) non è un file .strings valido")
        exit(1)
    }
    translations = plist
} else {
    translations = [:]
}

let missing = keys.keys.filter { translations[$0] == nil }.sorted()
let orphaned = translations.keys.filter { keys[$0] == nil }.sorted()

func escape(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
}

if args.contains("--missing") {
    for key in missing { print("/* \(keys[key]!) */\n\"\(escape(key))\" = \"\";\n") }
    exit(0)
}
print("Chiavi nel codice: \(keys.count) · tradotte: \(keys.count - missing.count) · mancanti: \(missing.count) · orfane: \(orphaned.count)")
for key in missing.prefix(40) { print("  mancante  \(keys[key]!)  \"\(key)\"") }
for key in orphaned.prefix(40) { print("  orfana    \"\(key)\"") }
// Le chiavi orfane sono innocue (una traduzione in più) e compilatori di
// versioni diverse non estraggono sempre le stesse: solo le mancanti, che
// mostrerebbero testo italiano in inglese, fanno fallire il controllo.
if !orphaned.isEmpty { print("  (avviso: \(orphaned.count) chiavi orfane, non bloccanti)") }
exit(missing.isEmpty ? 0 : 1)
