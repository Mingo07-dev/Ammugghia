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
        case .trash: return String(localized: "Sposta nel Cestino")
        case .permanent: return String(localized: "Elimina definitivamente")
        }
    }

    /// Etichetta compatta per il selettore nella barra dei comandi: quelle
    /// complete non stanno nella larghezza disponibile.
    var shortLabel: String {
        switch self {
        case .trash: return String(localized: "Cestino")
        case .permanent: return String(localized: "Definitiva")
        }
    }

    var caveat: String {
        switch self {
        case .trash:
            return String(localized: "Reversibile: puoi ripristinare tutto dal Cestino. Lo spazio si libera solo quando svuoti il Cestino.")
        case .permanent:
            return String(localized: "Irreversibile. Lo spazio si libera immediatamente.")
        }
    }
}

/// Esegue il piano di pulizia. Ogni operazione è indipendente: se una
/// fallisce le altre proseguono e l'errore finisce nel registro.
final class DeletionEngine {

    private let fileManager = FileManager.default
    private(set) var log: [String] = []
    private let logURL: URL?
    /// Dice se un'app (per bundle id) è in esecuzione. Iniettabile perché
    /// l'autotest deve poter simulare un'app aperta senza aprirne una.
    var isAppRunning: (String) -> Bool = { AppRuntime.isRunning(bundleID: $0) }
    /// Esclusioni dell'utente: terza barriera, dopo l'interfaccia e
    /// `PathGuard`. Fotografate a ogni esecuzione.
    var exclusions: ExclusionSet?
    private var activeExclusions = ExclusionSet.empty
    /// Ciò che l'operazione corrente ha spostato nel Cestino.
    private var trashedNow: [String: String] = [:]

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

    /// Esito di un comando esterno nel registro.
    private func noteResult(_ r: Shell.Result, _ command: String) {
        note(r.ok ? String(localized: "OK  \(command)") : String(localized: "ERRORE \(command) → \(r.stderr)"))
    }

    /// Scrive nel registro operazioni che non sono eliminazioni (es. la
    /// disattivazione di un elemento d'avvio): tutto ciò che il software
    /// modifica deve lasciare traccia nello stesso posto.
    func record(_ line: String) { note(line) }

    // MARK: - Esecuzione

    /// - Parameters:
    ///   - dryRun: valida tutto e scrive nel registro senza toccare il disco.
    ///   - progress: chiamata sul thread corrente con (fatti, totale, titolo).
    func execute(items: [CleanupItem],
                 mode: RemovalMode,
                 dryRun: Bool,
                 progress: ((Int, Int, String) -> Void)? = nil) -> [DeletionOutcome] {

        note(dryRun
             ? String(localized: "=== SIMULAZIONE: nessun file verrà modificato (\(items.count) operazioni) ===")
             : String(localized: "=== ESECUZIONE: \(items.count) operazioni, modalità \(mode.label) ==="))

        activeExclusions = exclusions ?? ExclusionSet.current()
        var outcomes: [DeletionOutcome] = []
        for (index, item) in items.enumerated() {
            progress?(index, items.count, item.title)
            trashedNow = [:]
            var outcome = perform(item, mode: mode, dryRun: dryRun)
            outcome.trashed = trashedNow
            outcomes.append(outcome)
        }
        progress?(items.count, items.count, String(localized: "Completato"))

        let freed = outcomes.filter(\.succeeded).reduce(0) { $0 + $1.freed }
        note(String(localized: "=== Fine: \(outcomes.filter(\.succeeded).count)/\(items.count) riuscite, ")
             + (dryRun ? String(localized: "\(ByteFormat.string(freed)) liberabili ===")
                       : String(localized: "\(ByteFormat.string(freed)) liberati ===")))
        return outcomes
    }

