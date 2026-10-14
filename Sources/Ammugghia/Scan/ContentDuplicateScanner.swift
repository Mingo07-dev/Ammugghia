import Foundation
import CryptoKit
import Darwin

/// Un file in un gruppo di duplicati.
struct DuplicateFile: Identifiable, Hashable {
    let path: String
    let modified: Date
    /// Byte che solo questo file occupa: per una copia clonata da APFS (la
    /// copia che fa il Finder) è quasi zero, perché i blocchi sono condivisi.
    let privateSize: Int64?
    /// File con lo stesso identificativo di clone condividono i blocchi.
    let cloneID: UInt64?
    var id: String { path }
}

/// File con contenuto identico. Solo visualizzazione: il tipo è distinto da
/// `CleanupItem` apposta, così un duplicato non può mai finire nel foglio di
/// conferma né nel motore di eliminazione.
struct DuplicateGroup: Identifiable, Hashable {
    let hash: String
    let size: Int64
    let files: [DuplicateFile]
    var id: String { hash }

    /// Spazio che si libererebbe tenendo una sola copia: lo spazio fisico di
    /// tutte le copie meno quello di una. I cloni APFS (stesso `cloneID`)
    /// sono una sola copia fisica, più gli eventuali blocchi modificati.
    var recoverable: Int64 {
        var clusters: [String: [DuplicateFile]] = [:]
        for file in files {
            clusters[file.cloneID.map { "c\($0)" } ?? "f\(file.path)", default: []].append(file)
        }
        let physical = clusters.values.reduce(Int64(0)) { total, members in
            let privates = members.map { $0.privateSize ?? 0 }
            let extra = members.count > 1 ? privates.reduce(0, +) - (privates.max() ?? 0) : 0
            return total + size + extra
        }
        return max(0, physical - size)
    }

    /// Spazio che sembrerebbe sprecato contando le copie a dimensione piena.
    var apparentWaste: Int64 { size * Int64(files.count - 1) }
    var hasClones: Bool { recoverable < apparentWaste / 2 }
}

/// Ricerca dei file con contenuto identico nelle cartelle personali.
///
/// Tre stadi, dal più economico: stessa dimensione esatta, poi un'impronta di
/// tre campioni da 16 KiB (inizio, metà, fine) che serve solo a *scartare*,
/// infine l'impronta SHA-256 dell'intero contenuto. Due file sono duplicati
/// solo se coincide quest'ultima.
enum ContentDuplicateScanner {

    struct Progress {
        var stage: String
        var done: Int
        var total: Int
    }

    static var defaultRoots: [String] {
        let home = ScanSupport.home
        return ["/Documents", "/Desktop", "/Downloads", "/Movies", "/Pictures", "/Music"]
            .map { home + $0 }.filter(ScanSupport.isDirectory)
    }

    /// Pacchetti gestiti da un'app: il loro contenuto non va confrontato file
    /// per file (una libreria Foto ha migliaia di miniature uguali per
    /// costruzione, e non si tocca dall'esterno).
    static let packageExtensions: Set<String> = [
        "app", "photoslibrary", "musiclibrary", "fcpbundle", "logicx", "xcodeproj",
        "xcworkspace", "framework", "bundle", "plugin", "imovielibrary", "tvlibrary",
        "aplibrary", "band", "dSYM", "xcarchive", "pages", "numbers", "key",
    ]
    static let skippedDirectories: Set<String> = [".git", "node_modules", ".Trash", "Pods", ".build", "DerivedData"]

    struct Candidate {
        let path: String
        let size: Int64
        let modified: Int64
        let device: UInt64
        let inode: UInt64
    }

