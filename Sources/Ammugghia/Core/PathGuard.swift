import Foundation

/// Il cancello di sicurezza. Nessun percorso viene eliminato senza passare
/// da qui, e in caso di dubbio il risultato è sempre il rifiuto.
///
/// Il modello è a doppia barriera: un percorso deve **rientrare** in una
/// lista di prefissi consentiti *e* **non rientrare** nella lista dei
/// percorsi protetti. Aggiungere uno scanner nuovo non allarga i permessi:
/// se il percorso non è in allowlist, viene rifiutato.
enum PathGuard {

    enum Violation: LocalizedError {
        case notAbsolute(String)
        case tooShallow(String)
        case doesNotExist(String)
        case isProtected(String, String)
        case outsideAllowlist(String)
        case symlinkEscape(String, String)
        case notAnApp(String)
        case notAProjectArtifact(String)
        case rootOrHome(String)

        var errorDescription: String? {
            switch self {
            case .notAbsolute(let p):
                return "Percorso non assoluto, rifiutato: \(p)"
            case .tooShallow(let p):
                return "Percorso troppo vicino alla radice del disco, rifiutato: \(p)"
            case .doesNotExist(let p):
                return "Il percorso non esiste (già eliminato?): \(p)"
            case .isProtected(let p, let why):
                return "Percorso protetto, rifiutato: \(p) — \(why)"
            case .outsideAllowlist(let p):
                return "Percorso fuori dalle aree che questo software può toccare: \(p)"
            case .symlinkEscape(let p, let target):
                return "Il percorso è un collegamento che punta fuori dall'area consentita: \(p) → \(target)"
            case .notAnApp(let p):
                return "Non è un bundle applicazione in una cartella Applicazioni: \(p)"
            case .notAProjectArtifact(let p):
                return "Non è una cartella di artefatti di build riconosciuta: \(p)"
            case .rootOrHome(let p):
                return "Rifiuto di eliminare una cartella radice o la cartella utente: \(p)"
            }
        }
    }

    static let home = NSHomeDirectory()

    // MARK: - Percorsi mai toccabili

    /// Protezione di primo livello: nessuna operazione, di nessun tipo, può
    /// toccare questi percorsi. Non esistono eccezioni oltre a
    /// `explicitExceptions`.
    static let absoluteProtected: [(path: String, reason: String)] = [
        (home + "/Pictures", "cartella Immagini (include la libreria Foto)"),
        (home + "/Music", "cartella Musica"),
        (home + "/Public", "cartella Pubblica"),
        (home + "/Library/Mobile Documents", "iCloud Drive"),
        (home + "/Library/CloudStorage", "cartelle sincronizzate su cloud"),
        (home + "/Library/Keychains", "portachiavi e credenziali"),
        (home + "/Library/Messages", "cronologia Messaggi"),
        (home + "/Library/Mail", "archivio Mail"),
        (home + "/Library/Photos", "libreria Foto"),
        (home + "/Library/Application Support/AddressBook", "Contatti"),
        (home + "/Library/Calendars", "Calendario"),
        (home + "/Library/Reminders", "Promemoria"),
        (home + "/Library/Safari", "cronologia e segnalibri Safari"),
        (home + "/Library/Application Support/MobileSync", "backup dei dispositivi iOS"),
        (home + "/.ssh", "chiavi SSH"),
        (home + "/.gnupg", "chiavi GPG"),
        (home + "/.aws", "credenziali AWS"),
        (home + "/.kube", "configurazione Kubernetes"),
        (home + "/.config", "file di configurazione"),
        (home + "/.docker/config.json", "credenziali dei registry Docker"),
        (home + "/.claude", "configurazione e cronologia di Claude Code"),
        ("/System", "sistema operativo"),
        ("/usr", "componenti di sistema"),
        ("/bin", "componenti di sistema"),
        ("/sbin", "componenti di sistema"),
        ("/etc", "configurazione di sistema"),
        ("/private/etc", "configurazione di sistema"),
        ("/private/var/db", "database di sistema"),
        ("/private/var/vm", "file di swap: eliminarli destabilizza il sistema"),
        ("/Volumes", "dischi esterni e volumi montati"),
        ("/Users/Shared", "cartella condivisa tra utenti"),
        ("/Library/Keychains", "portachiavi di sistema"),
    ]

