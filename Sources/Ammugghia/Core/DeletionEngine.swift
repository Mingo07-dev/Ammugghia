import Foundation
import AppKit

enum RemovalMode: String, CaseIterable, Identifiable {
    /// Reversibile: i file restano nel Cestino. Non libera spazio finché
    /// il Cestino non viene svuotato, ma è la modalità predefinita per
    /// tutto ciò che non è pura cache.
    case trash
    /// Irreversibile, libera spazio subito.
    case permanent

    var id: String { rawValue }

    var label: String {
        switch self {
        case .trash: return "Sposta nel Cestino"
        case .permanent: return "Elimina definitivamente"
        }
    }

    /// Etichetta compatta per il selettore nella barra dei comandi: quelle
    /// complete non stanno nella larghezza disponibile.
    var shortLabel: String {
        switch self {
        case .trash: return "Cestino"
        case .permanent: return "Definitiva"
        }
    }

    var caveat: String {
        switch self {
        case .trash:
            return "Reversibile: puoi ripristinare tutto dal Cestino. Lo spazio si libera solo quando svuoti il Cestino."
        case .permanent:
            return "Irreversibile. Lo spazio si libera immediatamente."
        }
    }
}

/// Esegue il piano di pulizia. Ogni operazione è indipendente: se una
/// fallisce le altre proseguono e l'errore finisce nel registro.
final class DeletionEngine {

    private let fileManager = FileManager.default
    private(set) var log: [String] = []
    private let logURL: URL?

    init() {
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/Ammugghia", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        self.logURL = dir.appendingPathComponent("pulizia-\(stamp).log")
    }