    static func find(roots: [String], minimumSize: Int64,
                     cache: HashCache? = nil,
                     exclusions: ExclusionSet = .empty,
                     progress: ((Progress) -> Void)? = nil,
                     isCancelled: @escaping () -> Bool = { false }) -> [DuplicateGroup] {
        // 1. Elenco dei file, un inode una volta sola: i collegamenti fisici
        //    sono lo stesso file, non un duplicato.
        progress?(Progress(stage: "Elenco dei file", done: 0, total: 0))
        var candidates: [Candidate] = []
        var seen = Set<String>()
        for root in roots where !isCancelled() {
            collect(root, device: BulkEnumerator.device(of: root) ?? 0, minimumSize: minimumSize,
                    exclusions: exclusions, into: &candidates, seen: &seen, isCancelled: isCancelled)
        }

        // 2. Stessa dimensione.
        let bySize = Dictionary(grouping: candidates, by: \.size).values.filter { $0.count > 1 }
        let toSample = bySize.flatMap { $0 }

        // 3. Campioni, poi impronta completa solo dove i campioni coincidono.
        var sampled: [String: String] = [:]
        let lock = NSLock()
        var done = 0
        concurrently(toSample, isCancelled: isCancelled) { candidate in
            let digest = cache?.lookup(candidate, kind: .sample) ?? sampleHash(candidate)
            lock.lock()
            if let digest { sampled[candidate.path] = digest; cache?.store(candidate, kind: .sample, digest) }
            done += 1
            let snapshot = done
            lock.unlock()
            if snapshot % 50 == 0 { progress?(Progress(stage: "Confronto rapido", done: snapshot, total: toSample.count)) }
        }

        var toHash: [Candidate] = []
        for group in bySize {
            let bySample = Dictionary(grouping: group.filter { sampled[$0.path] != nil }) { sampled[$0.path]! }
            toHash += bySample.values.filter { $0.count > 1 }.flatMap { $0 }
        }

        var full: [String: String] = [:]
        done = 0
        concurrently(toHash, isCancelled: isCancelled) { candidate in
            let digest = cache?.lookup(candidate, kind: .full) ?? fullHash(candidate)
            lock.lock()
            if let digest { full[candidate.path] = digest; cache?.store(candidate, kind: .full, digest) }
            done += 1
            let snapshot = done
            lock.unlock()
            if snapshot % 10 == 0 { progress?(Progress(stage: "Confronto completo", done: snapshot, total: toHash.count)) }
        }
        cache?.save()
        guard !isCancelled() else { return [] }

        // 4. Gruppi, con lo spazio davvero condiviso fra cloni APFS.
        let byHash = Dictionary(grouping: toHash.filter { full[$0.path] != nil }) { "\($0.size)-" + full[$0.path]! }
        return byHash.compactMap { key, members -> DuplicateGroup? in
            guard members.count > 1 else { return nil }
            let files = members.map { m -> DuplicateFile in
                let clone = cloneInfo(m.path)
                return DuplicateFile(path: m.path,
                                     modified: Date(timeIntervalSince1970: Double(m.modified)),
                                     privateSize: clone?.privateSize, cloneID: clone?.cloneID)
            }.sorted { $0.modified < $1.modified }
            return DuplicateGroup(hash: key, size: members[0].size, files: files)
        }
        .sorted { $0.recoverable > $1.recoverable }
    }

    // MARK: Elenco

    private static func collect(_ path: String, device: UInt64, minimumSize: Int64,
                                exclusions: ExclusionSet,
                                into result: inout [Candidate], seen: inout Set<String>,
                                isCancelled: () -> Bool) {
        guard !isCancelled(), let entries = BulkEnumerator.entries(of: path) else { return }
        for entry in entries {
            let child = path + "/" + entry.name
            if exclusions.excludes(child, scope: .duplicates) { continue }
            if entry.isDirectory {
                guard entry.device == device, !entry.isDataless,
                      !skippedDirectories.contains(entry.name),
                      !packageExtensions.contains((entry.name as NSString).pathExtension) else { continue }
                // Prodotti di compilazione (`build` accanto a un pubspec.yaml…):
                // copie uguali per costruzione, già nella categoria degli
                // artefatti di progetto.
                if let markers = PathGuard.projectArtifactRules[entry.name],
                   PathGuard.hasMarker(in: path, markers) { continue }
                collect(child, device: device, minimumSize: minimumSize, exclusions: exclusions,
                        into: &result, seen: &seen, isCancelled: isCancelled)
            } else if entry.isRegularFile, !entry.isDataless, entry.logicalSize >= minimumSize {
                guard seen.insert("\(entry.device):\(entry.inode)").inserted else { continue }
                result.append(Candidate(path: child, size: entry.logicalSize, modified: entry.modified,
                                        device: entry.device, inode: entry.inode))
            }
        }
    }

