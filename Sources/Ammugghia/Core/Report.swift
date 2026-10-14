import Foundation

/// `Ammugghia --report` esegue tutte le analisi e stampa il risultato senza
/// aprire l'interfaccia e senza eliminare niente. Utile per controllare da
/// terminale, o per verificare che gli scanner funzionino.
enum Report {

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