    private func note(_ line: String) {
        let stamped = "[\(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .medium))] \(line)"
        log.append(stamped)
        if let logURL {
            if let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile()
                handle.write((stamped + "\n").data(using: .utf8) ?? Data())
                try? handle.close()
            } else {
                try? (stamped + "\n").write(to: logURL, atomically: true, encoding: .utf8)
            }
        }
    }

    var logFilePath: String? { logURL?.path }

    // MARK: - Esecuzione

    /// - Parameters:
    ///   - dryRun: valida tutto e scrive nel registro senza toccare il disco.
    ///   - progress: chiamata sul thread corrente con (fatti, totale, titolo).
    func execute(items: [CleanupItem],
                 mode: RemovalMode,
                 dryRun: Bool,
                 progress: ((Int, Int, String) -> Void)? = nil) -> [DeletionOutcome] {

        note(dryRun
             ? "=== SIMULAZIONE: nessun file verrà modificato (\(items.count) operazioni) ==="
             : "=== ESECUZIONE: \(items.count) operazioni, modalità \(mode.label) ===")

        var outcomes: [DeletionOutcome] = []
        for (index, item) in items.enumerated() {
            progress?(index, items.count, item.title)
            outcomes.append(perform(item, mode: mode, dryRun: dryRun))
        }
        progress?(items.count, items.count, "Completato")

        let freed = outcomes.filter(\.succeeded).reduce(0) { $0 + $1.freed }
        note("=== Fine: \(outcomes.filter(\.succeeded).count)/\(items.count) riuscite, "
             + "\(ByteFormat.string(freed)) \(dryRun ? "liberabili" : "liberati") ===")
        return outcomes
    }

    private func perform(_ item: CleanupItem, mode: RemovalMode, dryRun: Bool) -> DeletionOutcome {
        switch item.action {

        case .revealOnly:
            // Non dovrebbe arrivare qui: l'interfaccia non ne permette la
            // selezione. Il rifiuto esplicito è la seconda barriera.
            return skip(item, "elemento solo informativo: questo software non lo elimina")

        case .removePaths(let paths):
            return removeValidated(item, paths: paths, mode: mode, dryRun: dryRun,
                                   validator: { try PathGuard.validate($0) })

        case .removeProjectArtifacts(let paths):
            return removeValidated(item, paths: paths, mode: mode, dryRun: dryRun,
                                   validator: { try PathGuard.validateProjectArtifact($0) })

        case .removeApp(let appPath, let related):
            return removeApp(item, appPath: appPath, related: related, mode: mode, dryRun: dryRun)

        case .simctlDeleteDevice(let udid):
            return runSimctl(item, ["simctl", "delete", udid], dryRun: dryRun)

        case .simctlEraseDevice(let udid):
            return runSimctl(item, ["simctl", "erase", udid], dryRun: dryRun)

        case .simctlDeleteRuntime(let id):
            return runSimctl(item, ["simctl", "runtime", "delete", id], dryRun: dryRun,
                             successNote: "La cancellazione del runtime è asincrona: "
                                        + "lo spazio si libera entro qualche minuto.")

        case .shell(let tool, let args):
            guard let path = Shell.which(tool) else {
                return skip(item, "strumento «\(tool)» non trovato nel sistema")
            }
            if dryRun {
                note("SIMULAZIONE  \(([tool] + args).joined(separator: " "))")
                return DeletionOutcome(title: item.title, succeeded: true, skipped: false,
                                       message: "Simulato", freed: item.size)
            }
            let r = Shell.run(path, args, timeout: 300)
            note("\(r.ok ? "OK" : "ERRORE") \(([tool] + args).joined(separator: " ")) → \(r.ok ? "ok" : r.stderr)")
            return DeletionOutcome(title: item.title, succeeded: r.ok, skipped: false,
                                   message: r.ok ? "Eseguito" : shortError(r.stderr.isEmpty ? r.stdout : r.stderr),
                                   freed: r.ok ? item.size : 0)

        case .privileged(let command, let paths):
            // Anche le operazioni amministrative passano da PathGuard: la
            // password non è un lasciapassare.
            for p in paths {
                do { try PathGuard.validate(p) }
                catch { return fail(item, "controllo di sicurezza non superato — \(error.localizedDescription)") }
            }
            if dryRun {
                note("SIMULAZIONE  sudo \(command)")
                return DeletionOutcome(title: item.title, succeeded: true, skipped: false,
                                       message: "Simulato (richiederebbe la password)", freed: item.size)
            }
            let r = Shell.runAsAdmin(command)
            note("\(r.ok ? "OK" : "ERRORE") sudo \(command) → \(r.ok ? "ok" : r.stderr)")
            if !r.ok && r.stderr.contains("-128") {
                return skip(item, "annullato: password non inserita")
            }
            return DeletionOutcome(title: item.title, succeeded: r.ok, skipped: false,
                                   message: r.ok ? "Eseguito con privilegi di amministratore" : shortError(r.stderr),
                                   freed: r.ok ? item.size : 0)

        case .dockerPrune(let kind):
            guard let docker = Shell.which("docker") else {
                return skip(item, "docker non installato")
            }
            if dryRun {
                note("SIMULAZIONE  \(kind.command)")
                return DeletionOutcome(title: item.title, succeeded: true, skipped: false,
                                       message: "Simulato", freed: item.size)
            }
            let r = Shell.run(docker, kind.args, timeout: 300)
            note("\(r.ok ? "OK" : "ERRORE") \(kind.command) → \(r.ok ? "ok" : r.stderr)")
            return DeletionOutcome(title: item.title, succeeded: r.ok, skipped: false,
                                   message: r.ok ? "Eseguito" : shortError(r.stderr),
                                   freed: r.ok ? item.size : 0)
        }
    }

    // MARK: - Rimozione file

    private func removeValidated(_ item: CleanupItem,
                                 paths: [String],
                                 mode: RemovalMode,
                                 dryRun: Bool,
                                 validator: (String) throws -> Void) -> DeletionOutcome {
        var freed: Int64 = 0
        var errors: [String] = []
        var done = 0
        var alreadyGone = 0

        for path in paths {
            do {
                try validator(path)
            } catch PathGuard.Violation.doesNotExist {
                alreadyGone += 1
                continue
            } catch {
                errors.append(error.localizedDescription)
                note("RIFIUTATO \(path) — \(error.localizedDescription)")
                continue
            }

            let size = item.perPathSize[path] ?? Shell.diskSize(path)

            if dryRun {
                note("SIMULAZIONE  \(mode == .trash ? "cestino" : "elimina") \(path) (\(ByteFormat.string(size)))")
                freed += size
                done += 1
                continue
            }

            do {
                switch mode {
                case .trash:
                    var resulting: NSURL?
                    try fileManager.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &resulting)
                case .permanent:
                    try fileManager.removeItem(atPath: path)
                }
                freed += size
                done += 1
                note("OK  \(mode == .trash ? "nel cestino" : "eliminato") \(path) (\(ByteFormat.string(size)))")
            } catch {
                let msg = friendlyFileError(error, path: path)
                errors.append(msg)
                note("ERRORE \(path) — \(msg)")
            }
        }

        if done == 0 && alreadyGone > 0 && errors.isEmpty {
            return skip(item, "già eliminato in precedenza")
        }
        let succeeded = errors.isEmpty && done > 0
        var message = succeeded
            ? "\(done) element\(done == 1 ? "o" : "i") \(dryRun ? "da rimuovere" : (mode == .trash ? "nel Cestino" : "eliminati"))"
            : errors.joined(separator: "; ")
        if alreadyGone > 0 && succeeded {
            message += ", \(alreadyGone) già assent\(alreadyGone == 1 ? "e" : "i")"
        }
        return DeletionOutcome(title: item.title, succeeded: succeeded, skipped: false,
                               message: message, freed: freed)
    }

    private func removeApp(_ item: CleanupItem,
                           appPath: String,
                           related: [String],
                           mode: RemovalMode,
                           dryRun: Bool) -> DeletionOutcome {
        // Un'app in esecuzione non va rimossa: file aperti, helper attivi e
        // preferenze riscritte alla chiusura vanificherebbero la pulizia.
        if AppRuntime.isRunning(bundlePath: appPath) {
            return skip(item, "l'applicazione è in esecuzione: chiudila e riprova")
        }
        do {
            try PathGuard.validateApp(appPath)
        } catch {
            return fail(item, error.localizedDescription)
        }

        var freed: Int64 = 0
        var errors: [String] = []

        // Prima i dati collegati, poi il bundle: se qualcosa va storto a metà
        // l'app resta al suo posto e la situazione è più facile da capire.
        for path in related {
            do {
                try PathGuard.validate(path)
                let size = item.perPathSize[path] ?? Shell.diskSize(path)
                if dryRun {
                    note("SIMULAZIONE  dati collegati: \(path) (\(ByteFormat.string(size)))")
                    freed += size
                    continue
                }
                switch mode {
                case .trash:
                    var out: NSURL?
                    try fileManager.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &out)
                case .permanent:
                    try fileManager.removeItem(atPath: path)
                }
                freed += size
                note("OK  dati collegati \(path) (\(ByteFormat.string(size)))")
            } catch PathGuard.Violation.doesNotExist {
                continue
            } catch {
                let msg = friendlyFileError(error, path: path)
                errors.append(msg)
                note("ERRORE dati collegati \(path) — \(msg)")
            }
        }

        let appSize = item.perPathSize[appPath] ?? Shell.diskSize(appPath)
        if dryRun {
            note("SIMULAZIONE  applicazione: \(appPath) (\(ByteFormat.string(appSize)))")
            freed += appSize
        } else {
            do {
                switch mode {
                case .trash:
                    var out: NSURL?
                    try fileManager.trashItem(at: URL(fileURLWithPath: appPath), resultingItemURL: &out)
                case .permanent:
                    try fileManager.removeItem(atPath: appPath)
                }
                freed += appSize
                note("OK  applicazione \(appPath) (\(ByteFormat.string(appSize)))")
            } catch {
                let msg = friendlyFileError(error, path: appPath)
                errors.append("bundle applicazione: \(msg)")
                note("ERRORE applicazione \(appPath) — \(msg)")
            }
        }

        return DeletionOutcome(title: item.title, succeeded: errors.isEmpty, skipped: false,
                               message: errors.isEmpty
                                ? "Applicazione e \(related.count) element\(related.count == 1 ? "o" : "i") collegat\(related.count == 1 ? "o" : "i") rimossi"
                                : errors.joined(separator: "; "),
                               freed: freed)
    }

    private func runSimctl(_ item: CleanupItem,
                           _ args: [String],
                           dryRun: Bool,
                           successNote: String? = nil) -> DeletionOutcome {
        guard let xcrun = Shell.which("xcrun") else {
            return skip(item, "xcrun non disponibile: Xcode o gli strumenti a riga di comando non sono installati")
        }
        if dryRun {
            note("SIMULAZIONE  xcrun \(args.joined(separator: " "))")
            return DeletionOutcome(title: item.title, succeeded: true, skipped: false,
                                   message: "Simulato", freed: item.size)
        }
        let r = Shell.run(xcrun, args, timeout: 300)
        note("\(r.ok ? "OK" : "ERRORE") xcrun \(args.joined(separator: " ")) → \(r.ok ? "ok" : r.stderr)")
        return DeletionOutcome(title: item.title, succeeded: r.ok, skipped: false,
                               message: r.ok ? (successNote ?? "Eseguito") : shortError(r.stderr),
                               freed: r.ok ? item.size : 0)
    }

    // MARK: - Backup

    /// Archivia i dati di un'app prima di eliminarli. Usato quando la casella
    /// «crea backup» è attiva e sono stati rilevati dati dell'utente.
    func backup(paths: [String], appName: String) -> (ok: Bool, message: String, archivePath: String?) {
        guard let ditto = Shell.which("ditto") else {
            return (false, "strumento «ditto» non disponibile", nil)
        }
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd-HHmm"
        let safeName = appName.replacingOccurrences(of: "/", with: "-")
        let dest = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Documents/Ammugghia Backup", isDirectory: true)
        try? fileManager.createDirectory(at: dest, withIntermediateDirectories: true)
        let archive = dest.appendingPathComponent("\(safeName)-\(stamp.string(from: Date())).zip")

        let existing = paths.filter { fileManager.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return (true, "nessun dato da archiviare", nil) }

        // Cartella temporanea con la struttura da comprimere.
        let staging = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ammugghia-backup-\(UUID().uuidString)", isDirectory: true)
        try? fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        for (i, p) in existing.enumerated() {
            let name = "\(i)-" + (p as NSString).lastPathComponent
            try? fileManager.copyItem(atPath: p, toPath: staging.appendingPathComponent(name).path)
        }
        let r = Shell.run(ditto, ["-c", "-k", "--sequesterRsrc", staging.path, archive.path], timeout: 600)
        if r.ok {
            note("BACKUP  \(archive.path)")
            return (true, "Backup creato in \(archive.path)", archive.path)
        }
        note("BACKUP FALLITO  \(shortError(r.stderr))")
        return (false, shortError(r.stderr), nil)
    }

    // MARK: - Utilità

    private func skip(_ item: CleanupItem, _ why: String) -> DeletionOutcome {
        note("SALTATO \(item.title) — \(why)")
        return DeletionOutcome(title: item.title, succeeded: false, skipped: true,
                               message: why, freed: 0)
    }

    private func fail(_ item: CleanupItem, _ why: String) -> DeletionOutcome {
        note("ERRORE \(item.title) — \(why)")
        return DeletionOutcome(title: item.title, succeeded: false, skipped: false,
                               message: why, freed: 0)
    }

    private func shortError(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "errore non specificato" }
        return t.split(separator: "\n").prefix(2).joined(separator: " ")
    }

    /// Traduce gli errori di FileManager in indicazioni utili, in particolare
    /// il caso "Accesso completo al disco" che su macOS recenti è la causa
    /// più frequente di fallimento.
    private func friendlyFileError(_ error: Error, path: String) -> String {
        let ns = error as NSError
        switch ns.code {
        case NSFileWriteNoPermissionError, NSFileReadNoPermissionError:
            return "permesso negato. Concedi «Accesso completo al disco» a Ammugghia in "
                 + "Impostazioni di Sistema → Privacy e sicurezza, oppure elimina questo elemento a mano."
        case NSFileWriteVolumeReadOnlyError:
            return "il volume è in sola lettura"
        case NSFileNoSuchFileError:
            return "già rimosso"
        default:
            return ns.localizedDescription
        }
    }
}

/// Stato di esecuzione delle applicazioni.
enum AppRuntime {
    static func isRunning(bundlePath: String) -> Bool {
        let normalized = PathGuard.normalize(bundlePath)
        return NSWorkspace.shared.runningApplications.contains { app in
            guard let url = app.bundleURL else { return false }
            return PathGuard.normalize(url.path) == normalized
        }
    }

    static func isRunning(bundleID: String) -> Bool {
        guard !bundleID.isEmpty else { return false }
        return NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }
}
