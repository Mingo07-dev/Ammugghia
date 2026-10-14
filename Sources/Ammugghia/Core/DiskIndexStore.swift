import Foundation

/// L'indice del disco salvato fra un'analisi e l'altra.
///
/// Serve **solo a mostrare**: la mappa, l'elenco dei file grandi. Nessun
/// elemento eliminabile prende dimensioni o percorsi da qui, quindi un indice
/// sbagliato può al più mostrare un numero sbagliato, mai far eliminare
/// qualcosa. Anche così, al minimo dubbio l'indice si butta e si rifà da zero.
final class DiskIndexStore {

    struct Report {
        enum Mode: Equatable {
            case full(reason: String)
            case incremental(changedDirectories: Int)
        }
        let mode: Mode
        let duration: TimeInterval
        let finishedAt: Date
    }

    /// FSEvents non segnala un file che cresce mentre resta aperto (database,
    /// log, dischi virtuali): lo segnala alla chiusura. I file grandi si
    /// ricontrollano a ogni aggiornamento, ma un file piccolo che cresce può
    /// restare indietro. Un'analisi completa al giorno ne limita il ritardo,
    /// e costa poche decine di secondi.
    static let maxAge: TimeInterval = 86_400

    /// Scarto ammesso sui byte di una cartella nella verifica a campione,
    /// purché file e sottocartelle coincidano: lo spazio allocato dei file
    /// appena scritti si assesta qualche secondo dopo, senza nuovi eventi.
    static func withinSettlingTolerance(_ a: Int64, _ b: Int64) -> Bool {
        abs(a - b) <= max(1_048_576, max(a, b) / 100)
    }

    static var defaultRoots: [String] {
        [ScanSupport.home, "/Applications", "/Library", "/opt/homebrew"]
            .filter(ScanSupport.isDirectory)
    }

    static let shared = DiskIndexStore(
        roots: defaultRoots,
        storage: URL(fileURLWithPath: ScanSupport.home)
            .appendingPathComponent("Library/Application Support/Ammugghia/index-v1.bin"))

    let roots: [String]
    let storage: URL
    let sampleSize: Int

    /// Una sola operazione alla volta: chi legge mentre l'indice si aggiorna
    /// aspetta, invece di vedere un albero a metà.
    private let lock = NSLock()
    private var header: IndexCodec.Header?
    private var trees: [IndexNode] = []
    private var loaded = false
    private(set) var lastReport: Report?

    /// Le esclusioni vengono lette a ogni aggiornamento; iniettabili per l'autotest.
    let exclusions: () -> ExclusionSet

    init(roots: [String], storage: URL, sampleSize: Int = 20,
         exclusions: @escaping () -> ExclusionSet = { ExclusionSet.current() }) {
        self.exclusions = exclusions
        // Percorsi canonici: FSEvents riporta quelli reali (`/private/var/…`),
        // e un evento che non corrisponde a nessuna radice andrebbe perso.
        self.roots = roots.map { PathGuard.realPath($0) ?? PathGuard.normalize($0) }
        self.storage = storage
        self.sampleSize = sampleSize
    }

    // MARK: Stato

    var hasIndex: Bool {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        return header?.complete == true
    }

    /// Data dell'ultima analisi completa.
    var lastFullScan: Date? {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        return header.map { Date(timeIntervalSince1970: $0.createdAt) }
    }

    // MARK: Aggiornamento