    private func perform(_ item: CleanupItem, mode: RemovalMode, dryRun: Bool) -> DeletionOutcome {
        // Controllato qui e non solo nel foglio di conferma: fra la conferma e
        // l'esecuzione l'utente può aver riaperto l'app. Vale anche per la
        // simulazione, che deve riportare ciò che accadrebbe davvero.
        let running = item.requiredStoppedApps.filter(isAppRunning)
        if !running.isEmpty {
            let names = running.map { AppRuntime.displayName(bundleID: $0) }.joined(separator: ", ")
            return skip(item, running.count == 1
                ? String(localized: "\(names) è in esecuzione: chiudi l'app e riprova")
                : String(localized: "\(names) sono in esecuzione: chiudi le app e riprova"))
        }

        switch item.action {

        case .revealOnly:
            // Non dovrebbe arrivare qui: l'interfaccia non ne permette la
            // selezione. Il rifiuto esplicito è la seconda barriera.
            return skip(item, String(localized: "elemento solo informativo: questo software non lo elimina"))

        case .removePaths(let paths):
            return removeValidated(item, paths: paths, mode: mode, dryRun: dryRun,
                                   validator: { try PathGuard.validate($0, expected: item.identities[$0]) })

        case .removeProjectArtifacts(let paths):
            return removeValidated(item, paths: paths, mode: mode, dryRun: dryRun,
                                   validator: { try PathGuard.validateProjectArtifact($0, expected: item.identities[$0]) })

        case .removeAgedFiles(let root, let days, let files):
            return removeAgedFiles(item, root: root, days: days, files: files, mode: mode, dryRun: dryRun)

        case .removeApp(let appPath, let related):
            return removeApp(item, appPath: appPath, related: related, mode: mode, dryRun: dryRun)

        case .simctlDeleteDevice(let udid):
            return runSimctl(item, ["simctl", "delete", udid], dryRun: dryRun)

        case .simctlEraseDevice(let udid):
            return runSimctl(item, ["simctl", "erase", udid], dryRun: dryRun)

        case .simctlDeleteRuntime(let id):
            return runSimctl(item, ["simctl", "runtime", "delete", id], dryRun: dryRun,
                             successNote: String(localized: "La cancellazione del runtime è asincrona: ")
                                        + String(localized: "lo spazio si libera entro qualche minuto."))

        case .shell(let tool, let args):
            guard let path = Shell.which(tool) else {
                return skip(item, String(localized: "strumento «\(tool)» non trovato nel sistema"))
            }
            if dryRun {
                note(String(localized: "SIMULAZIONE  \(([tool] + args).joined(separator: " "))"))
                return DeletionOutcome(title: item.title, succeeded: true, skipped: false,
                                       message: String(localized: "Simulato"), freed: item.size)
            }
            let r = Shell.run(path, args, timeout: 300)
            noteResult(r, ([tool] + args).joined(separator: " "))
            return DeletionOutcome(title: item.title, succeeded: r.ok, skipped: false,
                                   message: r.ok ? String(localized: "Eseguito") : shortError(r.stderr.isEmpty ? r.stdout : r.stderr),
                                   freed: r.ok ? item.size : 0)

        case .privileged(let command, let paths):
            // Anche le operazioni amministrative passano da PathGuard: la
            // password non è un lasciapassare.
            for p in paths {
                if activeExclusions.blocksDeletion(of: p) {
                    return fail(item, String(localized: "il percorso rientra nelle tue esclusioni: \(p)"))
                }
                do { try PathGuard.validate(p, expected: item.identities[p]) }
                catch { return fail(item, String(localized: "controllo di sicurezza non superato — \(error.localizedDescription)")) }
            }
            if dryRun {
                note(String(localized: "SIMULAZIONE  sudo \(command)"))
                return DeletionOutcome(title: item.title, succeeded: true, skipped: false,
                                       message: String(localized: "Simulato (richiederebbe la password)"), freed: item.size)
            }
            let r = Shell.runAsAdmin(command)
            noteResult(r, "sudo \(command)")
            if !r.ok && r.stderr.contains("-128") {
                return skip(item, String(localized: "annullato: password non inserita"))
            }
            return DeletionOutcome(title: item.title, succeeded: r.ok, skipped: false,
                                   message: r.ok ? String(localized: "Eseguito con privilegi di amministratore") : shortError(r.stderr),
                                   freed: r.ok ? item.size : 0)

        case .dockerPrune(let kind):
            guard let docker = Shell.which("docker") else {
                return skip(item, String(localized: "docker non installato"))
            }
            if dryRun {
                note("SIMULAZIONE  \(kind.command)")
                return DeletionOutcome(title: item.title, succeeded: true, skipped: false,
                                       message: String(localized: "Simulato"), freed: item.size)
            }
            let r = Shell.run(docker, kind.args, timeout: 300)
            noteResult(r, kind.command)
            return DeletionOutcome(title: item.title, succeeded: r.ok, skipped: false,
                                   message: r.ok ? String(localized: "Eseguito") : shortError(r.stderr),
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
            if activeExclusions.blocksDeletion(of: path) {
                errors.append(String(localized: "escluso dalle tue esclusioni: \(path)"))
                note(String(localized: "RIFIUTATO \(path) — rientra nelle esclusioni impostate dall'utente"))
                continue
            }
            do {
                try validator(path)
            } catch PathGuard.Violation.doesNotExist {
                alreadyGone += 1
                continue
            } catch {
                errors.append(error.localizedDescription)
                note(String(localized: "RIFIUTATO \(path) — \(error.localizedDescription)"))
                continue
            }

            let size = item.perPathSize[path] ?? Shell.diskSize(path)

            if dryRun {
                note(mode == .trash ? String(localized: "SIMULAZIONE  cestino \(path) (\(ByteFormat.string(size)))")
                                    : String(localized: "SIMULAZIONE  elimina \(path) (\(ByteFormat.string(size)))"))
                freed += size
                done += 1
                continue
            }

            do {
                switch mode {
                case .trash:
                    var resulting: NSURL?
                    try fileManager.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &resulting)
                    if let resulting, let moved = resulting.path { trashedNow[path] = moved }
                case .permanent:
                    try fileManager.removeItem(atPath: path)
                }
                freed += size
                done += 1
                note(mode == .trash ? String(localized: "OK  nel cestino \(path) (\(ByteFormat.string(size)))")
                                    : String(localized: "OK  eliminato \(path) (\(ByteFormat.string(size)))"))
            } catch {
                let msg = friendlyFileError(error, path: path)
                errors.append(msg)
                note(String(localized: "ERRORE \(path) — \(msg)"))
            }
        }

        if done == 0 && alreadyGone > 0 && errors.isEmpty {
            return skip(item, String(localized: "già eliminato in precedenza"))
        }
        let succeeded = errors.isEmpty && done > 0
        var message = succeeded
            ? (dryRun ? String(localized: "\(Plural.of(done, "elemento", "elementi")) da rimuovere")
               : mode == .trash ? String(localized: "\(Plural.of(done, "elemento", "elementi")) nel Cestino")
               : String(localized: "\(Plural.of(done, "elemento eliminato", "elementi eliminati"))"))
            : errors.joined(separator: "; ")
        if alreadyGone > 0 && succeeded {
            message += String(localized: ", \(Plural.of(alreadyGone, "già assente", "già assenti"))")
        }
        return DeletionOutcome(title: item.title, succeeded: succeeded, skipped: false,
                               message: message, freed: freed)
    }

