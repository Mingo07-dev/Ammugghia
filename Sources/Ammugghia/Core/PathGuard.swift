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
        case identityChanged(String)
        case containsMountPoint(String, String)
        case notEligibleTemporary(String, String)

        var errorDescription: String? {
            switch self {
            case .notAbsolute(let p):
                return String(localized: "Percorso non assoluto, rifiutato: \(p)")
            case .tooShallow(let p):
                return String(localized: "Percorso troppo vicino alla radice del disco, rifiutato: \(p)")
            case .doesNotExist(let p):
                return String(localized: "Il percorso non esiste (già eliminato?): \(p)")
            case .isProtected(let p, let why):
                return String(localized: "Percorso protetto, rifiutato: \(p) — \(why)")
            case .outsideAllowlist(let p):
                return String(localized: "Percorso fuori dalle aree che questo software può toccare: \(p)")
            case .symlinkEscape(let p, let target):
                return String(localized: "Il percorso è un collegamento che punta fuori dall'area consentita: \(p) → \(target)")
            case .notAnApp(let p):
                return String(localized: "Non è un bundle applicazione in una cartella Applicazioni: \(p)")
            case .notAProjectArtifact(let p):
                return String(localized: "Non è una cartella di artefatti di build riconosciuta: \(p)")
            case .rootOrHome(let p):
                return String(localized: "Rifiuto di eliminare una cartella radice o la cartella utente: \(p)")
            case .identityChanged(let p):
                return String(localized: "Il percorso è cambiato dopo l'analisi (non è più lo stesso file o cartella): \(p). Rianalizza prima di eliminare.")
            case .notEligibleTemporary(let p, let why):
                return String(localized: "File temporaneo non eliminabile: \(p) — \(why)")
            case .containsMountPoint(let p, let mount):
                return String(localized: "Il percorso contiene un volume montato, rifiutato: \(p) → \(mount)")
            }
        }
    }

    static let home = NSHomeDirectory()

    // MARK: - Percorsi mai toccabili

    /// Protezione di primo livello: nessuna operazione, di nessun tipo, può
    /// toccare questi percorsi. Non esistono eccezioni oltre a
    /// `explicitExceptions`.
    static let absoluteProtected: [(path: String, reason: String)] = [
        (home + "/Pictures", String(localized: "cartella Immagini (include la libreria Foto)")),
        (home + "/Music", String(localized: "cartella Musica")),
        (home + "/Public", String(localized: "cartella Pubblica")),
        (home + "/Library/Mobile Documents", String(localized: "iCloud Drive")),
        (home + "/Library/CloudStorage", String(localized: "cartelle sincronizzate su cloud")),
        (home + "/Library/Keychains", String(localized: "portachiavi e credenziali")),
        (home + "/Library/Messages", String(localized: "cronologia Messaggi")),
        (home + "/Library/Mail", String(localized: "archivio Mail")),
        (home + "/Library/Photos", String(localized: "libreria Foto")),
        (home + "/Library/Application Support/AddressBook", "Contatti"),
        (home + "/Library/Calendars", "Calendario"),
        (home + "/Library/Reminders", "Promemoria"),
        (home + "/Library/Safari", String(localized: "cronologia e segnalibri Safari")),
        (home + "/Library/Application Support/MobileSync", String(localized: "backup dei dispositivi iOS")),
        (home + "/.ssh", String(localized: "chiavi SSH")),
        (home + "/.gnupg", String(localized: "chiavi GPG")),
        (home + "/.aws", String(localized: "credenziali AWS")),
        (home + "/.kube", String(localized: "configurazione Kubernetes")),
        (home + "/.config", String(localized: "file di configurazione")),
        (home + "/.docker/config.json", String(localized: "credenziali dei registry Docker")),
        (home + "/.claude", String(localized: "configurazione e cronologia di Claude Code")),
        ("/System", String(localized: "sistema operativo")),
        ("/usr", String(localized: "componenti di sistema")),
        ("/bin", String(localized: "componenti di sistema")),
        ("/sbin", String(localized: "componenti di sistema")),
        ("/etc", String(localized: "configurazione di sistema")),
        ("/private/etc", String(localized: "configurazione di sistema")),
        ("/private/var/db", String(localized: "database di sistema")),
        ("/private/var/vm", String(localized: "file di swap: eliminarli destabilizza il sistema")),
        ("/Volumes", String(localized: "dischi esterni e volumi montati")),
        ("/Users/Shared", String(localized: "cartella condivisa tra utenti")),
        ("/Library/Keychains", String(localized: "portachiavi di sistema")),
    ]

    /// Protezione di secondo livello: le cartelle dei documenti dell'utente.
    /// Bloccate per qualsiasi eliminazione generica, ma non per gli artefatti
    /// di build, che devono superare una prova doppia (nome della cartella in
    /// un elenco chiuso *più* un file manifest di progetto nella cartella
    /// padre). Serve perché molti progetti vivono in ~/Documents o sulla
    /// Scrivania: senza questa distinzione i loro `node_modules` sarebbero
    /// irraggiungibili.
    static let documentAreas: [(path: String, reason: String)] = [
        (home + "/Documents", String(localized: "cartella Documenti")),
        (home + "/Desktop", "Scrivania"),
        (home + "/Downloads", "Download"),
        (home + "/Movies", String(localized: "cartella Filmati")),
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

    /// Artefatti di build riconosciuti, ciascuno con i file manifest che ne
    /// dimostrano la natura. Il legame è stretto di proposito: una cartella
    /// `target` è un artefatto accanto a `Cargo.toml` o `pom.xml`, ma accanto a
    /// un `package.json` è quasi certamente qualcos'altro. Un manifest qualsiasi
    /// non basta più.
    ///
    /// Un marcatore che inizia con `*.` indica un'estensione (es. un
    /// `.xcodeproj` di nome qualsiasi); uno con `/` è un percorso relativo.
    ///
    /// Esclusi di proposito: `vendor` (Composer e Go lo versionano spesso),
    /// `bin`/`obj` di .NET (nomi troppo generici), `dist` (spesso un output
    /// preparato a mano e pubblicato).
    static let projectArtifactRules: [String: [String]] = {
        let node = ["package.json"]
        let gradle = ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"]
        let python = ["pyproject.toml", "setup.py", "setup.cfg", "requirements.txt", "Pipfile", "tox.ini"]
        let unity = ["ProjectSettings/ProjectVersion.txt"]
        return [
            "node_modules": node, ".next": node, ".turbo": node, ".parcel-cache": node,
            ".nuxt": node, ".expo": node, ".angular": node,
            "Pods": ["Podfile"],
            ".dart_tool": ["pubspec.yaml"],
            "build": ["pubspec.yaml", "package.json", "CMakeLists.txt"] + gradle,
            ".gradle": gradle, ".cxx": gradle,
            "DerivedData": ["*.xcodeproj", "*.xcworkspace", "Package.swift"],
            ".build": ["Package.swift"], ".swiftpm": ["Package.swift"],
            "target": ["Cargo.toml", "pom.xml"],
            ".pytest_cache": python, ".mypy_cache": python, ".ruff_cache": python,
            ".tox": python, ".nox": python,
            ".godot": ["project.godot"],
            ".zig-cache": ["build.zig"], "zig-out": ["build.zig"],
            ".terraform": [".terraform.lock.hcl"],
            ".stack-work": ["stack.yaml"],
            "dist-newstyle": ["cabal.project", "*.cabal"],
            "_build": ["mix.exs"], ".elixir_ls": ["mix.exs"],
            "Library": unity, "Temp": unity, "obj": unity,
        ]
    }()

    static var projectArtifactNames: Set<String> { Set(projectArtifactRules.keys) }

    /// Nomi abbastanza comuni da poter indicare anche cartelle scritte a
    /// mano: per questi serve una prova in più (vedi `validateProjectArtifact`).
    static let genericArtifactNames: Set<String> = ["build", "target", "Library", "Temp", "obj"]

    /// Tutti i manifest noti, usati per riconoscere un progetto annidato.
    static var allProjectMarkers: Set<String> {
        Set(projectArtifactRules.values.joined().filter { !$0.hasPrefix("*.") && !$0.contains("/") })
    }

    // MARK: - Cartelle temporanee dell'utente

    /// Le cartelle temporanee e di cache dell'utente corrente in
    /// `/var/folders`, chieste al sistema con `confstr` invece di indovinarle.
    /// Non sono in `allowedPrefixes`: `validate` le rifiuta, e l'unico modo di
    /// eliminarci qualcosa è `validateAgedFile`, un file alla volta.
    static let ageGatedRoots: [String] = [_CS_DARWIN_USER_TEMP_DIR, _CS_DARWIN_USER_CACHE_DIR]
        .compactMap(systemDirectory)

    private static func systemDirectory(_ name: Int32) -> String? {
        let length = confstr(name, nil, 0)
        guard length > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: length)
        guard confstr(name, &buffer, length) > 0 else { return nil }
        return realPath(String(cString: buffer))
    }

    /// Percorso canonico (`/var` → `/private/var`), senza risolvere l'ultimo
    /// componente: un collegamento va giudicato per quello che è.
    static func realPath(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &buffer) != nil else { return nil }
        return String(cString: buffer)
    }

    private static func realPathKeepingLast(_ path: String) -> String? {
        let parent = (path as NSString).deletingLastPathComponent
        guard let realParent = realPath(parent) else { return nil }
        return realParent + "/" + (path as NSString).lastPathComponent
    }

    /// Database e preferenze restano esclusi anche se vecchi: possono essere
    /// in uso da un processo che li apre di rado.
    static let ageGatedExcludedExtensions: Set<String> = [
        "db", "sqlite", "sqlite3", "plist", "db-wal", "db-shm",
        "sqlite-wal", "sqlite-shm", "sqlite3-wal", "sqlite3-shm", "lock",
    ]

    /// Cartelle di sistema dentro `/var/folders` da non attraversare.
    static func isExcludedTemporaryComponent(_ name: String) -> Bool {
        (name.hasPrefix("com.apple.") && name.hasSuffix(".Sandbox"))
            || name == "ShortcutsSandboxCache"
            || name == "com.apple.QuickLook.thumbnailcache"
    }

    /// Un file temporaneo è eliminabile solo se: sta dentro una delle due
    /// cartelle dell'utente, non è un collegamento né una cartella, è sullo
    /// stesso volume, non ha un'estensione esclusa, non sta in una cartella
    /// esclusa, e non è stato né modificato né letto negli ultimi giorni.
    static func validateAgedFile(_ rawPath: String, root rawRoot: String, olderThanDays days: Int,
                                 expected: FileIdentity? = nil, now: Date = Date()) throws {
        guard let root = realPath(rawRoot), ageGatedRoots.contains(root) else {
            throw Violation.outsideAllowlist(rawRoot)
        }
        guard let path = realPathKeepingLast(rawPath) else { throw Violation.doesNotExist(rawPath) }
        guard path.hasPrefix(root + "/"), !path.contains("/../") else {
            throw Violation.outsideAllowlist(rawPath)
        }
        let relative = path.dropFirst(root.count + 1).split(separator: "/").map(String.init)
        if relative.dropLast().contains(where: isExcludedTemporaryComponent) {
            throw Violation.notEligibleTemporary(path, String(localized: "cartella di sistema esclusa"))
        }
        if ageGatedExcludedExtensions.contains((path as NSString).pathExtension.lowercased()) {
            throw Violation.notEligibleTemporary(path, String(localized: "database, preferenze o file di blocco: esclusi"))
        }
        if let hit = absoluteHit(path) { throw Violation.isProtected(path, hit.reason) }

        var info = stat()
        guard lstat(path, &info) == 0 else { throw Violation.doesNotExist(path) }
        guard info.st_mode & S_IFMT == S_IFREG else {
            throw Violation.notEligibleTemporary(path, String(localized: "non è un file normale"))
        }
        var rootInfo = stat()
        guard lstat(root, &rootInfo) == 0, rootInfo.st_dev == info.st_dev else {
            throw Violation.notEligibleTemporary(path, String(localized: "su un volume diverso"))
        }
        let limit = now.timeIntervalSince1970 - Double(days) * 86_400
        let modified = Double(info.st_mtimespec.tv_sec)
        let accessed = Double(info.st_atimespec.tv_sec)
        guard modified < limit, accessed < limit else {
            throw Violation.notEligibleTemporary(path, String(localized: "usato negli ultimi \(days) giorni"))
        }
        try validateIdentity(path, expected: expected)
    }

    // MARK: - Validazione

    /// Normalizza il percorso e applica tutti i controlli.
    /// - Parameter mustExist: se `false` un percorso inesistente non è un errore
    ///   (utile nella fase di sola visualizzazione).
    /// - Parameter expected: identità registrata durante l'analisi. Se il
    ///   percorso esiste ma non è più lo stesso oggetto, viene rifiutato.
    static func validate(_ rawPath: String, mustExist: Bool = true,
                         expected: FileIdentity? = nil) throws {
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
        try validateIdentity(path, expected: expected)
        try validateNoMountPoint(path)
    }

    /// Bundle applicazione: consentito solo direttamente in una cartella
    /// Applicazioni e solo con estensione `.app`.
    static func validateApp(_ rawPath: String, expected: FileIdentity? = nil) throws {
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
        try validateIdentity(path, expected: expected)
        try validateNoMountPoint(path)
    }

    /// Artefatto di build dentro un progetto. Doppia condizione: il nome
    /// della cartella deve essere in `projectArtifactRules` **e** la cartella
    /// padre deve contenere uno dei manifest associati a *quel* nome. Senza il
    /// manifest una cartella chiamata "build" potrebbe essere codice sorgente.
    static func validateProjectArtifact(_ rawPath: String, expected: FileIdentity? = nil) throws {
        let path = normalize(rawPath)
        let name = (path as NSString).lastPathComponent
        guard let markers = projectArtifactRules[name] else {
            throw Violation.notAProjectArtifact(path)
        }
        let parent = (path as NSString).deletingLastPathComponent
        guard hasMarker(in: parent, markers) else { throw Violation.notAProjectArtifact(path) }
        guard FileManager.default.fileExists(atPath: path) else {
            throw Violation.doesNotExist(path)
        }
        // Per i nomi generici serve una prova in più: una cartella `build` o
        // `target` che è a sua volta un repository o un progetto (ha un .git o
        // un manifest proprio) è stata creata da qualcuno, non da un compilatore.
        if genericArtifactNames.contains(name) {
            let fm = FileManager.default
            if fm.fileExists(atPath: path + "/.git") || hasMarker(in: path, Array(allProjectMarkers)) {
                throw Violation.notAProjectArtifact(path)
            }
        }
        // Le aree documenti sono ammesse qui — la prova doppia sopra è ciò
        // che le sblocca — ma la protezione assoluta resta valida.
        if let hit = absoluteHit(path) {
            throw Violation.isProtected(path, hit.reason)
        }
        let components = URL(fileURLWithPath: path).pathComponents
        if components.count < 4 { throw Violation.tooShallow(path) }
        // Un artefatto non deve mai essere un collegamento: si elimina la
        // cartella vera dentro il progetto, non ciò a cui punta.
        if FileIdentity.of(path)?.isSymlink == true {
            throw Violation.notAProjectArtifact(path)
        }
        try validateIdentity(path, expected: expected)
        try validateNoMountPoint(path)
    }

    /// Vero se la cartella contiene almeno uno dei marcatori indicati.
    static func hasMarker(in directory: String, _ markers: [String]) -> Bool {
        let fm = FileManager.default
        var extensions: [String] = []
        for marker in markers {
            if marker.hasPrefix("*.") {
                extensions.append(String(marker.dropFirst(2)))
            } else if fm.fileExists(atPath: directory + "/" + marker) {
                return true
            }
        }
        guard !extensions.isEmpty,
              let names = try? fm.contentsOfDirectory(atPath: directory) else { return false }
        return names.contains { name in
            extensions.contains((name as NSString).pathExtension)
        }
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
            return (path, String(localized: "area riservata della cartella utente (\(dot))"))
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

    /// Confronta l'identità attuale con quella registrata durante l'analisi.
    /// Senza un'identità attesa non c'è niente da confrontare: i controlli
    /// sul percorso restano comunque tutti validi.
    static func validateIdentity(_ path: String, expected: FileIdentity?) throws {
        guard let expected, let current = FileIdentity.of(path) else { return }
        if current != expected { throw Violation.identityChanged(path) }
    }

    /// Un volume montato dentro la cartella da eliminare verrebbe svuotato
    /// insieme a lei. Il caso è raro, ma l'elenco dei volumi montati è breve e
    /// il controllo costa poco.
    static func validateNoMountPoint(_ path: String) throws {
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil,
                                                            options: []) ?? []
        for volume in volumes {
            let mount = normalize(volume.path)
            if mount == path || mount.hasPrefix(path + "/") {
                throw Violation.containsMountPoint(path, mount)
            }
        }
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
    /// - Parameter ignoringMissing: un percorso già assente non è un problema
    ///   di sicurezza ma lavoro già fatto. Il criterio è il *tipo* di errore,
    ///   mai il testo del messaggio, che cambia con la lingua.
    static func preflight(_ item: CleanupItem, ignoringMissing: Bool = false) -> [String] {
        var problems: [String] = []
        func record(_ error: Error) {
            if ignoringMissing, case Violation.doesNotExist = error { return }
            problems.append(error.localizedDescription)
        }
        switch item.action {
        case .removePaths(let paths):
            for p in paths {
                do { try validate(p, expected: item.identities[p]) } catch { record(error) }
            }
        case .removeProjectArtifacts(let paths):
            for p in paths {
                do { try validateProjectArtifact(p, expected: item.identities[p]) } catch { record(error) }
            }
        case .removeApp(let app, let related):
            do { try validateApp(app, expected: item.identities[app]) } catch { record(error) }
            for p in related {
                do { try validate(p, expected: item.identities[p]) } catch { record(error) }
            }
        case .privileged(_, let paths):
            for p in paths {
                do { try validate(p, expected: item.identities[p]) } catch { record(error) }
            }
        case .removeAgedFiles(let root, _, _):
            if !ageGatedRoots.contains(realPath(root) ?? root) {
                problems.append(Violation.outsideAllowlist(root).localizedDescription)
            }
        case .revealOnly, .simctlDeleteDevice, .simctlEraseDevice,
             .simctlDeleteRuntime, .shell, .dockerPrune:
            break
        }
        return problems
    }
}