    /// Protezione di secondo livello: le cartelle dei documenti dell'utente.
    /// Bloccate per qualsiasi eliminazione generica, ma non per gli artefatti
    /// di build, che devono superare una prova doppia (nome della cartella in
    /// un elenco chiuso *più* un file manifest di progetto nella cartella
    /// padre). Serve perché molti progetti vivono in ~/Documents o sulla
    /// Scrivania: senza questa distinzione i loro `node_modules` sarebbero
    /// irraggiungibili.
    static let documentAreas: [(path: String, reason: String)] = [
        (home + "/Documents", "cartella Documenti"),
        (home + "/Desktop", "Scrivania"),
        (home + "/Downloads", "Download"),
        (home + "/Movies", "cartella Filmati"),
    ]

    static var protectedPrefixes: [(path: String, reason: String)] {
        absoluteProtected + documentAreas
    }

    /// Percorsi che rientrerebbero in un prefisso protetto ma sono
    /// deliberatamente ammessi, uno per uno. Solo eccezioni esatte:
    /// nessun carattere jolly.
    static let explicitExceptions: Set<String> = [
        "/System/Volumes/Data/macOS Install Data",
    ]

    /// Aree in cui lo strumento può operare. Tutto il resto è fuori portata.
    static var allowedPrefixes: [String] {
        [
            home + "/Library/Caches",
            home + "/Library/Developer",
            home + "/Library/Containers",
            home + "/Library/Group Containers",
            home + "/Library/Application Support",
            home + "/Library/Saved Application State",
            home + "/Library/Logs",
            home + "/Library/WebKit",
            home + "/Library/HTTPStorages",
            home + "/Library/Cookies",
            home + "/Library/Preferences",
            home + "/Library/LaunchAgents",
            home + "/Library/Android",
            home + "/Library/pnpm",
            home + "/.Trash",
            "/Library/Caches",
            "/Library/Logs",
            // Area degli strumenti di sviluppo installati a livello di sistema:
            // cache dei simulatori e Command Line Tools. Contiene solo
            // componenti reinstallabili da Apple.
            "/Library/Developer",
            "/Library/Application Support",
            "/Library/LaunchAgents",
            "/Library/LaunchDaemons",
            "/Library/PrivilegedHelperTools",
            "/opt/homebrew/Cellar",
            "/System/Volumes/Data/macOS Install Data",
        ]
        // Le cartelle nascoste nella home (~/.gradle, ~/.npm…) sono ammesse
        // tramite `isAllowedHomeDotDirectory`, non elencandole tutte.
    }

    /// Cartelle nascoste della home escluse a prescindere, anche se il
    /// resto di `~/.*` è consentito.
    static let deniedHomeDotDirectories: Set<String> = [
        ".ssh", ".gnupg", ".aws", ".kube", ".config", ".claude",
        ".gitconfig", ".git-credentials", ".netrc", ".zsh_history",
        ".bash_history", ".zshrc", ".bashrc", ".zprofile", ".profile",
        ".Trash", ".CFUserTextEncoding", ".viminfo", ".local",
    ]

    /// Nomi di cartelle riconosciute come artefatti di build, eliminabili
    /// dentro un progetto solo se il progetto ha un file manifest
    /// corrispondente (vedi `validateProjectArtifact`).
    static let projectArtifactNames: Set<String> = [
        "node_modules", "Pods", ".dart_tool", ".cxx", "DerivedData",
        ".gradle", "build", ".next", ".turbo", ".parcel-cache",
    ]

    /// File la cui presenza dimostra che la cartella padre è un progetto.
    static let projectMarkers: [String] = [
        "package.json", "pubspec.yaml", "Podfile", "build.gradle",
        "build.gradle.kts", "settings.gradle", "settings.gradle.kts",
        "Cargo.toml", "pom.xml", "Package.swift",
    ]