    /// File temporanei: ognuno viene rivalidato adesso, non solo durante
    /// l'analisi. Quelli usati nel frattempo vengono saltati senza errore:
    /// è il comportamento atteso, non un guasto.
    private func removeAgedFiles(_ item: CleanupItem, root: String, days: Int,
                                 files: [String: AgedFile], mode: RemovalMode,
                                 dryRun: Bool) -> DeletionOutcome {
        var freed: Int64 = 0
        var removed = 0
        var skipped = 0
        var errors: [String] = []

        for (path, file) in files.sorted(by: { $0.key < $1.key }) {
            if activeExclusions.blocksDeletion(of: path) {
                skipped += 1
                continue
            }
            do {
                try PathGuard.validateAgedFile(path, root: root, olderThanDays: days,
                                               expected: file.identity)
            } catch {
                skipped += 1
                note(String(localized: "SALTATO \(error.localizedDescription)"))
                continue
            }
            if dryRun {
                note(mode == .trash ? String(localized: "SIMULAZIONE  cestino \(path) (\(ByteFormat.string(file.size)))")
                                    : String(localized: "SIMULAZIONE  elimina \(path) (\(ByteFormat.string(file.size)))"))
                freed += file.size
                removed += 1
                continue
            }
            do {
                switch mode {
                case .trash:
                    var resulting: NSURL?
                    try fileManager.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &resulting)
                    if let resulting, let moved = resulting.path { trashedNow[path] = moved }
                case .permanent:
                    try fileManager.removeItem(atPath: path)
                }
                freed += file.size
                removed += 1
                note(mode == .trash ? String(localized: "OK  nel cestino \(path) (\(ByteFormat.string(file.size)))")
                                    : String(localized: "OK  eliminato \(path) (\(ByteFormat.string(file.size)))"))
            } catch {
                let msg = friendlyFileError(error, path: path)
                errors.append(msg)
                note(String(localized: "ERRORE \(path) — \(msg)"))
            }
        }

