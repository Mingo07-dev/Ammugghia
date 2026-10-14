import Foundation

// MARK: - Nodi

/// Un file grande ricordato dall'indice, per la mappa e per «File grandi».
struct IndexedFile: Hashable {
    let name: String
    let size: Int64
    let modified: Int64
}

/// Una cartella dell'indice. Si registrano solo le cartelle, con i totali dei
/// file che contengono direttamente e i file sopra la soglia: tenere ogni
/// singolo file costerebbe centinaia di MB di memoria.
final class IndexNode {
    let name: String
    var modified: Int64 = 0
    var ownBytes: Int64 = 0
    var ownFiles: Int = 0
    var largeFiles: [IndexedFile] = []
    var children: [IndexNode] = []
    /// Cartella che non è stato possibile leggere: mai contata come vuota.
    var unreadable = false
    /// Totali di tutto il sottoalbero, ricalcolati da `aggregate()`.
    var totalBytes: Int64 = 0
    var totalFiles: Int = 0

    init(name: String) { self.name = name }

    @discardableResult
    func aggregate() -> (Int64, Int) {
        var bytes = ownBytes
        var files = ownFiles
        for child in children {
            let (b, f) = child.aggregate()
            bytes += b
            files += f
        }
        totalBytes = bytes
        totalFiles = files
        return (bytes, files)
    }

    func child(named name: String) -> IndexNode? {
        children.first { $0.name == name }
    }

    /// Tutte le cartelle del sottoalbero con il loro percorso.
    func walk(path: String, _ visit: (IndexNode, String) -> Void) {
        visit(self, path)
        for child in children { child.walk(path: path + "/" + child.name, visit) }
    }
}

// MARK: - Scansione

/// Costruisce o aggiorna i nodi leggendo il disco, con più cartelle in
/// parallelo.
final class IndexScanner {
    static let largeFileThreshold: Int64 = 50_000_000

    let device: UInt64
    /// Percorsi da non leggere (esclusioni dell'utente per la mappa).
    let isExcluded: (String) -> Bool
    private let queue: OperationQueue
    private let counterLock = NSLock()
    private var scanned = 0
    private let progress: ((Int) -> Void)?

    init(device: UInt64, isExcluded: @escaping (String) -> Bool = { _ in false },
         progress: ((Int) -> Void)? = nil) {
        self.device = device
        self.isExcluded = isExcluded
        self.progress = progress
        queue = OperationQueue()
        queue.maxConcurrentOperationCount = min(8, max(2, ProcessInfo.processInfo.activeProcessorCount))
        queue.qualityOfService = .userInitiated
    }

    /// Legge il contenuto diretto della cartella. Restituisce le
    /// sottocartelle da esplorare: sullo stesso volume, non collegamenti, non
    /// segnaposto iCloud. Entrare in una cartella non scaricata farebbe
    /// scaricare il suo elenco dalla rete.
    @discardableResult
    func readDirect(_ node: IndexNode, path: String, keepingChildren: Bool) -> [(IndexNode, String)] {
        guard let entries = BulkEnumerator.entries(of: path) else {
            node.unreadable = true
            node.ownBytes = 0
            node.ownFiles = 0
            node.largeFiles = []
            if !keepingChildren { node.children = [] }
            return []
        }
        node.unreadable = false
        var bytes: Int64 = 0
        var files = 0
        var large: [IndexedFile] = []
        var directories: [BulkEntry] = []
        for entry in entries {
            if isExcluded(path + "/" + entry.name) { continue }
            if entry.isDirectory {
                if entry.device == device && !entry.isDataless { directories.append(entry) }
            } else if entry.isRegularFile {
                let share = entry.share
                bytes += share
                files += 1
                if share >= IndexScanner.largeFileThreshold {
                    large.append(IndexedFile(name: entry.name, size: share, modified: entry.modified))
                }
            }
        }
        node.ownBytes = bytes
        node.ownFiles = files
        node.largeFiles = large.sorted { $0.size > $1.size }

        // Le sottocartelle già note restano con il loro contenuto; quelle
        // nuove vanno esplorate, quelle sparite tolte.
        let existing = keepingChildren
            ? Dictionary(node.children.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
            : [:]
        var children: [IndexNode] = []
        var toExplore: [(IndexNode, String)] = []
        for entry in directories {
            if let kept = existing[entry.name] {
                kept.modified = entry.modified
                children.append(kept)
            } else {
                let child = IndexNode(name: entry.name)
                child.modified = entry.modified
                children.append(child)
                toExplore.append((child, path + "/" + entry.name))
            }
        }
        node.children = children

        counterLock.lock()
        scanned += 1
        let count = scanned
        counterLock.unlock()
        if count % 500 == 0 { progress?(count) }
        return toExplore
    }

    /// Esplora tutto il sottoalbero in parallelo.
    func scanTree(_ node: IndexNode, path: String) {
        node.children = []
        enqueue(node, path: path)
        queue.waitUntilAllOperationsAreFinished()
    }

    /// Rilegge solo il contenuto diretto ed esplora le eventuali cartelle nuove.
    func refreshDirect(_ node: IndexNode, path: String) {
        let fresh = readDirect(node, path: path, keepingChildren: true)
        for (child, childPath) in fresh { enqueue(child, path: childPath) }
        queue.waitUntilAllOperationsAreFinished()
    }

    private func enqueue(_ node: IndexNode, path: String) {
        queue.addOperation { [self] in
            for (child, childPath) in readDirect(node, path: path, keepingChildren: false) {
                enqueue(child, path: childPath)
            }
        }
    }

    var directoriesScanned: Int {
        counterLock.lock()
        defer { counterLock.unlock() }
        return scanned
    }
}

// MARK: - Formato su disco

/// Formato binario semplice e versionato. Qualunque anomalia in lettura
/// restituisce `nil`: un indice dubbio si butta, non si ripara.
enum IndexCodec {
    static let magic: UInt32 = 0x414D_4958   // "AMIX"
    // 2: aggiunte le esclusioni della mappa nell'intestazione.
    static let version: UInt32 = 2

