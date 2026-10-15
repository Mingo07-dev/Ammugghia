import Foundation

/// Artefatti di build dentro le cartelle di progetto: `node_modules`, `Pods`,
/// `.dart_tool`, `build`. Sono la voce che le Impostazioni di macOS contano
/// come «Documenti», gonfiando quella categoria di decine di GB.
enum ProjectArtifactScanner {

    /// Cartelle in cui cercare i progetti. Esclude di proposito `~/Library`.
    static var searchRoots: [String] {
        let home = ScanSupport.home
        return [
            home + "/Developer", home + "/Projects", home + "/Progetti",
            home + "/src", home + "/code", home + "/Code", home + "/work",
            home + "/Documents", home + "/Desktop", home + "/repos", home + "/git",
        ].filter(ScanSupport.isDirectory)
    }

    /// Un artefatto trovato, con il progetto a cui appartiene.
    struct Artifact {
        let path: String
        let kind: String
        let projectName: String
        let projectPath: String
        var size: Int64 = 0
        let modified: Date?
    }

    static func find(in roots: [String], olderThanDays: Int) -> [Artifact] {
        guard let findTool = Shell.which("find") else { return [] }
        var found: [Artifact] = []

        for root in roots {
            // `-prune` impedisce di scendere dentro un artefatto già trovato:
            // senza, i node_modules annidati moltiplicherebbero i risultati.
            var args = [root, "-maxdepth", "6", "-type", "d", "("]
            for (i, name) in PathGuard.projectArtifactNames.sorted().enumerated() {
                args += (i == 0 ? [] : ["-o"]) + ["-name", name]
            }
            args += [")", "-prune", "-print"]
            let r = Shell.run(findTool, args, timeout: 180)
            for line in r.stdout.split(separator: "\n") {
                let path = String(line)
                guard !path.isEmpty else { continue }
                // Doppia verifica: la cartella padre deve essere un progetto
                // riconoscibile, altrimenti "build" potrebbe essere sorgente.
                do { try PathGuard.validateProjectArtifact(path) } catch { continue }

                let parent = (path as NSString).deletingLastPathComponent
                let modified = ScanSupport.modificationDate(path)
                if let modified, Date().timeIntervalSince(modified) < Double(olderThanDays) * 86_400 {
                    continue
                }
                found.append(Artifact(
                    path: path,
                    kind: (path as NSString).lastPathComponent,
                    projectName: (parent as NSString).lastPathComponent,
                    projectPath: parent,
                    modified: modified))
            }
        }

        // Dimensioni in blocco.
        let sizes = Shell.diskSizes(found.map(\.path))
        for i in found.indices { found[i].size = sizes[found[i].path] ?? 0 }
        return found.filter { $0.size >= 20_000_000 }.sorted { $0.size > $1.size }
    }

    static func scan(olderThanDays: Int = 60) -> [CleanupItem] {
        let artifacts = find(in: searchRoots, olderThanDays: olderThanDays)
        // Raggruppati per progetto: è così che l'utente ci ragiona.
        let byProject = Dictionary(grouping: artifacts, by: \.projectPath)

        return byProject.map { projectPath, list -> CleanupItem in
            let name = (projectPath as NSString).lastPathComponent
            let total = list.reduce(0) { $0 + $1.size }
            let kinds = list.map(\.kind).joined(separator: ", ")
            let newest = list.compactMap(\.modified).max()
            let sizes = Dictionary(uniqueKeysWithValues: list.map { ($0.path, $0.size) })
            return CleanupItem(
                title: String(localized: "Progetto «\(name)»: \(kinds)"),
                detail: String(localized: "Dipendenze e prodotti di compilazione del progetto in \(projectPath). Il codice sorgente NON viene toccato: solo le cartelle rigenerabili."),
                consequence: String(localized: "Per lavorare di nuovo sul progetto serve reinstallare le dipendenze (`npm install`, `pod install`, `flutter pub get`…) e ricompilare (`cargo build`, `swift build`…)."),
                action: .removeProjectArtifacts(list.map(\.path)),
                risk: .redownload, size: total, perPathSize: sizes,
                lastUsed: newest, preselect: false)
        }.sorted { $0.size > $1.size }
    }
}

/// File grossi e non aperti da tempo. Non elimina nulla per conto proprio:
/// serve a rendere visibile quello che le Impostazioni nascondono.
enum LargeFileScanner {

    struct BigFile {
        let path: String
        var size: Int64
        let lastUsed: Date?
    }

    static func scan(minimumBytes: Int64 = 500_000_000, limit: Int = 60) -> [CleanupItem] {
        guard let findTool = Shell.which("find") else { return [] }
        let home = ScanSupport.home
        let megabytes = max(1, minimumBytes / 1_000_000)

        // Solo le cartelle dei documenti dell'utente: le aree di sistema e
        // ~/Library sono coperte dalle altre categorie.
        let roots = [
            home + "/Documents", home + "/Desktop", home + "/Downloads",
            home + "/Movies", home + "/Developer", home + "/Projects",
        ].filter(ScanSupport.isDirectory)
        guard !roots.isEmpty else { return [] }

        var files: [BigFile] = []
        // Con un indice aggiornabile in modo parziale bastano pochi secondi;
        // se servirebbe un'analisi completa si usa `find`, per non allungare
        // l'analisi generale. In entrambi i casi l'elenco è solo informativo.
        if DiskIndexStore.shared.refresh(allowFull: false) != nil {
            files = DiskIndexStore.shared.largeFiles(under: roots, minimum: minimumBytes)
                .map { BigFile(path: $0.path, size: $0.size, lastUsed: nil) }
        } else {
            for root in roots {
                let r = Shell.run(findTool, [root, "-type", "f", "-size", "+\(megabytes)M", "-print"], timeout: 180)
                for line in r.stdout.split(separator: "\n") {
                    let path = String(line)
                    guard !path.isEmpty else { continue }
                    // Un file solo su iCloud ha la dimensione dichiarata ma non
                    // occupa spazio qui: mostrarlo fra i «grandi» sarebbe falso.
                    if FileIdentity.isDataless(path) { continue }
                    let attrs = try? FileManager.default.attributesOfItem(atPath: path)
                    let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                    files.append(BigFile(path: path, size: size, lastUsed: nil))
                }
            }
        }

        let exclusions = ExclusionSet.current()
        files.removeAll { exclusions.excludes($0.path, scope: .largeFiles) }
        files.sort { $0.size > $1.size }
        files = Array(files.prefix(limit))

        return files.map { file in
            // La data d'ultimo uso solo per i file mostrati: `mdls` è lento.
            let used = Shell.lastUsedDate(file.path)
            let name = (file.path as NSString).lastPathComponent
            return CleanupItem(
                title: name,
                detail: String(localized: "File di \(ByteFormat.string(file.size)) in \((file.path as NSString).deletingLastPathComponent)."),
                consequence: String(localized: "Questo software non elimina i file nelle tue cartelle di documenti: usa «Mostra nel Finder» e decidi tu. L'elenco serve solo a rendere visibile ciò che occupa spazio."),
                action: .revealOnly([file.path]),
                risk: .userData, size: file.size,
                perPathSize: [file.path: file.size],
                lastUsed: used, preselect: false)
        }
    }
}
