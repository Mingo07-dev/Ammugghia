import Foundation

/// `Ammugghia --report` esegue tutte le analisi e stampa il risultato senza
/// aprire l'interfaccia e senza eliminare niente. Utile per controllare da
/// terminale, o per verificare che gli scanner funzionino.
enum Report {

    /// `Ammugghia --index`: aggiorna l'indice del disco e ne riassume il contenuto.
    static func runIndex() -> Int32 {
        let store = DiskIndexStore.shared
        print("Ammugghia — indice del disco (\(store.storage.path))")
        guard let report = store.refresh(progress: { n in
            FileHandle.standardError.write("\r\(n) cartelle…".data(using: .utf8)!)
        }) else { return 1 }
        FileHandle.standardError.write("\n".data(using: .utf8)!)
        switch report.mode {
        case .full(let reason): print("Analisi completa (\(reason))")
        case .incremental(let n): print("Aggiornamento parziale: \(Plural.of(n, "cartella riletta", "cartelle rilette"))")
        }
        print(String(format: "Durata: %.1f s", report.duration))
        for entry in store.level(at: nil) ?? [] {
            print("  \(ByteFormat.string(entry.size).padding(toLength: 10, withPad: " ", startingAt: 0)) \(entry.path)")
        }
        return 0
    }

    /// `Ammugghia --duplicates`: cerca i file duplicati e li elenca. Legge i
    /// file, non ne modifica nessuno.
    static func runDuplicates() -> Int32 {
        let roots = ContentDuplicateScanner.defaultRoots
        print("Ammugghia — file duplicati in \(roots.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))")
        let start = Date()
        let groups = ContentDuplicateScanner.find(roots: roots, minimumSize: 1_000_000, cache: HashCache.shared) { p in
            FileHandle.standardError.write("\r\(p.stage) \(p.done)/\(p.total)        ".data(using: .utf8)!)
        }
        FileHandle.standardError.write("\n".data(using: .utf8)!)
        let total = groups.reduce(0) { $0 + $1.recoverable }
        print("\(Plural.of(groups.count, "gruppo", "gruppi")), \(ByteFormat.string(total)) recuperabili, "
              + String(format: "%.1f s", Date().timeIntervalSince(start)))
        for group in groups.prefix(15) {
            print("  \(ByteFormat.string(group.recoverable).padding(toLength: 10, withPad: " ", startingAt: 0)) "
                  + "\(group.files.count) × \(ByteFormat.string(group.size))\(group.hasClones ? " (cloni APFS)" : "")")
            for file in group.files { print("      \(file.path)") }
        }
        return 0
    }

    /// `Ammugghia --startup`: elenca gli elementi d'avvio senza modificarli.
    static func runStartup() -> Int32 {
        let items = StartupScanner.scan()
        print("Ammugghia — elementi d'avvio (\(StartupScanner.appleServiceCount()) servizi di macOS esclusi)")
        for item in items {
            var flags: [String] = []
            if item.isDisabled { flags.append("disattivato") }
            if item.isLoaded { flags.append("caricato") }
            if item.isOrphan { flags.append("ORFANO") }
            if item.runAtLoad { flags.append("all'avvio") }
            if item.keepAlive { flags.append("sempre attivo") }
            if let i = item.interval { flags.append("ogni \(i / 60) min") }
            print("  [\(item.domain.label)] \(item.displayName) — \(item.label)")
            print("      \(flags.joined(separator: ", "))  ·  firma: \(item.signer ?? "sconosciuta")")
            if let p = item.program { print("      \(p)") }
        }
        return 0
    }