    /// Porta l'indice allo stato attuale del disco.
    /// - Parameter allowFull: se `false` e serve un'analisi completa,
    ///   restituisce `nil` senza farla (chi chiama ripiega su altro).
    func refresh(forceFull: Bool = false, allowFull: Bool = true,
                 progress: ((Int) -> Void)? = nil) -> Report? {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        let start = Date()

        let reason = forceFull ? "analisi da zero richiesta" : fullScanReason()
        if let reason {
            guard allowFull else { return nil }
            return fullScan(reason: reason, start: start, progress: progress)
        }

        guard var current = header else { return nil }
        let exclusionSet = exclusions()
        let excluded: (String) -> Bool = { exclusionSet.excludes($0, scope: .map) }
        let now = ChangeTracker.currentEventID()
        switch ChangeTracker.changes(since: current.eventID, in: roots) {
        case .mustRescan(let why):
            guard allowFull else { return nil }
            return fullScan(reason: why, start: start, progress: progress)

        case .changes(let directories, let recursive):
            // Due tipi di rilettura: quella ricorsiva copre tutto il
            // sottoalbero, quella diretta solo la cartella stessa. Dopo aver
            // riletto in modo diretto una cartella, le sue sottocartelle
            // cambiate vanno rilette comunque.
            var rescannedTrees = Set<String>()
            var rescannedDirs = Set<String>()
            func covered(_ path: String) -> Bool {
                rescannedTrees.contains { path == $0 || path.hasPrefix($0 + "/") }
            }
            for path in recursive.sorted(by: { $0.count < $1.count }) {
                guard let (index, node, nodePath, _) = locate(path), !covered(nodePath) else { continue }
                IndexScanner(device: current.roots[index].device, isExcluded: excluded).scanTree(node, path: nodePath)
                rescannedTrees.insert(nodePath)
            }
            // Dalle cartelle più vicine alla radice: una cartella nuova viene
            // esplorata per intero una volta sola e poi considerata coperta.
            for path in directories.sorted(by: { $0.count < $1.count }) {
                guard let (index, node, nodePath, _) = locate(path),
                      !covered(nodePath), !rescannedDirs.contains(nodePath) else { continue }
                let scanner = IndexScanner(device: current.roots[index].device, isExcluded: excluded)
                let before = Set(node.children.map(\.name))
                scanner.refreshDirect(node, path: nodePath)
                rescannedDirs.insert(nodePath)
                for child in node.children where !before.contains(child.name) {
                    rescannedTrees.insert(nodePath + "/" + child.name)
                }
            }
            // File grandi già noti: si ricontrolla lo spazio occupato, perché
            // un disco virtuale o un database può crescere di GB senza che
            // FSEvents lo segnali finché resta aperto.
            var grown: [(Int, IndexNode, String)] = []
            for (index, tree) in trees.enumerated() {
                tree.walk(path: roots[index]) { node, path in
                    guard !rescannedDirs.contains(path), !covered(path) else { return }
                    if node.largeFiles.contains(where: { DiskIndexStore.currentShare(path + "/" + $0.name) != $0.size }) {
                        grown.append((index, node, path))
                    }
                }
            }
            for (index, node, path) in grown {
                IndexScanner(device: current.roots[index].device, isExcluded: excluded).refreshDirect(node, path: path)
                rescannedDirs.insert(path)
            }
            for tree in trees { tree.aggregate() }
            let touched = rescannedTrees.union(rescannedDirs)

            // Cintura e bretelle: alcune cartelle che FSEvents dà per
            // invariate vengono rilette davvero. Una sola differenza e
            // l'indice viene rifatto da zero.
            if let mismatch = verifySample(excludingTrees: rescannedTrees, directories: rescannedDirs) {
                guard allowFull else { return nil }
                return fullScan(reason: "verifica a campione non superata (\(mismatch))",
                                start: start, progress: progress)
            }

            current.eventID = now
            header = current
            save()
            let report = Report(mode: .incremental(changedDirectories: touched.count),
                                duration: Date().timeIntervalSince(start), finishedAt: Date())
            lastReport = report
            return report
        }
    }

    /// Motivo per cui l'indice salvato non è una base affidabile, oppure `nil`.
    private func fullScanReason() -> String? {
        guard let header, header.complete else { return "nessuna analisi completa precedente" }
        guard header.roots.map(\.path) == roots, trees.count == roots.count else {
            return "cartelle da analizzare cambiate"
        }
        if Date().timeIntervalSince1970 - header.createdAt > DiskIndexStore.maxAge {
            return "ultima analisi completa più vecchia di un giorno"
        }
        if header.osVersion != ProcessInfo.processInfo.operatingSystemVersionString {
            return "macOS è stato aggiornato"
        }
        if header.exclusions != exclusions().mapFingerprint {
            return "le esclusioni della mappa sono cambiate"
        }
        if header.fullDiskAccess != DiskIndexStore.hasFullDiskAccess() {
            return "i permessi di accesso al disco sono cambiati"
        }
        for root in header.roots {
            guard let device = BulkEnumerator.device(of: root.path), device == root.device else {
                return "il volume di \(root.path) è cambiato"
            }
            if DiskIndexStore.volumeUUID(root.path) != root.volumeUUID {
                return "il volume di \(root.path) è cambiato"
            }
            if ChangeTracker.databaseUUID(device: device) != root.eventsUUID {
                return "la storia delle modifiche del volume è stata azzerata"
            }
        }
        return nil
    }

