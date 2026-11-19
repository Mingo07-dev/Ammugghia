import Foundation

/// Le «ricevute» che il programma d'installazione di macOS lascia per ogni
/// pacchetto (`pkgutil`). Quando il pacchetto non ha più nessun file sul disco
/// la ricevuta è un residuo: dimenticarla non tocca nessun file.
enum PackageReceipts {

    /// Solo caratteri che un identificatore di pacchetto può avere davvero:
    /// l'id finisce in un comando eseguito con privilegi, e uno che inizia con
    /// «-» diventerebbe un'opzione di `pkgutil`.
    static func isValidID(_ id: String) -> Bool {
        !id.hasPrefix("-") && id.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil
    }

    /// Le ricevute di Apple non si toccano mai.
    static func isForgettable(_ id: String) -> Bool {
        isValidID(id) && !id.lowercased().hasPrefix("com.apple.")
    }

    /// Tutte le ricevute non Apple installate.
    static func installedIDs() -> [String] {
        let result = Shell.run("/usr/sbin/pkgutil", ["--pkgs"], timeout: 30)
        guard result.ok else { return [] }
        return result.stdout.split(separator: "\n").map(String.init).filter(isForgettable).sorted()
    }

    static let receiptsDirectory = "/var/db/receipts"

    /// La cartella in cui il pacchetto è stato installato, dalla ricevuta
    /// stessa (`InstallPrefixPath`, relativo a «/»): evita un processo
    /// `pkgutil` per ogni ricevuta. `nil` se la ricevuta non si legge.
    private static func installBase(_ id: String, directory: String) -> String? {
        guard let data = FileManager.default.contents(atPath: directory + "/" + id + ".plist"),
              let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
        else { return nil }
        let prefix = (plist["InstallPrefixPath"] as? String) ?? "/"
        return prefix.hasPrefix("/") ? prefix : "/" + prefix
    }

    /// `true` solo se si è *dimostrato* che nessun file del pacchetto esiste
    /// più: ricevuta illeggibile, elenco file vuoto o errore di `pkgutil`
    /// significano «non lo so», quindi `false`.
    static func hasNoFilesLeft(_ id: String, receipts: String = receiptsDirectory) -> Bool {
        guard isForgettable(id), let base = installBase(id, directory: receipts) else { return false }
        let list = Shell.run("/usr/sbin/pkgutil", ["--only-files", "--files", id], timeout: 60)
        guard list.ok else { return false }
        let files = list.stdout.split(separator: "\n").map(String.init)
        guard !files.isEmpty else { return false }

        var info = stat()
        for file in files {
            let full = (base as NSString).appendingPathComponent(file)
            if lstat(full, &info) == 0 { return false }
        }
        return true
    }

    private static let memo = ScanMemo<[String]>()

    static func invalidate() { memo.invalidate() }

    /// Ricevute non Apple senza più file. I controlli sono indipendenti: si
    /// fanno in parallelo, e il risultato vale un minuto.
    static func orphanIDs() -> [String] {
        memo.value {
            let ids = installedIDs()
            let results = UncheckedBox([Bool](repeating: false, count: ids.count))
            DispatchQueue.concurrentPerform(iterations: ids.count) { index in
                let orphaned = hasNoFilesLeft(ids[index])
                results.lock.lock()
                results.value[index] = orphaned
                results.lock.unlock()
            }
            return zip(ids, results.value).filter(\.1).map(\.0)
        }
    }

    /// Il comando letterale eseguito da amministratore; `nil` se un id non è valido.
    static func forgetCommand(_ ids: [String]) -> String? {
        guard !ids.isEmpty, ids.allSatisfy(isForgettable) else { return nil }
        return ids.map { "/usr/sbin/pkgutil --forget \(Shell.shellQuote($0))" }.joined(separator: " && ")
    }
}

/// Un valore condiviso fra le iterazioni di `concurrentPerform`, protetto dal
/// suo blocco.
private final class UncheckedBox<Value>: @unchecked Sendable {
    let lock = NSLock()
    var value: Value
    init(_ value: Value) { self.value = value }
}