        if removed == 0 && errors.isEmpty {
            return skip(item, String(localized: "nessun file è più eliminabile: sono stati usati o rimossi dopo l'analisi"))
        }
        var message = dryRun ? String(localized: "\(Plural.files(removed)) da rimuovere")
            : mode == .trash ? String(localized: "\(Plural.files(removed)) nel Cestino")
            : String(localized: "\(Plural.of(removed, "file eliminato", "file eliminati"))")
        if skipped > 0 { message += String(localized: ", \(skipped) saltati perché usati di recente o esclusi") }
        if !errors.isEmpty { message += ", \(Plural.of(errors.count, "errore", "errori")): " + (errors.first ?? "") }
        return DeletionOutcome(title: item.title, succeeded: errors.isEmpty, skipped: false,
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
            return skip(item, String(localized: "l'applicazione è in esecuzione: chiudila e riprova"))
        }
        if activeExclusions.blocksDeletion(of: appPath) {
            return fail(item, String(localized: "l'applicazione rientra nelle tue esclusioni"))
        }
        do {
            try PathGuard.validateApp(appPath, expected: item.identities[appPath])
        } catch {
            return fail(item, error.localizedDescription)
        }

        var freed: Int64 = 0
        var errors: [String] = []

        // Prima il bundle, poi i dati collegati. Se l'app non si può rimuovere
        // (password annullata, permessi) i dati restano intatti: un'app
        // rimossa con qualche residuo si ripulisce dopo, un'app ancora
        // installata ma senza i suoi dati riparte da zero senza motivo.
        let appSize = item.perPathSize[appPath] ?? Shell.diskSize(appPath)
        let needsAdmin = PathGuard.bundleNeedsAdmin(appPath)
        if dryRun {
            note(needsAdmin
                 ? String(localized: "SIMULAZIONE  applicazione (con password): \(appPath) (\(ByteFormat.string(appSize)))")
                 : String(localized: "SIMULAZIONE  applicazione: \(appPath) (\(ByteFormat.string(appSize)))"))
            freed += appSize
        } else if needsAdmin {
            switch removeBundleAsAdmin(appPath, mode: mode, expected: item.identities[appPath]) {
            case .done:
                freed += appSize
                note(String(localized: "OK  applicazione \(appPath) (\(ByteFormat.string(appSize)))"))
            case .cancelled:
                return skip(item, String(localized: "annullato: password non inserita. L'app e i suoi dati sono rimasti al loro posto."))
            case .failed(let why):
                note(String(localized: "ERRORE applicazione \(appPath) — \(why)"))
                return fail(item, String(localized: "bundle applicazione: \(why). I dati collegati non sono stati toccati."))
            }
        } else {
            do {
                switch mode {
                case .trash:
                    var out: NSURL?
                    try fileManager.trashItem(at: URL(fileURLWithPath: appPath), resultingItemURL: &out)
                    if let out, let moved = out.path { trashedNow[appPath] = moved }
                case .permanent:
                    try fileManager.removeItem(atPath: appPath)
                }
                freed += appSize
                note(String(localized: "OK  applicazione \(appPath) (\(ByteFormat.string(appSize)))"))
            } catch {
                let msg = friendlyFileError(error, path: appPath)
                note(String(localized: "ERRORE applicazione \(appPath) — \(msg)"))
                return fail(item, String(localized: "bundle applicazione: \(msg). I dati collegati non sono stati toccati."))
            }
        }