    // MARK: - Validazione

    /// Normalizza il percorso e applica tutti i controlli.
    /// - Parameter mustExist: se `false` un percorso inesistente non è un errore
    ///   (utile nella fase di sola visualizzazione).
    static func validate(_ rawPath: String, mustExist: Bool = true) throws {
        let path = normalize(rawPath)

        guard path.hasPrefix("/") else { throw Violation.notAbsolute(rawPath) }

        // Radici e cartella utente: rifiuto categorico.
        if path == "/" || path == home || path == "/Users" || path == "/Applications"
            || path == home + "/Library" || path == "/Library" {
            throw Violation.rootOrHome(path)
        }

        // Almeno /Users/<utente>/<qualcosa>: blocca ~/ e /Xxx.
        let components = URL(fileURLWithPath: path).pathComponents
        if components.count < 3 && !explicitExceptions.contains(path) {
            throw Violation.tooShallow(path)
        }

        if mustExist {
            guard FileManager.default.fileExists(atPath: path) else {
                throw Violation.doesNotExist(path)
            }
        }

        if !explicitExceptions.contains(path) {
            if let hit = protectedHit(path) {
                throw Violation.isProtected(path, hit.reason)
            }
        }

        guard isAllowed(path) else { throw Violation.outsideAllowlist(path) }

        // Un collegamento simbolico può puntare altrove: si valida anche la
        // destinazione, così eliminare "~/Library/Caches/x" che punta a
        // "~/Documents" non passa.
        try validateSymlinkTarget(path)
    }

    /// Bundle applicazione: consentito solo direttamente in una cartella
    /// Applicazioni e solo con estensione `.app`.
    static func validateApp(_ rawPath: String) throws {
        let path = normalize(rawPath)
        guard path.hasSuffix(".app") else { throw Violation.notAnApp(path) }

        let parent = (path as NSString).deletingLastPathComponent
        let allowedParents = [
            "/Applications",
            "/Applications/Utilities",
            home + "/Applications",
        ]
        // Ammessa anche una sottocartella diretta di /Applications
        // (es. /Applications/Adobe/Foo.app).
        let isNestedInApplications = parent.hasPrefix("/Applications/")
            && parent.components(separatedBy: "/").count <= 3

        guard allowedParents.contains(parent) || isNestedInApplications else {
            throw Violation.notAnApp(path)
        }
        guard FileManager.default.fileExists(atPath: path) else {
            throw Violation.doesNotExist(path)
        }
        // Le app di sistema vivono in /System/Applications e sono già
        // escluse dal prefisso protetto "/System".
        if let hit = protectedHit(path) {
            throw Violation.isProtected(path, hit.reason)
        }
    }

    /// Artefatto di build dentro un progetto. Doppia condizione: il nome
    /// della cartella deve essere in `projectArtifactNames` **e** la cartella
    /// padre deve contenere un file manifest di progetto. Senza il manifest
    /// una cartella chiamata "build" potrebbe essere codice sorgente.
    static func validateProjectArtifact(_ rawPath: String) throws {
        let path = normalize(rawPath)
        let name = (path as NSString).lastPathComponent
        guard projectArtifactNames.contains(name) else {
            throw Violation.notAProjectArtifact(path)
        }
        let parent = (path as NSString).deletingLastPathComponent
        let hasMarker = projectMarkers.contains {
            FileManager.default.fileExists(atPath: parent + "/" + $0)
        }
        guard hasMarker else { throw Violation.notAProjectArtifact(path) }
        guard FileManager.default.fileExists(atPath: path) else {
            throw Violation.doesNotExist(path)
        }
        // Le aree documenti sono ammesse qui — la prova doppia sopra è ciò
        // che le sblocca — ma la protezione assoluta resta valida.
        if let hit = absoluteHit(path) {
            throw Violation.isProtected(path, hit.reason)
        }
        let components = URL(fileURLWithPath: path).pathComponents
        if components.count < 4 { throw Violation.tooShallow(path) }
    }