    /// `Ammugghia --verify-index`: aggiorna l'indice e lo confronta con
    /// un'analisi completa fatta adesso. Serve a provare l'aggiornamento parziale.
    static func runVerifyIndex() -> Int32 {
        guard let report = DiskIndexStore.shared.refresh() else { return 1 }
        print("Indice: \(report.mode) in \(String(format: "%.1f", report.duration)) s")
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory() + "ammugghia-verifica-indice.bin")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let reference = DiskIndexStore(roots: DiskIndexStore.shared.roots, storage: scratch)
        guard let full = reference.refresh(forceFull: true) else { return 1 }
        print("Riferimento: analisi completa in \(String(format: "%.1f", full.duration)) s")
        let a = DiskIndexStore.shared.fingerprint()
        let b = reference.fingerprint()
        let differing = Set(a.keys).union(b.keys).filter { a[$0] != b[$0] }
        print("Cartelle confrontate: \(b.count), diverse: \(differing.count)")
        guard !differing.isEmpty else { return 0 }

        // Le cartelle scritte in continuo (log, database delle app) cambiano
        // durante l'analisi di riferimento. Una differenza è spiegata se, dopo
        // un nuovo aggiornamento, l'indice corrisponde al disco adesso.
        _ = DiskIndexStore.shared.refresh()
        let now = DiskIndexStore.shared.fingerprint()
        var unexplained: [String] = []
        for path in differing.sorted() {
            let probe = IndexNode(name: (path as NSString).lastPathComponent)
            IndexScanner(device: BulkEnumerator.device(of: path) ?? 0)
                .readDirect(probe, path: path, keepingChildren: false)
            let disk = FileManager.default.fileExists(atPath: path)
                ? "\(probe.ownBytes)|\(probe.ownFiles)|\(probe.unreadable)|"
                    + probe.children.map(\.name).sorted().joined(separator: ",")
                : nil
            // Stessi file e sottocartelle, byte quasi uguali: è lo spazio
            // allocato dei file ancora aperti o appena scritti.
            func parts(_ s: String?) -> (Int64, String)? {
                guard let s, let bar = s.firstIndex(of: "|"), let bytes = Int64(s[..<bar]) else { return nil }
                return (bytes, String(s[s.index(after: bar)...]))
            }
            let settling: Bool = {
                guard let a = parts(now[path]), let b = parts(disk) else { return false }
                return a.1 == b.1 && DiskIndexStore.withinSettlingTolerance(a.0, b.0)
            }()
            let verdict = now[path] == disk ? "modificata durante la verifica"
                : (settling ? "solo spazio in assestamento (file aperto o appena scritto)" : "NON SPIEGATA")
            if now[path] != disk && !settling { unexplained.append(path) }
            print("  ≠ \(path) — \(verdict)")
            if now[path] != disk { print("      indice: \(now[path]?.prefix(80) ?? "assente")\n      disco:  \(disk?.prefix(80) ?? "assente")") }
        }
        print(unexplained.isEmpty
              ? "Nessuna differenza strutturale: solo modifiche in corso o spazio in assestamento."
              : "\(Plural.of(unexplained.count, "differenza non spiegata", "differenze non spiegate")).")
        return unexplained.isEmpty ? 0 : 1
    }

    static func run() -> Int32 {
        let disk = DiskInfo.current()
        print("Ammugghia — analisi (nessun file verrà modificato)")
        print(String(repeating: "═", count: 78))
        print("Disco: \(ByteFormat.string(disk.free)) liberi su \(ByteFormat.string(disk.total)) "
              + "(\(Int(disk.usedFraction * 100))% occupato)")
        print("")

        let scanners: [(String, CategoryID)] = [
            ("Xcode", .xcode),
            ("Simulatori iOS", .simulators),
            ("Android", .android),
            ("Gestori di pacchetti", .packageManagers),
            ("Browser", .browsers),
            ("App", .appCaches),
            ("Modelli AI", .aiModels),
            ("Residui di app", .orphans),
            ("Sistema", .system),
            ("Sfondi dinamici", .wallpapers),
            ("Docker", .docker),
            ("Artefatti dei progetti", .projectArtifacts),
            ("File grandi (solo informativo)", .largeFiles),
        ]

        var grandTotal: Int64 = 0
        var safeTotal: Int64 = 0

        for (name, categoryID) in scanners {
            let presence = Relevance.detect(categoryID)
            // Le categorie assenti si segnalano in una riga, senza elencare
            // nulla: è lo stesso criterio con cui l'interfaccia le nasconde.
            if case .absent(let detail) = presence {
                print("── \(name) — nascosta: \(detail)")
                print("")
                continue
            }
            if case .residual(let detail) = presence {
                print("── \(name) — RESIDUI: \(detail)")
            }
            let items = AppModel.scanner(for: categoryID)()
            // Una sola alternativa per gruppo esclusivo, altrimenti i totali
            // contano due volte lo stesso spazio.
            var seenGroups = Set<String>()
            let unique = items.filter { item in
                guard let group = item.exclusiveGroup else { return true }
                return seenGroups.insert(group).inserted
            }
            let total = unique.filter { !$0.action.isInformationalOnly }.reduce(0) { $0 + $1.size }
            grandTotal += total
            safeTotal += unique.filter { $0.risk == .safe }.reduce(0) { $0 + $1.size }

            print("── \(name) — \(ByteFormat.string(total)) in \(Plural.of(items.count, "voce", "voci"))")
            if let note = AppModel.note(for: categoryID) {
                print("   ℹ︎ \(note)")
            }
            for item in items.prefix(12) {
                let flag: String
                switch item.risk {
                case .safe: flag = "sicuro     "
                case .redownload: flag = "riscaricare"
                case .userData: flag = "DATI UTENTE"
                }
                let info = item.action.isInformationalOnly ? " [solo lettura]" : ""
                let admin = item.action.needsAdmin ? " [password]" : ""
                print("   \(flag)  \(ByteFormat.string(item.size).padding(toLength: 9, withPad: " ", startingAt: 0))  \(item.title)\(info)\(admin)")
                if let w = item.warning {
                    print("              ⚠ \(w.prefix(150))")
                }
            }
            if items.count > 12 { print("   … e altre \(items.count - 12) voci") }
            print("")
        }

        // Versioni multiple.
        let groups = DuplicateScanner.scan()
        print(String(repeating: "═", count: 78))
        print("VERSIONI MULTIPLE — \(groups.count) grupp\(groups.count == 1 ? "o" : "i")")
        print("")
        var versionSavings: Int64 = 0
        for group in groups {
            print("── \(group.title) — \(group.entries.count) versioni, \(ByteFormat.string(group.totalSize))")
            print("   \(group.suggestion)")
            for entry in group.entries {
                let keep = entry.recommendedToKeep ? "TIENI  " : "       "
                print("   \(keep)\(ByteFormat.string(entry.size).padding(toLength: 9, withPad: " ", startingAt: 0))  "
                      + "\(entry.label)  —  \(DateFormat.relative(entry.lastUsed))")
                if let note = entry.note { print("            \(note)") }
            }
            versionSavings += group.entries.filter { !$0.recommendedToKeep }.reduce(0) { $0 + $1.size }
            print("")
        }

        // Applicazioni.
        let apps = AppInventory.applications()
        let removable = apps.filter { !$0.isProtected }
        print(String(repeating: "═", count: 78))
        print("APPLICAZIONI — \(apps.count) totali, \(removable.count) disinstallabili")
        print("Le 15 più grandi:")
        for app in removable.prefix(15) {
            print("   \(ByteFormat.string(app.size).padding(toLength: 9, withPad: " ", startingAt: 0))  "
                  + "\(app.name.padding(toLength: 28, withPad: " ", startingAt: 0))  \(app.bundleID)")
        }
        print("")

        print(String(repeating: "═", count: 78))
        print("RIEPILOGO")
        print("  Eliminabile per categoria:     \(ByteFormat.string(grandTotal))")
        print("  di cui cache sicure:           \(ByteFormat.string(safeTotal))")
        print("  Versioni duplicate superflue:  \(ByteFormat.string(versionSavings))")
        print("  Totale potenziale:             \(ByteFormat.string(grandTotal + versionSavings))")
        print("")
        print("Nessun file è stato modificato. Usa l'interfaccia grafica per scegliere cosa eliminare.")
        return 0
    }
}
