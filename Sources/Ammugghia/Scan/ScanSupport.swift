import Foundation

/// Utilità condivise dagli scanner.
enum ScanSupport {

    static let home = NSHomeDirectory()
    static let fm = FileManager.default

    static func exists(_ path: String) -> Bool { fm.fileExists(atPath: path) }

    static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return false }
        return isDir.boolValue
    }

    /// Figli diretti di una cartella, percorsi assoluti, senza i file nascosti
    /// di sistema.
    static func children(of path: String, includeHidden: Bool = false) -> [String] {
        guard let names = try? fm.contentsOfDirectory(atPath: path) else { return [] }
        return names
            .filter { includeHidden || !$0.hasPrefix(".") }
            .filter { $0 != ".DS_Store" }
            .map { path + "/" + $0 }
            .sorted()
    }

    static func modificationDate(_ path: String) -> Date? {
        (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    /// Crea un elemento per una cartella singola, calcolandone la dimensione.
    /// Restituisce `nil` se la cartella non esiste o è vuota: gli elementi a
    /// zero byte sono solo rumore nell'elenco.
    static func item(title: String,
                     detail: String,
                     consequence: String,
                     path: String,
                     risk: RiskLevel,
                     lastUsed: Date? = nil,
                     warning: String? = nil,
                     requiredStoppedApps: [String] = [],
                     minBytes: Int64 = 1_000_000) -> CleanupItem? {
        guard exists(path) else { return nil }
        let size = Shell.diskSize(path)
        guard size >= minBytes else { return nil }
        return CleanupItem(title: title, detail: detail, consequence: consequence,
                           action: .removePaths([path]), risk: risk, size: size,
                           perPathSize: [path: size], lastUsed: lastUsed, warning: warning,
                           requiredStoppedApps: requiredStoppedApps)
    }

    /// Elemento che raggruppa più percorsi (es. tutte le cache di un tool).
    static func item(title: String,
                     detail: String,
                     consequence: String,
                     paths: [String],
                     risk: RiskLevel,
                     lastUsed: Date? = nil,
                     warning: String? = nil,
                     requiredStoppedApps: [String] = [],
                     minBytes: Int64 = 1_000_000) -> CleanupItem? {
        let present = paths.filter(exists)
        guard !present.isEmpty else { return nil }
        let sizes = Shell.diskSizes(present)
        let total = sizes.values.reduce(0, +)
        guard total >= minBytes else { return nil }
        return CleanupItem(title: title, detail: detail, consequence: consequence,
                           action: .removePaths(present), risk: risk, size: total,
                           perPathSize: sizes, lastUsed: lastUsed, warning: warning,
                           requiredStoppedApps: requiredStoppedApps)
    }

    /// Svuota il *contenuto* di una cartella conservando la cartella stessa.
    /// Serve per le cache che il proprietario si aspetta di trovare esistenti
    /// (es. `~/Library/Developer/Xcode/DerivedData`).
    static func contentsItem(title: String,
                             detail: String,
                             consequence: String,
                             directory: String,
                             risk: RiskLevel,
                             warning: String? = nil,
                             minBytes: Int64 = 1_000_000) -> CleanupItem? {
        guard isDirectory(directory) else { return nil }
        let kids = children(of: directory, includeHidden: true)
        guard !kids.isEmpty else { return nil }
        let sizes = Shell.diskSizes(kids)
        let total = sizes.values.reduce(0, +)
        guard total >= minBytes else { return nil }
        return CleanupItem(title: title, detail: detail, consequence: consequence,
                           action: .removePaths(kids), risk: risk, size: total,
                           perPathSize: sizes,
                           lastUsed: modificationDate(directory), warning: warning)
    }

    /// Legge un valore da un plist tramite PlistBuddy: gestisce sia il formato
    /// binario che XML senza dover scegliere in anticipo.
    static func plistValue(_ path: String, key: String) -> String? {
        guard exists(path) else { return nil }
        let r = Shell.run("/usr/libexec/PlistBuddy", ["-c", "Print :\(key)", path], timeout: 15)
        guard r.ok else { return nil }
        let v = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    /// Converte un plist in JSON per poterlo decodificare con Codable.
    static func plistAsJSON(_ path: String) -> Any? {
        guard exists(path), let data = fm.contents(atPath: path) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    }

    static func jsonObject(fromFile path: String) -> Any? {
        guard let data = fm.contents(atPath: path) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    static func jsonObject(fromString s: String) -> Any? {
        guard let data = s.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
}

/// Informazioni sullo spazio del volume di avvio.
struct DiskInfo {
    var total: Int64 = 0
    var free: Int64 = 0
    /// Spazio che macOS può liberare da sé (snapshot locali, cache di sistema).
    /// Mostrato a parte per non confonderlo con lo spazio davvero disponibile.
    var purgeable: Int64 = 0
    var used: Int64 { max(0, total - free) }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    static func current() -> DiskInfo {
        var info = DiskInfo()
        let url = URL(fileURLWithPath: NSHomeDirectory())
        // `volumeAvailableCapacity` è lo spazio realmente libero, quello che
        // riporta `df`. La variante "ForImportantUsage" include lo spazio
        // liberabile (snapshot, cache di sistema) e mostrerebbe più GB di
        // quanti ce ne siano davvero: per uno strumento che misura il
        // recupero di spazio sarebbe fuorviante.
        if let values = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ]) {
            info.total = Int64(values.volumeTotalCapacity ?? 0)
            info.free = Int64(values.volumeAvailableCapacity ?? 0)
            info.purgeable = max(0, (values.volumeAvailableCapacityForImportantUsage ?? 0) - info.free)
        }
        return info
    }
}