    // MARK: - Interni

    static func normalize(_ path: String) -> String {
        var p = (path as NSString).expandingTildeInPath
        p = (p as NSString).standardizingPath
        // `standardizingPath` risolve i simbolici solo in /private, quindi
        // ".." residui vanno esclusi a mano.
        if p.contains("/../") || p.hasSuffix("/..") { return path }
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// Solo la protezione di primo livello.
    static func absoluteHit(_ path: String) -> (path: String, reason: String)? {
        if explicitExceptions.contains(path) { return nil }
        for entry in absoluteProtected {
            if path == entry.path || path.hasPrefix(entry.path + "/") { return entry }
        }
        if let dot = homeDotComponent(path), deniedHomeDotDirectories.contains(dot) {
            return (path, "area riservata della cartella utente (\(dot))")
        }
        return nil
    }

    static func protectedHit(_ path: String) -> (path: String, reason: String)? {
        if let hit = absoluteHit(path) { return hit }
        if explicitExceptions.contains(path) { return nil }
        for entry in documentAreas {
            if path == entry.path || path.hasPrefix(entry.path + "/") { return entry }
        }
        return nil
    }

    static func isAllowed(_ path: String) -> Bool {
        if explicitExceptions.contains(path) { return true }
        for prefix in allowedPrefixes {
            if path == prefix || path.hasPrefix(prefix + "/") { return true }
        }
        if isAllowedHomeDotDirectory(path) { return true }
        return false
    }

    /// Prima componente nascosta subito sotto la home, se c'è.
    static func homeDotComponent(_ path: String) -> String? {
        guard path.hasPrefix(home + "/.") else { return nil }
        let rest = String(path.dropFirst(home.count + 1))
        return rest.split(separator: "/").first.map(String.init)
    }

    /// `~/.gradle`, `~/.npm`, `~/.pub-cache`… sono consentite in blocco
    /// tranne quelle in denylist: le cache degli strumenti di sviluppo sono
    /// troppe per elencarle una per una, ma restano confinate a `~/.*`.
    static func isAllowedHomeDotDirectory(_ path: String) -> Bool {
        guard let dot = homeDotComponent(path) else { return false }
        guard !deniedHomeDotDirectories.contains(dot) else { return false }
        // Serve almeno ~/.qualcosa (non la home stessa).
        return path.count > home.count + 2
    }

    static func validateSymlinkTarget(_ path: String) throws {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        guard let type = attrs?[.type] as? FileAttributeType, type == .typeSymbolicLink else {
            return
        }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        if let hit = protectedHit(resolved) {
            throw Violation.symlinkEscape(path, "\(resolved) (\(hit.reason))")
        }
        guard isAllowed(resolved) else {
            throw Violation.symlinkEscape(path, resolved)
        }
    }

    /// Verifica preventiva usata dall'interfaccia per marcare gli elementi
    /// non eliminabili *prima* che l'utente li selezioni.
    static func preflight(_ item: CleanupItem) -> [String] {
        var problems: [String] = []
        switch item.action {
        case .removePaths(let paths):
            for p in paths {
                do { try validate(p) } catch { problems.append(error.localizedDescription) }
            }
        case .removeProjectArtifacts(let paths):
            for p in paths {
                do { try validateProjectArtifact(p) } catch { problems.append(error.localizedDescription) }
            }
        case .removeApp(let app, let related):
            do { try validateApp(app) } catch { problems.append(error.localizedDescription) }
            for p in related {
                do { try validate(p) } catch { problems.append(error.localizedDescription) }
            }
        case .privileged(_, let paths):
            for p in paths {
                do { try validate(p) } catch { problems.append(error.localizedDescription) }
            }
        case .revealOnly, .simctlDeleteDevice, .simctlEraseDevice,
             .simctlDeleteRuntime, .shell, .dockerPrune:
            break
        }
        return problems
    }
}