    private func fullScan(reason: String, start: Date, progress: ((Int) -> Void)?) -> Report {
        // Il numero di evento si prende *prima* di leggere: ciò che cambia
        // durante la lettura verrà riletto al prossimo aggiornamento.
        let eventID = ChangeTracker.currentEventID()
        let exclusionSet = exclusions()
        var rootHeaders: [IndexCodec.RootHeader] = []
        var newTrees: [IndexNode] = []
        var total = 0
        for root in roots {
            let device = BulkEnumerator.device(of: root) ?? 0
            let node = IndexNode(name: root)
            let scanner = IndexScanner(device: device, isExcluded: { exclusionSet.excludes($0, scope: .map) }) {
                count in progress?(total + count)
            }
            scanner.scanTree(node, path: root)
            total += scanner.directoriesScanned
            node.aggregate()
            newTrees.append(node)
            rootHeaders.append(IndexCodec.RootHeader(
                path: root, device: device,
                volumeUUID: DiskIndexStore.volumeUUID(root) ?? "",
                eventsUUID: ChangeTracker.databaseUUID(device: device) ?? ""))
        }
        trees = newTrees
        header = IndexCodec.Header(
            complete: true, eventID: eventID, createdAt: Date().timeIntervalSince1970,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            fullDiskAccess: DiskIndexStore.hasFullDiskAccess(),
            exclusions: exclusionSet.mapFingerprint, roots: rootHeaders)
        save()
        let report = Report(mode: .full(reason: reason), duration: Date().timeIntervalSince(start),
                            finishedAt: Date())
        lastReport = report
        return report
    }