    struct Header {
        var complete: Bool
        var eventID: UInt64
        var createdAt: Double
        var osVersion: String
        var fullDiskAccess: Bool
        var exclusions: String
        var roots: [RootHeader]
    }

    struct RootHeader {
        var path: String
        var device: UInt64
        var volumeUUID: String
        var eventsUUID: String
    }

    // Scrittura

    static func encode(header: Header, trees: [IndexNode]) -> Data {
        var w = Writer()
        w.u32(magic); w.u32(version)
        w.u8(header.complete ? 1 : 0)
        w.u64(header.eventID)
        w.f64(header.createdAt)
        w.string(header.osVersion)
        w.u8(header.fullDiskAccess ? 1 : 0)
        w.string(header.exclusions)
        w.u32(UInt32(header.roots.count))
        for (root, tree) in zip(header.roots, trees) {
            w.string(root.path); w.u64(root.device)
            w.string(root.volumeUUID); w.string(root.eventsUUID)
            write(tree, &w)
        }
        w.u32(magic)   // chiusura: un file troncato non passa
        return w.data
    }

    private static func write(_ node: IndexNode, _ w: inout Writer) {
        w.string(node.name)
        w.i64(node.modified); w.i64(node.ownBytes); w.i64(Int64(node.ownFiles))
        w.u8(node.unreadable ? 1 : 0)
        w.u32(UInt32(node.largeFiles.count))
        for f in node.largeFiles { w.string(f.name); w.i64(f.size); w.i64(f.modified) }
        w.u32(UInt32(node.children.count))
        for child in node.children { write(child, &w) }
    }

    // Lettura

    static func decode(_ data: Data) -> (Header, [IndexNode])? {
        var r = Reader(data: data)
        guard r.u32() == magic, r.u32() == version,
              let complete = r.u8(), let eventID = r.u64(), let createdAt = r.f64(),
              let os = r.string(), let fda = r.u8(), let exclusions = r.string(),
              let count = r.u32(), count < 64 else { return nil }
        var roots: [RootHeader] = []
        var trees: [IndexNode] = []
        for _ in 0..<count {
            guard let path = r.string(), let device = r.u64(), let volume = r.string(),
                  let events = r.string(), let tree = read(&r, depth: 0) else { return nil }
            roots.append(RootHeader(path: path, device: device, volumeUUID: volume, eventsUUID: events))
            trees.append(tree)
        }
        guard r.u32() == magic, r.isAtEnd else { return nil }
        return (Header(complete: complete == 1, eventID: eventID, createdAt: createdAt,
                       osVersion: os, fullDiskAccess: fda == 1, exclusions: exclusions,
                       roots: roots), trees)
    }

    private static func read(_ r: inout Reader, depth: Int) -> IndexNode? {
        guard depth < 512, let name = r.string(), let modified = r.i64(), let own = r.i64(),
              let files = r.i64(), let unreadable = r.u8(), let largeCount = r.u32() else { return nil }
        let node = IndexNode(name: name)
        node.modified = modified; node.ownBytes = own; node.ownFiles = Int(files)
        node.unreadable = unreadable == 1
        for _ in 0..<largeCount {
            guard let n = r.string(), let s = r.i64(), let m = r.i64() else { return nil }
            node.largeFiles.append(IndexedFile(name: n, size: s, modified: m))
        }
        guard let childCount = r.u32() else { return nil }
        node.children.reserveCapacity(Int(childCount))
        for _ in 0..<childCount {
            guard let child = read(&r, depth: depth + 1) else { return nil }
            node.children.append(child)
        }
        return node
    }

    struct Writer {
        var data = Data()
        mutating func u8(_ v: UInt8) { data.append(v) }
        mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        mutating func i64(_ v: Int64) { u64(UInt64(bitPattern: v)) }
        mutating func f64(_ v: Double) { u64(v.bitPattern) }
        mutating func string(_ s: String) {
            let bytes = Array(s.utf8)
            u32(UInt32(bytes.count)); data.append(contentsOf: bytes)
        }
    }

    struct Reader {
        let data: Data
        var offset = 0
        var isAtEnd: Bool { offset == data.count }

        private mutating func take(_ n: Int) -> Data? {
            guard n >= 0, offset + n <= data.count else { return nil }
            let start = data.startIndex + offset
            offset += n
            return data[start..<start + n]
        }
        mutating func u8() -> UInt8? { take(1)?.first }
        mutating func u32() -> UInt32? {
            take(4).map { $0.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) } }
        }
        mutating func u64() -> UInt64? {
            take(8).map { $0.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) } }
        }
        mutating func i64() -> Int64? { u64().map { Int64(bitPattern: $0) } }
        mutating func f64() -> Double? { u64().map { Double(bitPattern: $0) } }
        mutating func string() -> String? {
            guard let n = u32(), n < 1 << 20, let bytes = take(Int(n)) else { return nil }
            return String(data: bytes, encoding: .utf8)
        }
    }
}