    // MARK: Impronte

    static let sampleLength = 16 * 1024

    /// Inizio, metà e fine. Serve solo a scartare: due file con campioni
    /// diversi sono certamente diversi, con campioni uguali non si sa ancora.
    static func sampleHash(_ candidate: Candidate) -> String? {
        guard let handle = FileHandle(forReadingAtPath: candidate.path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        let offsets: [UInt64] = [0, UInt64(max(0, candidate.size / 2 - Int64(sampleLength) / 2)),
                                 UInt64(max(0, candidate.size - Int64(sampleLength)))]
        for offset in offsets {
            guard (try? handle.seek(toOffset: offset)) != nil,
                  let data = try? handle.read(upToCount: sampleLength) else { return nil }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// SHA-256 dell'intero contenuto, letto a blocchi da 1 MiB. Se il file
    /// cambia durante la lettura il risultato non vale e il file viene escluso.
    static func fullHash(_ candidate: Candidate) -> String? {
        guard unchanged(candidate), let handle = FileHandle(forReadingAtPath: candidate.path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        var total: Int64 = 0
        while true {
            let chunk: Data
            do {
                guard let data = try handle.read(upToCount: 1 << 20), !data.isEmpty else { break }
                chunk = data
            } catch { return nil }
            hasher.update(data: chunk)
            total += Int64(chunk.count)
        }
        guard total == candidate.size, unchanged(candidate) else { return nil }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func unchanged(_ candidate: Candidate) -> Bool {
        var info = stat()
        guard lstat(candidate.path, &info) == 0 else { return false }
        return Int64(info.st_size) == candidate.size
            && Int64(info.st_mtimespec.tv_sec) == candidate.modified
            && UInt64(info.st_ino) == candidate.inode
    }

    /// Identificativo di clone e byte non condivisi, chiesti ad APFS. `nil`
    /// se il file system non lo sa dire: il file conta allora per intero.
    static func cloneInfo(_ path: String) -> (cloneID: UInt64, privateSize: Int64)? {
        let privateSizeBit: UInt32 = 0x0000_0008   // ATTR_CMNEXT_PRIVATESIZE
        let cloneIDBit: UInt32 = 0x0000_0100       // ATTR_CMNEXT_CLONEID
        var request = attrlist()
        request.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        request.commonattr = 0x8000_0000           // ATTR_CMN_RETURNED_ATTRS
        request.forkattr = privateSizeBit | cloneIDBit
        var buffer = [UInt8](repeating: 0, count: 64)
        let options = UInt32(FSOPT_ATTR_CMN_EXTENDED) | UInt32(FSOPT_NOFOLLOW)
        let status = buffer.withUnsafeMutableBytes { raw in
            withUnsafeMutablePointer(to: &request) {
                getattrlist(path, UnsafeMutableRawPointer($0), raw.baseAddress, raw.count, options)
            }
        }
        guard status == 0 else { return nil }
        return buffer.withUnsafeBytes { raw -> (UInt64, Int64)? in
            let returned = raw.loadUnaligned(fromByteOffset: 4, as: attribute_set_t.self)
            guard returned.forkattr & privateSizeBit != 0, returned.forkattr & cloneIDBit != 0 else { return nil }
            let offset = 4 + MemoryLayout<attribute_set_t>.size
            let privateSize = raw.loadUnaligned(fromByteOffset: offset, as: Int64.self)
            let cloneID = raw.loadUnaligned(fromByteOffset: offset + 8, as: UInt64.self)
            return (cloneID, privateSize)
        }
    }

    /// Al massimo quattro letture insieme: di più non accelera un disco e
    /// rallenta tutto il resto del Mac.
    private static func concurrently(_ items: [Candidate], isCancelled: @escaping () -> Bool,
                                     _ work: @escaping (Candidate) -> Void) {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 4
        queue.qualityOfService = .utility
        for item in items {
            queue.addOperation { if !isCancelled() { work(item) } }
        }
        queue.waitUntilAllOperationsAreFinished()
    }
}

// MARK: - Memoria delle impronte

/// Impronte già calcolate, riusate finché percorso, dimensione, data di
/// modifica, dispositivo e inode restano identici. Una sola differenza e
/// l'impronta si ricalcola.
final class HashCache {
    enum Kind: UInt8 { case sample = 1, full = 2 }

    struct Key: Hashable { let path: String; let kind: UInt8 }
    struct Value { let size: Int64; let modified: Int64; let device: UInt64; let inode: UInt64
                   let digest: String; var used: Double }

    static let maxEntries = 500_000
    static let shared = HashCache(storage: URL(fileURLWithPath: ScanSupport.home)
        .appendingPathComponent("Library/Application Support/Ammugghia/hashes-v1.bin"))

    private let storage: URL
    private let lock = NSLock()
    private var entries: [Key: Value] = [:]
    private var loaded = false

    init(storage: URL) { self.storage = storage }

    func lookup(_ c: ContentDuplicateScanner.Candidate, kind: Kind) -> String? {
        lock.lock(); defer { lock.unlock() }
        load()
        let key = Key(path: c.path, kind: kind.rawValue)
        guard var value = entries[key], value.size == c.size, value.modified == c.modified,
              value.device == c.device, value.inode == c.inode else { return nil }
        value.used = Date().timeIntervalSince1970
        entries[key] = value
        return value.digest
    }

    func store(_ c: ContentDuplicateScanner.Candidate, kind: Kind, _ digest: String) {
        lock.lock(); defer { lock.unlock() }
        load()
        entries[Key(path: c.path, kind: kind.rawValue)] = Value(
            size: c.size, modified: c.modified, device: c.device, inode: c.inode,
            digest: digest, used: Date().timeIntervalSince1970)
    }

    func save() {
        lock.lock(); defer { lock.unlock() }
        guard loaded else { return }
        // Si tengono le più usate di recente.
        if entries.count > HashCache.maxEntries {
            let keep = entries.sorted { $0.value.used > $1.value.used }.prefix(HashCache.maxEntries)
            entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        var w = IndexCodec.Writer()
        w.u32(0x414D_4843); w.u32(1); w.u32(UInt32(entries.count))   // "AMHC"
        for (key, value) in entries {
            w.string(key.path); w.u8(key.kind); w.i64(value.size); w.i64(value.modified)
            w.u64(value.device); w.u64(value.inode); w.string(value.digest); w.f64(value.used)
        }
        w.u32(0x414D_4843)
        try? FileManager.default.createDirectory(at: storage.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? w.data.write(to: storage, options: .atomic)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: storage) else { return }
        var r = IndexCodec.Reader(data: data)
        guard r.u32() == 0x414D_4843, r.u32() == 1, let count = r.u32() else { return }
        var decoded: [Key: Value] = [:]
        for _ in 0..<count {
            guard let path = r.string(), let kind = r.u8(), let size = r.i64(), let modified = r.i64(),
                  let device = r.u64(), let inode = r.u64(), let digest = r.string(), let used = r.f64()
            else { return }
            decoded[Key(path: path, kind: kind)] = Value(size: size, modified: modified, device: device,
                                                         inode: inode, digest: digest, used: used)
        }
        // Un file troncato o corrotto si ignora per intero.
        guard r.u32() == 0x414D_4843, r.isAtEnd else { return }
        entries = decoded
    }
}