    /// Rilegge alcune cartelle a caso fra quelle non toccate e le confronta
    /// con l'indice. Restituisce la prima che non corrisponde.
    private func verifySample(excludingTrees trees: Set<String>, directories: Set<String>) -> String? {
        var candidates: [(IndexNode, String, UInt64)] = []
        for (index, tree) in self.trees.enumerated() {
            let device = header?.roots[index].device ?? 0
            tree.walk(path: roots[index]) { node, path in
                if !directories.contains(path),
                   !trees.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                    candidates.append((node, path, device))
                }
            }
        }
        for (node, path, device) in candidates.shuffled().prefix(sampleSize) {
            let probe = IndexNode(name: node.name)
            let set = exclusions()
            let scanner = IndexScanner(device: device, isExcluded: { set.excludes($0, scope: .map) })
            scanner.readDirect(probe, path: path, keepingChildren: false)
            let same = probe.unreadable == node.unreadable
                && DiskIndexStore.withinSettlingTolerance(probe.ownBytes, node.ownBytes)
                && probe.ownFiles == node.ownFiles
                && Set(probe.children.map(\.name)) == Set(node.children.map(\.name))
            if !same { return path }
        }
        return nil
    }

    // MARK: Lettura per l'interfaccia

    struct Entry: Identifiable, Hashable {
        enum Kind: Hashable { case directory, file, otherFiles, group }
        let path: String
        let name: String
        let size: Int64
        let files: Int
        let modified: Int64
        let kind: Kind
        let unreadable: Bool
        var id: String { "\(kind)|\(path)" }
        var isNavigable: Bool { kind == .directory && !unreadable }
    }

    /// Il contenuto di un livello della mappa. `nil` come percorso indica il
    /// livello più alto, con le cartelle analizzate.
    func level(at path: String?) -> [Entry]? {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        guard header?.complete == true else { return nil }
        guard let path else {
            return zip(roots, trees).map { root, tree in
                Entry(path: root, name: root == ScanSupport.home ? "Cartella utente" : root,
                      size: tree.totalBytes, files: tree.totalFiles, modified: tree.modified,
                      kind: .directory, unreadable: tree.unreadable)
            }.sorted { $0.size > $1.size }
        }
        guard let (_, node, nodePath, exact) = locate(path), exact else { return nil }
        var entries = node.children.map { child in
            Entry(path: nodePath + "/" + child.name, name: child.name, size: child.totalBytes,
                  files: child.totalFiles, modified: child.modified, kind: .directory,
                  unreadable: child.unreadable)
        }
        entries += node.largeFiles.map { file in
            Entry(path: nodePath + "/" + file.name, name: file.name, size: file.size, files: 1,
                  modified: file.modified, kind: .file, unreadable: false)
        }
        let rest = node.ownBytes - node.largeFiles.reduce(0) { $0 + $1.size }
        let restCount = node.ownFiles - node.largeFiles.count
        if rest > 0 && restCount > 0 {
            entries.append(Entry(path: nodePath, name: Plural.of(restCount, "altro file", "altri file"),
                                 size: rest, files: restCount, modified: node.modified,
                                 kind: .otherFiles, unreadable: false))
        }
        return entries.sorted { $0.size > $1.size }
    }

    /// Dati di un singolo percorso, per l'intestazione della mappa.
    func summary(at path: String) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        guard let (_, node, nodePath, exact) = locate(path), exact else { return nil }
        return Entry(path: nodePath, name: (nodePath as NSString).lastPathComponent,
                     size: node.totalBytes, files: node.totalFiles, modified: node.modified,
                     kind: .directory, unreadable: node.unreadable)
    }

    /// File sopra la soglia nelle cartelle indicate, dal più grande.
    func largeFiles(under folders: [String], minimum: Int64) -> [(path: String, size: Int64)] {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        var result: [(String, Int64)] = []
        for folder in folders {
            guard let (_, node, nodePath, exact) = locate(folder), exact else { continue }
            node.walk(path: nodePath) { n, p in
                for file in n.largeFiles where file.size >= minimum {
                    result.append((p + "/" + file.name, file.size))
                }
            }
        }
        return result.sorted { $0.1 > $1.1 }
    }

    /// Fotografia dell'indice per il confronto nell'autotest.
    func fingerprint() -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        var result: [String: String] = [:]
        for (index, tree) in trees.enumerated() {
            tree.walk(path: roots[index]) { node, path in
                result[path] = "\(node.ownBytes)|\(node.ownFiles)|\(node.unreadable)|"
                    + node.children.map(\.name).sorted().joined(separator: ",")
            }
        }
        return result
    }

    // MARK: Interni

    /// Il nodo più profondo che corrisponde al percorso, con il suo percorso
    /// e se corrisponde esattamente.
    private func locate(_ raw: String) -> (Int, IndexNode, String, Bool)? {
        let path = ChangeTracker.normalize(raw)
        for (index, root) in roots.enumerated() where index < trees.count {
            guard path == root || path.hasPrefix(root + "/") else { continue }
            var node = trees[index]
            var nodePath = root
            let rest = path.dropFirst(root.count).split(separator: "/")
            for component in rest {
                guard let child = node.child(named: String(component)) else {
                    return (index, node, nodePath, false)
                }
                node = child
                nodePath += "/" + component
            }
            return (index, node, nodePath, true)
        }
        return nil
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: storage),
              let (decodedHeader, decodedTrees) = IndexCodec.decode(data) else { return }
        header = decodedHeader
        trees = decodedTrees
        for tree in trees { tree.aggregate() }
    }

    private func save() {
        guard let header else { return }
        let data = IndexCodec.encode(header: header, trees: trees)
        try? FileManager.default.createDirectory(at: storage.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: storage, options: .atomic)
    }

    /// Spazio attribuito oggi a un file, con lo stesso criterio dell'indice.
    static func currentShare(_ path: String) -> Int64 {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return -1 }
        if info.st_flags & UInt32(SF_DATALESS) != 0 { return 0 }
        let allocated = Int64(info.st_blocks) * 512
        return info.st_nlink > 1 ? allocated / Int64(info.st_nlink) : allocated
    }

    static func volumeUUID(_ path: String) -> String? {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
    }

    /// Con «Accesso completo al disco» cartelle prima illeggibili diventano
    /// leggibili senza che FSEvents lo segnali: se il permesso cambia, l'indice
    /// va rifatto.
    static func hasFullDiskAccess() -> Bool {
        BulkEnumerator.entries(of: ScanSupport.home + "/Library/Safari") != nil
            || BulkEnumerator.entries(of: ScanSupport.home + "/Library/Mail") != nil
    }
}