        for path in related {
            if activeExclusions.blocksDeletion(of: path) {
                note(String(localized: "SALTATO dati collegati \(path) — rientra nelle esclusioni impostate dall'utente"))
                continue
            }
            do {
                try PathGuard.validate(path, expected: item.identities[path])
                let size = item.perPathSize[path] ?? Shell.diskSize(path)
                if dryRun {
                    note(String(localized: "SIMULAZIONE  dati collegati: \(path) (\(ByteFormat.string(size)))"))
                    freed += size
                    continue
                }
                switch mode {
                case .trash:
                    var out: NSURL?
                    try fileManager.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &out)
                    if let out, let moved = out.path { trashedNow[path] = moved }
                case .permanent:
                    try fileManager.removeItem(atPath: path)
                }
                freed += size
                note(String(localized: "OK  dati collegati \(path) (\(ByteFormat.string(size)))"))
            } catch PathGuard.Violation.doesNotExist {
                continue
            } catch {
                let msg = friendlyFileError(error, path: path)
                errors.append(msg)
                note(String(localized: "ERRORE dati collegati \(path) — \(msg)"))
            }
        }

        return DeletionOutcome(title: item.title, succeeded: errors.isEmpty, skipped: false,
                               message: errors.isEmpty
                                ? String(localized: "Applicazione e \(Plural.of(related.count, "elemento collegato", "elementi collegati")) rimossi")
                                : String(localized: "Applicazione rimossa; non rimossi: ") + errors.joined(separator: "; "),
                               freed: freed)
    }

    private enum AdminRemoval { case done, cancelled, failed(String) }

    /// Rimozione di un bundle che appartiene a `root` (app del Mac App Store):
    /// stesso effetto del Finder, che in questo caso chiede la password.
    /// Nel Cestino il bundle resta di proprietà di `root`: si svuota come
    /// qualunque altro elemento, ma rimetterlo al suo posto richiede il Finder.
    private func removeBundleAsAdmin(_ appPath: String, mode: RemovalMode,
                                     expected: FileIdentity?) -> AdminRemoval {
        // Ricontrollo subito prima della password: deve essere ancora lo
        // stesso bundle, nello stesso posto.
        do { try PathGuard.validateApp(appPath, expected: expected) } catch {
            return .failed(error.localizedDescription)
        }
        let command: String
        var destination: String?
        switch mode {
        case .trash:
            let trash = ScanSupport.home + "/.Trash"
            let name = (appPath as NSString).lastPathComponent
            var target = trash + "/" + name
            if FileManager.default.fileExists(atPath: target) {
                let stamp = Int(Date().timeIntervalSince1970)
                target = trash + "/" + (name as NSString).deletingPathExtension + " \(stamp).app"
            }
            destination = target
            command = "/bin/mv -n " + Shell.shellQuote(appPath) + " " + Shell.shellQuote(target)
        case .permanent:
            command = "/bin/rm -rf " + Shell.shellQuote(appPath)
        }
        let r = Shell.runAsAdmin(command)
        noteResult(r, "sudo \(command)")
        if !r.ok && r.stderr.contains("-128") { return .cancelled }
        // L'esito vero è sul disco: il bundle non deve più esserci.
        guard r.ok, !FileManager.default.fileExists(atPath: appPath) else {
            return .failed(r.ok ? String(localized: "il bundle è ancora al suo posto") : shortError(r.stderr))
        }
        if let destination { trashedNow[appPath] = destination }
        return .done
    }

    private func runSimctl(_ item: CleanupItem,
                           _ args: [String],
                           dryRun: Bool,
                           successNote: String? = nil) -> DeletionOutcome {
        guard let xcrun = Shell.which("xcrun") else {
            return skip(item, String(localized: "xcrun non disponibile: Xcode o gli strumenti a riga di comando non sono installati"))
        }
        if dryRun {
            note(String(localized: "SIMULAZIONE  xcrun \(args.joined(separator: " "))"))
            return DeletionOutcome(title: item.title, succeeded: true, skipped: false,
                                   message: String(localized: "Simulato"), freed: item.size)
        }
        let r = Shell.run(xcrun, args, timeout: 300)
        noteResult(r, "xcrun \(args.joined(separator: " "))")
        return DeletionOutcome(title: item.title, succeeded: r.ok, skipped: false,
                               message: r.ok ? (successNote ?? String(localized: "Eseguito")) : shortError(r.stderr),
                               freed: r.ok ? item.size : 0)
    }

    // MARK: - Backup

    /// Archivia i dati di un'app prima di eliminarli. Usato quando la casella
    /// «crea backup» è attiva e sono stati rilevati dati dell'utente.
    func backup(paths: [String], appName: String) -> (ok: Bool, message: String, archivePath: String?) {
        guard let ditto = Shell.which("ditto") else {
            return (false, String(localized: "strumento «ditto» non disponibile"), nil)
        }
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd-HHmm"
        let safeName = appName.replacingOccurrences(of: "/", with: "-")
        let dest = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Documents/Ammugghia Backup", isDirectory: true)
        try? fileManager.createDirectory(at: dest, withIntermediateDirectories: true)
        let archive = dest.appendingPathComponent("\(safeName)-\(stamp.string(from: Date())).zip")

        let existing = paths.filter { fileManager.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return (true, String(localized: "nessun dato da archiviare"), nil) }

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
            return (true, String(localized: "Backup creato in \(archive.path)"), archive.path)
        }
        note(String(localized: "BACKUP FALLITO  \(shortError(r.stderr))"))
        return (false, shortError(r.stderr), nil)
    }

    // MARK: - Utilità

    private func skip(_ item: CleanupItem, _ why: String) -> DeletionOutcome {
        note(String(localized: "SALTATO \(item.title) — \(why)"))
        return DeletionOutcome(title: item.title, succeeded: false, skipped: true,
                               message: why, freed: 0)
    }

    private func fail(_ item: CleanupItem, _ why: String) -> DeletionOutcome {
        note(String(localized: "ERRORE \(item.title) — \(why)"))
        return DeletionOutcome(title: item.title, succeeded: false, skipped: false,
                               message: why, freed: 0)
    }

    private func shortError(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return String(localized: "errore non specificato") }
        return t.split(separator: "\n").prefix(2).joined(separator: " ")
    }

    /// Traduce gli errori di FileManager in indicazioni utili, in particolare
    /// il caso "Accesso completo al disco" che su macOS recenti è la causa
    /// più frequente di fallimento.
    func friendlyFileError(_ error: Error, path: String) -> String {
        // Solo gli errori di sistema si traducono per codice: un rifiuto di
        // PathGuard ha codici propri che coincidono per caso con quelli di
        // Cocoa (il suo 4 è «fuori dalle aree consentite», per Cocoa è «file
        // inesistente») e va mostrato con il suo messaggio.
        let ns = error as NSError
        guard ns.domain == NSCocoaErrorDomain else { return error.localizedDescription }
        if path.hasSuffix(".app"), ns.code == NSFileWriteNoPermissionError {
            return String(localized: "permesso negato: macOS protegge le app installate. Concedi «Gestione app» ad Ammugghia in Impostazioni di Sistema → Privacy e sicurezza, oppure trascina l'app nel Cestino dal Finder.")
        }
        switch ns.code {
        case NSFileWriteNoPermissionError, NSFileReadNoPermissionError:
            return String(localized: "permesso negato. Concedi «Accesso completo al disco» a Ammugghia in ")
                 + String(localized: "Impostazioni di Sistema → Privacy e sicurezza, oppure elimina questo elemento a mano.")
        case NSFileWriteVolumeReadOnlyError:
            return String(localized: "il volume è in sola lettura")
        case NSFileNoSuchFileError:
            return String(localized: "già rimosso")
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

    /// Nome leggibile di un'app: quello dell'istanza in esecuzione o del
    /// bundle installato, altrimenti il bundle id stesso.
    static func displayName(bundleID: String) -> String {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
           let name = app.localizedName {
            return name
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: "")
        }
        return bundleID
    }

    /// Chiede alle app di chiudersi come farebbe l'utente da menu: possono
    /// chiedere di salvare i documenti. Mai `forceTerminate`.
    static func requestQuit(bundleIDs: [String]) {
        for id in bundleIDs {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: id) {
                app.terminate()
            }
        }
    }
}
