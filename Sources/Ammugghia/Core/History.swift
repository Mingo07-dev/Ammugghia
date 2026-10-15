import Foundation

/// Una voce della cronologia: un'operazione eseguita davvero, non simulata.
struct HistoryEntry: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case cleanup, startup }

    var id = UUID()
    let date: Date
    let kind: Kind
    let origin: String
    let title: String
    let paths: [String]
    let freed: Int64
    let succeeded: Bool
    let skipped: Bool
    let message: String
    /// «Cestino», «Definitiva» o il comando eseguito.
    let mode: String
    /// Percorso originale → posizione nel Cestino.
    var trashed: [String: String]
    var restored: [String] = []

    var restorable: [String] { trashed.keys.filter { !restored.contains($0) }.sorted() }
}

/// La cronologia delle operazioni, in `~/Library/Application Support/Ammugghia`.
///
/// Scritta in modo atomico. Un file illeggibile non viene mai sovrascritto:
/// lo si mette da parte con un altro nome e si riparte vuoti, così niente si
/// perde senza che si possa recuperare.
final class HistoryStore {
    static let maxEntries = 1_000
    static let maxAge: TimeInterval = 365 * 86_400
    /// Oltre questo numero di file (es. migliaia di file temporanei) non si
    /// conserva l'elenco per il ripristino: resta solo la voce.
    static let maxRestorablePaths = 200

    static let shared = HistoryStore(storage: URL(fileURLWithPath: ScanSupport.home)
        .appendingPathComponent("Library/Application Support/Ammugghia/history-v1.json"))

    let storage: URL
    private let lock = NSLock()
    private var entries: [HistoryEntry] = []
    private var loaded = false

    init(storage: URL) { self.storage = storage }

    var all: [HistoryEntry] {
        lock.lock(); defer { lock.unlock() }
        load()
        return entries
    }

    func append(_ new: [HistoryEntry]) {
        guard !new.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        load()
        let trimmed = new.map { entry -> HistoryEntry in
            var e = entry
            if e.trashed.count > HistoryStore.maxRestorablePaths { e.trashed = [:] }
            return e
        }
        entries = (trimmed + entries)
            .filter { Date().timeIntervalSince($0.date) < HistoryStore.maxAge }
        if entries.count > HistoryStore.maxEntries { entries = Array(entries.prefix(HistoryStore.maxEntries)) }
        save()
    }

    enum RestoreError: LocalizedError {
        case notInTrash(String), occupied(String), parentMissing(String), unknown(String)
        var errorDescription: String? {
            switch self {
            case .notInTrash(let p): return String(localized: "Non è più nel Cestino (svuotato o già ripristinato): \(p)")
            case .occupied(let p): return String(localized: "Al posto originale c'è già qualcosa, non lo sovrascrivo: \(p)")
            case .parentMissing(let p): return String(localized: "La cartella che lo conteneva non esiste più: \(p)")
            case .unknown(let p): return String(localized: "Elemento non presente in questa voce: \(p)")
            }
        }
    }

    /// Rimette al suo posto ciò che un'operazione ha spostato nel Cestino.
    /// Si limita a spostare: non sovrascrive, non crea cartelle, non elimina.
    func restore(entryID: UUID, path original: String) throws {
        lock.lock(); defer { lock.unlock() }
        load()
        guard let index = entries.firstIndex(where: { $0.id == entryID }),
              let inTrash = entries[index].trashed[original] else { throw RestoreError.unknown(original) }
        let fm = FileManager.default
        guard FileIdentity.of(inTrash) != nil, HistoryStore.isInTrash(inTrash) else {
            throw RestoreError.notInTrash(original)
        }
        guard FileIdentity.of(original) == nil else { throw RestoreError.occupied(original) }
        guard ScanSupport.isDirectory((original as NSString).deletingLastPathComponent) else {
            throw RestoreError.parentMissing(original)
        }
        try fm.moveItem(atPath: inTrash, toPath: original)
        entries[index].restored.append(original)
        save()
    }

    /// Il ripristino parte solo da un Cestino vero: la posizione registrata
    /// non deve poter indicare un percorso qualsiasi.
    static func isInTrash(_ path: String) -> Bool {
        let p = PathGuard.normalize(path)
        if p.hasPrefix(ScanSupport.home + "/.Trash/") { return true }
        // Cestini dei volumi: /Volumes/<nome>/.Trashes/<uid>/…
        return p.hasPrefix("/Volumes/") && p.contains("/.Trashes/\(getuid())/")
    }

    // MARK: File

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: storage) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([HistoryEntry].self, from: data) {
            entries = decoded
        } else {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let aside = storage.deletingLastPathComponent()
                .appendingPathComponent("history-v1.invalid-\(stamp).json")
            try? FileManager.default.moveItem(at: storage, to: aside)
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entries) else { return }
        try? FileManager.default.createDirectory(at: storage.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: storage, options: .atomic)
    }
}
