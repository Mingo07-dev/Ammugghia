import Foundation

/// Verifica delle protezioni, eseguibile con `Ammugghia --selftest`.
///
/// Per uno strumento che elimina file, poter dimostrare che il cancello di
/// sicurezza rifiuta ciò che deve rifiutare vale più di qualsiasi commento.
/// Ogni caso qui è un percorso che *non* deve mai essere eliminabile, oppure
/// uno che deve esserlo.
enum SelfTest {

    struct Case {
        let path: String
        let shouldPass: Bool
        let why: String
    }

    static func run() -> Int32 {
        let home = NSHomeDirectory()

        let cases: [Case] = [
            // Deve rifiutare: radici e cartelle di primo livello.
            .init(path: "/", shouldPass: false, why: String(localized: "radice del disco")),
            .init(path: home, shouldPass: false, why: String(localized: "cartella utente")),
            .init(path: "/Users", shouldPass: false, why: String(localized: "cartella di tutti gli utenti")),
            .init(path: "/System", shouldPass: false, why: String(localized: "sistema operativo")),
            .init(path: "/usr/bin", shouldPass: false, why: String(localized: "binari di sistema")),
            .init(path: "/etc", shouldPass: false, why: String(localized: "configurazione di sistema")),
            .init(path: home + "/Library", shouldPass: false, why: String(localized: "intera libreria utente")),
            .init(path: "/Library", shouldPass: false, why: String(localized: "intera libreria di sistema")),
            .init(path: "/Applications", shouldPass: false, why: String(localized: "cartella Applicazioni")),

            // Deve rifiutare: dati personali.
            .init(path: home + "/Documents", shouldPass: false, why: String(localized: "Documenti")),
            .init(path: home + "/Documents/fattura.pdf", shouldPass: false, why: String(localized: "file in Documenti")),
            .init(path: home + "/Desktop/progetto", shouldPass: false, why: String(localized: "cartella sulla Scrivania")),
            .init(path: home + "/Pictures/Foto Library.photoslibrary", shouldPass: false, why: String(localized: "libreria Foto")),
            .init(path: home + "/Movies/vacanze.mov", shouldPass: false, why: String(localized: "filmato personale")),
            .init(path: home + "/Music", shouldPass: false, why: String(localized: "Musica")),
            .init(path: home + "/Downloads/installer.dmg", shouldPass: false, why: String(localized: "file scaricato")),
            .init(path: home + "/.ssh/id_rsa", shouldPass: false, why: String(localized: "chiave SSH")),
            .init(path: home + "/.gnupg", shouldPass: false, why: String(localized: "chiavi GPG")),
            .init(path: home + "/.aws/credentials", shouldPass: false, why: String(localized: "credenziali AWS")),
            .init(path: home + "/.config/qualcosa", shouldPass: false, why: "configurazioni"),
            .init(path: home + "/.claude", shouldPass: false, why: String(localized: "dati di Claude Code")),
            .init(path: home + "/Library/Mobile Documents", shouldPass: false, why: String(localized: "iCloud Drive")),
            .init(path: home + "/Library/Keychains", shouldPass: false, why: "portachiavi"),
            .init(path: home + "/Library/Mail", shouldPass: false, why: String(localized: "archivio Mail")),
            .init(path: home + "/Library/Messages", shouldPass: false, why: String(localized: "cronologia Messaggi")),
            .init(path: home + "/Library/Photos", shouldPass: false, why: String(localized: "libreria Foto")),
            .init(path: home + "/Library/Safari/History.db", shouldPass: false, why: String(localized: "cronologia Safari")),
            .init(path: home + "/Library/Application Support/MobileSync/Backup",
                  shouldPass: false, why: String(localized: "backup dei dispositivi iOS")),

            // Deve rifiutare: percorsi malformati o fuori area.
            .init(path: "relativo/non/assoluto", shouldPass: false, why: String(localized: "percorso relativo")),
            .init(path: "/opt", shouldPass: false, why: String(localized: "fuori dalle aree consentite")),
            .init(path: "/private/var/vm/swapfile0", shouldPass: false, why: String(localized: "file di swap")),
            .init(path: "/Volumes/Disco Esterno/dati", shouldPass: false, why: String(localized: "disco esterno")),

            // Deve accettare: aree di cache legittime.
            .init(path: home + "/Library/Caches/qualcosa", shouldPass: true, why: String(localized: "cache utente")),
            .init(path: home + "/Library/Developer/Xcode/DerivedData/App-abc",
                  shouldPass: true, why: String(localized: "DerivedData di Xcode")),
            .init(path: home + "/Library/Developer/CoreSimulator/Devices/UUID",
                  shouldPass: true, why: String(localized: "dispositivo simulato")),
            .init(path: home + "/.gradle/caches", shouldPass: true, why: String(localized: "cache Gradle")),
            .init(path: home + "/.npm/_cacache", shouldPass: true, why: String(localized: "cache npm")),
            .init(path: home + "/Library/Android/sdk/ndk/28.0", shouldPass: true, why: String(localized: "NDK Android")),
            .init(path: "/Library/Developer/CoreSimulator/Caches/dyld",
                  shouldPass: true, why: String(localized: "cache dyld dei simulatori")),
            .init(path: "/Library/Developer/CommandLineTools",
                  shouldPass: true, why: String(localized: "Command Line Tools (reinstallabili da Apple)")),
            .init(path: "/Library/Preferences/com.apple.loginwindow.plist",
                  shouldPass: false, why: String(localized: "preferenze di sistema: fuori allowlist di proposito")),
            .init(path: "/System/Volumes/Data/macOS Install Data",
                  shouldPass: true, why: String(localized: "installer residuo (eccezione esplicita)")),
            .init(path: (PathGuard.ageGatedRoots.first ?? "/private/var/folders/xx/T") + "/qualcosa",
                  shouldPass: false, why: String(localized: "cartelle temporanee: solo tramite la regola dei 7 giorni")),
            .init(path: "/private/var/folders", shouldPass: false,
                  why: String(localized: "radice delle cartelle temporanee di tutti gli utenti")),
        ]

        print(String(localized: "Ammugghia — verifica delle protezioni"))
        print(String(repeating: "─", count: 72))

        var failures = 0
        for testCase in cases {
            // `mustExist: false` isola la logica di protezione dalla presenza
            // effettiva del file su questo Mac.
            var passed: Bool
            var detail = ""
            do {
                try PathGuard.validate(testCase.path, mustExist: false)
                passed = true
            } catch {
                passed = false
                detail = error.localizedDescription
            }

            let correct = passed == testCase.shouldPass
            if !correct { failures += 1 }

            let mark = correct ? "✓" : "✗ ERRORE"
            let verdict = passed ? "CONSENTITO" : "RIFIUTATO"
            let expected = testCase.shouldPass ? "consentito" : "rifiutato"
            print("\(mark)  \(verdict.padding(toLength: 11, withPad: " ", startingAt: 0)) \(testCase.path)")
            print("       \(testCase.why) — atteso: \(expected)")
            if !correct && !detail.isEmpty { print("       motivo: \(detail)") }
        }

        // Verifica separata degli artefatti di progetto: devono essere
        // ammessi nelle aree documenti solo con la prova doppia.
        print(String(repeating: "─", count: 72))
        print(String(localized: "Artefatti di progetto (richiedono nome in elenco + file di progetto nel padre)"))

        let tmp = NSTemporaryDirectory() + "ammugghia-selftest-\(UUID().uuidString)"
        let fm = FileManager.default
        try? fm.createDirectory(atPath: tmp + "/con-manifest/node_modules", withIntermediateDirectories: true)
        fm.createFile(atPath: tmp + "/con-manifest/package.json", contents: Data("{}".utf8))
        try? fm.createDirectory(atPath: tmp + "/senza-manifest/node_modules", withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: tmp + "/con-manifest/src", withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: tmp) }

        // Ogni nome è legato al proprio manifest: `target` vale per Rust e
        // Maven, non per un progetto Node.
        func makeProject(_ name: String, manifests: [String], artifact: String) {
            let base = tmp + "/" + name
            try? fm.createDirectory(atPath: base + "/" + artifact, withIntermediateDirectories: true)
            for m in manifests {
                let file = base + "/" + m
                try? fm.createDirectory(atPath: (file as NSString).deletingLastPathComponent,
                                        withIntermediateDirectories: true)
                if m.hasSuffix(".xcodeproj") {
                    try? fm.createDirectory(atPath: file, withIntermediateDirectories: true)
                } else {
                    fm.createFile(atPath: file, contents: Data())
                }
            }
        }
        makeProject("rust", manifests: ["Cargo.toml"], artifact: "target")
        makeProject("node-target", manifests: ["package.json"], artifact: "target")
        makeProject("repo-build", manifests: ["package.json"], artifact: "build/.git")
        makeProject("progetto-build", manifests: ["package.json"], artifact: "build")
        fm.createFile(atPath: tmp + "/progetto-build/build/package.json", contents: Data())
        makeProject("unity", manifests: ["ProjectSettings/ProjectVersion.txt"], artifact: "Library")
        makeProject("non-unity", manifests: ["package.json"], artifact: "Library")
        makeProject("xcode", manifests: ["App.xcodeproj"], artifact: "DerivedData")
        makeProject("swift", manifests: ["Package.swift"], artifact: ".build")
        makeProject("collegamento", manifests: ["package.json"], artifact: "vero")
        try? fm.createSymbolicLink(atPath: tmp + "/collegamento/node_modules",
                                   withDestinationPath: tmp + "/collegamento/vero")

        let artifactCases: [Case] = [
            .init(path: tmp + "/con-manifest/node_modules", shouldPass: true,
                  why: String(localized: "node_modules accanto a package.json")),
            .init(path: tmp + "/senza-manifest/node_modules", shouldPass: false,
                  why: String(localized: "node_modules senza file di progetto nel padre")),
            .init(path: tmp + "/con-manifest/src", shouldPass: false,
                  why: String(localized: "cartella «src»: nome non in elenco, potrebbe essere sorgente")),
            .init(path: home + "/Pictures/finto/node_modules", shouldPass: false,
                  why: String(localized: "protezione assoluta: mai nella libreria Foto")),
            .init(path: tmp + "/rust/target", shouldPass: true,
                  why: String(localized: "target accanto a Cargo.toml")),
            .init(path: tmp + "/node-target/target", shouldPass: false,
                  why: String(localized: "target accanto al solo package.json: manifest non corrispondente")),
            .init(path: tmp + "/repo-build/build", shouldPass: false,
                  why: String(localized: "build che contiene un .git: è un repository, non un output")),
            .init(path: tmp + "/progetto-build/build", shouldPass: false,
                  why: String(localized: "build che contiene un proprio package.json: è un progetto")),
            .init(path: tmp + "/unity/Library", shouldPass: true,
                  why: String(localized: "Library di Unity con ProjectSettings/ProjectVersion.txt")),
            .init(path: tmp + "/non-unity/Library", shouldPass: false,
                  why: String(localized: "Library senza progetto Unity")),
            .init(path: tmp + "/xcode/DerivedData", shouldPass: true,
                  why: String(localized: "DerivedData accanto a un .xcodeproj")),
            .init(path: tmp + "/swift/.build", shouldPass: true,
                  why: ".build accanto a Package.swift"),
            .init(path: tmp + "/collegamento/node_modules", shouldPass: false,
                  why: String(localized: "node_modules che è un collegamento simbolico")),
        ]

        for testCase in artifactCases {
            var passed: Bool
            var detail = ""
            do {
                try PathGuard.validateProjectArtifact(testCase.path)
                passed = true
            } catch {
                passed = false
                detail = error.localizedDescription
            }
            let correct = passed == testCase.shouldPass
            if !correct { failures += 1 }
            print("\(correct ? "✓" : "✗ ERRORE")  \(passed ? "CONSENTITO " : "RIFIUTATO  ") \(testCase.path)")
            print("       \(testCase.why)")
            if !correct && !detail.isEmpty { print("       motivo: \(detail)") }
        }

        // Verifica del motore su un file creato per l'occasione: la
        // simulazione non deve toccarlo, l'eliminazione reale deve rimuoverlo.
        print(String(repeating: "─", count: 72))
        print(String(localized: "Motore di eliminazione (su un file di prova creato ora)"))

        let sandbox = home + "/Library/Caches/ammugghia-selftest"
        try? fm.createDirectory(atPath: sandbox, withIntermediateDirectories: true)
        let probe = sandbox + "/prova.dat"
        fm.createFile(atPath: probe, contents: Data(repeating: 0, count: 2_000_000))
        defer { try? fm.removeItem(atPath: sandbox) }

        var engineFailures = 0
        var engineChecks = 0
        func check(_ condition: Bool, _ description: String) {
            engineChecks += 1
            if !condition { engineFailures += 1 }
            print("\(condition ? "✓" : "✗ ERRORE")  \(description)")
        }

        check(fm.fileExists(atPath: probe), String(localized: "file di prova creato in \(sandbox)"))

        let engine = DeletionEngine()
        // Le esclusioni dell'utente non devono cambiare l'esito dell'autotest.
        engine.exclusions = .empty
        let item = CleanupItem(
            title: String(localized: "File di prova dell'autotest"),
            detail: String(localized: "Creato dall'autotest."),
            consequence: "Nessuna.",
            action: .removePaths([probe]),
            risk: .safe,
            size: 2_000_000,
            perPathSize: [probe: 2_000_000])

        let dry = engine.execute(items: [item], mode: .permanent, dryRun: true)
        check(dry.first?.succeeded == true, String(localized: "la simulazione riporta esito positivo"))
        check(fm.fileExists(atPath: probe), String(localized: "dopo la simulazione il file è ancora al suo posto"))

        let real = engine.execute(items: [item], mode: .permanent, dryRun: false)
        check(real.first?.succeeded == true, String(localized: "l'eliminazione reale riporta esito positivo"))
        check(!fm.fileExists(atPath: probe), String(localized: "dopo l'eliminazione il file non esiste più"))

        // Un percorso protetto deve essere rifiutato anche arrivando
        // direttamente al motore, non solo in interfaccia.
        let forbidden = CleanupItem(
            title: String(localized: "Tentativo su percorso protetto"),
            detail: String(localized: "Verifica che il motore rifiuti anche ciò che l'interfaccia non permetterebbe."),
            consequence: String(localized: "Deve essere rifiutato."),
            action: .removePaths([home + "/Documents"]),
            risk: .safe, size: 0)
        let blocked = engine.execute(items: [forbidden], mode: .permanent, dryRun: false)
        check(blocked.first?.succeeded == false,
              String(localized: "il motore rifiuta ~/Documents anche se richiesto esplicitamente"))
        check(fm.fileExists(atPath: home + "/Documents"),
              String(localized: "la cartella Documenti è intatta"))

        // Identità: l'oggetto analizzato viene sostituito da un altro con lo
        // stesso nome prima dell'esecuzione. Il motore deve rifiutarlo e il
        // sostituto deve restare intatto.
        let swapped = sandbox + "/sostituita"
        try? fm.createDirectory(atPath: swapped, withIntermediateDirectories: true)
        let analysed = CleanupItem(
            title: String(localized: "Cartella analizzata e poi sostituita"),
            detail: String(localized: "Creata dall'autotest."), consequence: String(localized: "Deve essere rifiutata."),
            action: .removePaths([swapped]), risk: .safe, size: 0)
        check(analysed.identities[swapped] != nil, String(localized: "l'identità viene registrata alla creazione dell'elemento"))
        try? fm.removeItem(atPath: swapped)
        try? fm.createDirectory(atPath: swapped, withIntermediateDirectories: true)
        // Un file dentro tiene occupato l'inode della prima cartella anche se
        // il file system riusasse i numeri: qui serve un inode diverso.
        fm.createFile(atPath: swapped + "/segnale", contents: Data("x".utf8))
        if FileIdentity.of(swapped) == analysed.identities[swapped] {
            // Su alcuni file system l'inode può essere riusato subito: si
            // sostituisce con un collegamento, che ha comunque tipo diverso.
            try? fm.removeItem(atPath: swapped)
            try? fm.createSymbolicLink(atPath: swapped, withDestinationPath: sandbox)
        }
        let swappedResult = engine.execute(items: [analysed], mode: .permanent, dryRun: false)
        check(swappedResult.first?.succeeded == false,
              String(localized: "il motore rifiuta un percorso sostituito dopo l'analisi"))
        check(fm.fileExists(atPath: swapped) || (try? fm.destinationOfSymbolicLink(atPath: swapped)) != nil,
              String(localized: "il sostituto è ancora al suo posto"))

        // App in esecuzione: un elemento che richiede un'app chiusa viene
        // saltato, anche in simulazione, e il file non viene toccato.
        let guarded = sandbox + "/cache-app-aperta.dat"
        fm.createFile(atPath: guarded, contents: Data(repeating: 0, count: 1_000))
        let appItem = CleanupItem(
            title: String(localized: "Cache di un'app aperta"),
            detail: String(localized: "Creata dall'autotest."), consequence: String(localized: "Deve essere saltata."),
            action: .removePaths([guarded]), risk: .safe, size: 1_000,
            requiredStoppedApps: ["it.ammugghia.selftest.app-finta"])
        let runningEngine = DeletionEngine()
        runningEngine.exclusions = .empty
        runningEngine.isAppRunning = { $0 == "it.ammugghia.selftest.app-finta" }
        let blockedRun = runningEngine.execute(items: [appItem], mode: .permanent, dryRun: false)
        check(blockedRun.first?.skipped == true, String(localized: "l'elemento viene saltato se l'app richiesta è aperta"))
        check(fm.fileExists(atPath: guarded), String(localized: "il file dell'app aperta è intatto"))
        runningEngine.isAppRunning = { _ in false }
        let freeRun = runningEngine.execute(items: [appItem], mode: .permanent, dryRun: false)
        check(freeRun.first?.succeeded == true && !fm.fileExists(atPath: guarded),
              String(localized: "ad app chiusa la stessa eliminazione riesce"))

        // Cartelle temporanee: solo file vecchi, singoli, non esclusi, dentro
        // la cartella dell'utente. Il motore riceve un elenco preparato qui,
        // così l'autotest tocca soltanto i propri file.
        check(PathGuard.ageGatedRoots.count == 2, String(localized: "cartelle temporanee dell'utente ricavate dal sistema"))
        if let tempRoot = PathGuard.ageGatedRoots.first {
            let area = tempRoot + "/ammugghia-selftest-eta-\(UUID().uuidString)"
            try? fm.createDirectory(atPath: area + "/com.apple.prova.Sandbox", withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: area) }
            func make(_ name: String, daysAgo: Int) -> String {
                let path = area + "/" + name
                fm.createFile(atPath: path, contents: Data(repeating: 1, count: 4_096))
                let t = time(nil) - time_t(daysAgo * 86_400)
                var times = [timeval(tv_sec: t, tv_usec: 0), timeval(tv_sec: t, tv_usec: 0)]
                utimes(path, &times)
                return path
            }
            let old = make("vecchio.tmp", daysAgo: 30)
            let recent = make("recente.tmp", daysAgo: 1)
            let database = make("archivio.sqlite", daysAgo: 30)
            let sandboxed = make("com.apple.prova.Sandbox/profilo.bin", daysAgo: 30)
            let link = area + "/collegamento.tmp"
            try? fm.createSymbolicLink(atPath: link, withDestinationPath: old)
            let outside = sandbox + "/fuori-area.tmp"
            fm.createFile(atPath: outside, contents: Data(repeating: 1, count: 4_096))

            let listed = SystemScanner.agedFiles(in: tempRoot, olderThanDays: 7)
            check(listed[old] != nil || listed[PathGuard.realPath(old) ?? old] != nil,
                  String(localized: "lo scanner propone il file temporaneo vecchio"))
            check(!listed.keys.contains { $0.hasSuffix("/recente.tmp") || $0.hasSuffix("/archivio.sqlite")
                                         || $0.hasSuffix("/profilo.bin") || $0.hasSuffix("/collegamento.tmp") },
                  String(localized: "lo scanner esclude file recenti, database, cartelle di sistema e collegamenti"))

            var files: [String: AgedFile] = [:]
            for path in [old, recent, database, sandboxed, link, outside] {
                if let identity = FileIdentity.of(path) {
                    files[path] = AgedFile(identity: identity, size: 4_096)
                }
            }
            let agedItem = CleanupItem(
                title: String(localized: "File temporanei dell'autotest"),
                detail: String(localized: "Creati dall'autotest."), consequence: String(localized: "Solo il file vecchio deve sparire."),
                action: .removeAgedFiles(root: tempRoot, olderThanDays: 7, files: files),
                risk: .safe, size: 0)
            let agedRun = engine.execute(items: [agedItem], mode: .permanent, dryRun: false)
            check(agedRun.first?.succeeded == true && !fm.fileExists(atPath: old),
                  String(localized: "il file temporaneo vecchio viene eliminato"))
            check(fm.fileExists(atPath: recent) && fm.fileExists(atPath: database)
                  && fm.fileExists(atPath: sandboxed) && fm.fileExists(atPath: outside)
                  && (try? fm.destinationOfSymbolicLink(atPath: link)) != nil,
                  String(localized: "restano intatti: file recente, database, cartella di sistema, collegamento, file fuori area"))
        }

        // Residui di app: la decisione «orfano» è pura e si verifica con un
        // contesto finto, senza toccare i container veri.
        let orphanContext = OrphanScanner.Context(
            installed: ["com.tizio.editor"],
            isRegistered: { $0 == "com.altrove.app" },
            isRunning: { $0 == "com.attivo.app" })
        check(OrphanScanner.isOrphan("com.rimossa.app", in: orphanContext),
              String(localized: "residui: un'app assente ovunque è orfana"))
        check(!OrphanScanner.isOrphan("com.tizio.editor", in: orphanContext)
              && !OrphanScanner.isOrphan("com.tizio.editor.ShareExtension", in: orphanContext),
              String(localized: "residui: app installata e sue estensioni non sono orfane"))
        check(!OrphanScanner.isOrphan("com.altrove.app.Widget", in: orphanContext),
              String(localized: "residui: estensione di un'app registrata fuori da /Applications non è orfana"))
        check(!OrphanScanner.isOrphan("com.attivo.app", in: orphanContext),
              String(localized: "residui: un'app in esecuzione non è orfana"))
        check(!OrphanScanner.isOrphan("com.apple.Notes", in: orphanContext)
              && !OrphanScanner.isOrphan("group.com.apple.notes", in: orphanContext),
              String(localized: "residui: i container Apple non sono mai orfani"))
        check(!OrphanScanner.isOrphan("3F2504E0-4F89-11D3-9A0C-0305E82C3301", in: orphanContext),
              String(localized: "residui: un container con nome UUID illeggibile non viene proposto"))
        check(OrphanScanner.isTeamPrefixed("ABCDE12345.com.rimossa.app", "com.rimossa.app")
              && !OrphanScanner.isTeamPrefixed("group.altro.com.rimossa.app", "com.rimossa.app"),
              String(localized: "residui: gruppo condiviso riconosciuto solo nella forma TEAMID.<id>"))

        // Modelli Ollama: il nome passato a `ollama rm` deve essere esatto.
        check(AIModelScanner.ollamaName(registry: "/m/registry.ollama.ai", namespace: "/m/library",
                                        model: "/m/llama3", tag: "/m/8b") == "llama3:8b"
              && AIModelScanner.ollamaName(registry: "registry.ollama.ai", namespace: "utente",
                                           model: "mio", tag: "latest") == "utente/mio:latest"
              && AIModelScanner.ollamaName(registry: "hf.co", namespace: "org",
                                           model: "modello", tag: "Q4") == "hf.co/org/modello:Q4",
              String(localized: "modelli: nomi Ollama per libreria, utente e registri esterni"))

        // Indice del disco: misura identica a `du`, aggiornamento parziale
        // identico a un'analisi completa, indice corrotto rifatto da zero.
        let indexArea = tmp + "/indice"
        try? fm.createDirectory(atPath: indexArea + "/a/b", withIntermediateDirectories: true)
        fm.createFile(atPath: indexArea + "/a/uno.dat", contents: Data(repeating: 1, count: 300_000))
        fm.createFile(atPath: indexArea + "/a/b/due.dat", contents: Data(repeating: 2, count: 120_000))
        try? fm.linkItem(atPath: indexArea + "/a/uno.dat", toPath: indexArea + "/a/b/uno-link.dat")
        try? fm.createSymbolicLink(atPath: indexArea + "/link", withDestinationPath: sandbox)
        let duOutput = Shell.run("/usr/bin/du", ["-sk", indexArea], timeout: 30).stdout
        let duKB = Int64(duOutput.split(separator: "\t").first ?? "") ?? -1
        let storeFile = URL(fileURLWithPath: tmp + "/indice-test.bin")
        let store = DiskIndexStore(roots: [indexArea], storage: storeFile, sampleSize: 1_000, exclusions: { .empty })
        let first = store.refresh()
        let indexedKB = (store.level(at: nil)?.first?.size ?? -2) / 1024
        check(first.map { if case .full = $0.mode { return true } else { return false } } == true,
              String(localized: "indice: la prima volta è un'analisi completa"))
        check(indexedKB == duKB, String(localized: "indice: misura uguale a du (\(indexedKB) KB, du \(duKB) KB) con link fisici e simbolici"))

        fm.createFile(atPath: indexArea + "/a/b/nuovo.dat", contents: Data(repeating: 3, count: 200_000))
        try? fm.removeItem(atPath: indexArea + "/a/uno.dat")
        try? fm.createDirectory(atPath: indexArea + "/c/d", withIntermediateDirectories: true)
        fm.createFile(atPath: indexArea + "/c/d/tre.dat", contents: Data(repeating: 4, count: 50_000))
        // FSEvents consegna gli eventi al proprio database in modo asincrono.
        Thread.sleep(forTimeInterval: 2)
        let second = DiskIndexStore(roots: [indexArea], storage: storeFile, sampleSize: 0, exclusions: { .empty }).refresh()
        let incremental = DiskIndexStore(roots: [indexArea], storage: storeFile, sampleSize: 0, exclusions: { .empty })
        _ = incremental.level(at: nil)
        let reference = DiskIndexStore(roots: [indexArea],
                                       storage: URL(fileURLWithPath: tmp + "/indice-rif.bin"),
                                       exclusions: { .empty })
        _ = reference.refresh(forceFull: true)
        check(second.map { if case .incremental = $0.mode { return true } else { return false } } == true,
              String(localized: "indice: la seconda volta è un aggiornamento parziale via FSEvents"))
        check(!incremental.fingerprint().isEmpty && incremental.fingerprint() == reference.fingerprint(),
              String(localized: "indice: l'aggiornamento parziale coincide nodo per nodo con un'analisi completa"))

        try? Data("non è un indice".utf8).write(to: storeFile)
        let afterCorruption = DiskIndexStore(roots: [indexArea], storage: storeFile, exclusions: { .empty }).refresh()
        check(afterCorruption.map { if case .full = $0.mode { return true } else { return false } } == true,
              String(localized: "indice: un file corrotto viene ignorato e rifatto da zero"))

        // Duplicati: stessa dimensione e stessi campioni non bastano, serve
        // lo stesso contenuto. Link fisici e simbolici non sono duplicati, e
        // un clone APFS non spreca spazio.
        let dupArea = tmp + "/duplicati"
        try? fm.createDirectory(atPath: dupArea + "/sotto", withIntermediateDirectories: true)
        var content = Data((0..<1_200_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        fm.createFile(atPath: dupArea + "/originale.dat", contents: content)
        fm.createFile(atPath: dupArea + "/sotto/copia.dat", contents: content)
        try? fm.linkItem(atPath: dupArea + "/originale.dat", toPath: dupArea + "/sotto/link-fisico.dat")
        try? fm.createSymbolicLink(atPath: dupArea + "/link-simbolico.dat",
                                   withDestinationPath: dupArea + "/originale.dat")
        _ = clonefile(dupArea + "/originale.dat", dupArea + "/clone.dat", 0)
        // Diverso solo in un punto che i campioni non leggono: lo scarta
        // soltanto l'impronta completa.
        content[100_000] ^= 0xFF
        fm.createFile(atPath: dupArea + "/quasi-uguale.dat", contents: content)
        let groups = ContentDuplicateScanner.find(roots: [dupArea], minimumSize: 1_000_000)
        let names = Set(groups.first?.files.map { ($0.path as NSString).lastPathComponent } ?? [])
        check(groups.count == 1 && names == ["originale.dat", "copia.dat", "clone.dat"]
              || names == ["link-fisico.dat", "copia.dat", "clone.dat"],
              String(localized: "duplicati: un gruppo con originale, copia e clone; esclusi link e file quasi uguale"))
        check(groups.first?.recoverable == 1_200_000,
              String(localized: "duplicati: il clone APFS non conta come spazio sprecato (\(groups.first?.recoverable ?? -1) byte recuperabili)"))

        // Elementi d'avvio: il guardiano rifiuta servizi Apple, etichette
        // che potrebbero alterare il comando, file fuori posto o che dichiarano
        // un servizio diverso.
        let startupRoots = StartupScanner.Roots(userAgents: tmp + "/avvio/utente",
                                                globalAgents: tmp + "/avvio/globali",
                                                daemons: tmp + "/avvio/sistema")
        for dir in [startupRoots.userAgents, startupRoots.globalAgents, startupRoots.daemons] {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        func agent(_ label: String, in dir: String, file: String? = nil) -> String {
            let path = dir + "/" + (file ?? label) + ".plist"
            let plist: [String: Any] = ["Label": label, "ProgramArguments": ["/usr/bin/true"]]
            try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: URL(fileURLWithPath: path))
            return path
        }
        func startupItem(_ path: String, _ label: String, _ domain: StartupItem.Domain) -> StartupItem {
            StartupItem(plistPath: path, label: label, domain: domain, program: "/usr/bin/true",
                        programExists: true, ownerName: nil, signer: nil, runAtLoad: false,
                        keepAlive: false, interval: nil, isDisabled: false, isLoaded: false)
        }
        func accepted(_ item: StartupItem) -> Bool {
            (try? StartupGuard.validate(item, roots: startupRoots)) != nil
        }
        let valid = agent("it.ammugghia.prova", in: startupRoots.userAgents)
        check(accepted(startupItem(valid, "it.ammugghia.prova", .userAgent)),
              String(localized: "avvio: un agente valido nella sua cartella è modificabile"))
        check(!accepted(startupItem(agent("com.apple.finto", in: startupRoots.userAgents), "com.apple.finto", .userAgent)),
              String(localized: "avvio: i servizi di macOS non sono modificabili"))
        let injected = agent("it.prova; rm -rf ~", in: startupRoots.userAgents, file: "iniettato")
        check(!accepted(startupItem(injected, "it.prova; rm -rf ~", .userAgent)),
              String(localized: "avvio: un'etichetta con spazi o punto e virgola viene rifiutata"))
        check(!accepted(startupItem(valid, "it.ammugghia.prova", .daemon)),
              String(localized: "avvio: un agente utente non può essere trattato come servizio di sistema"))
        let other = agent("it.ammugghia.altro", in: startupRoots.globalAgents, file: "it.ammugghia.prova")
        check(!accepted(startupItem(other, "it.ammugghia.prova", .globalAgent)),
              String(localized: "avvio: il file deve dichiarare lo stesso servizio richiesto"))
        let linked = startupRoots.globalAgents + "/collegato.plist"
        try? fm.createSymbolicLink(atPath: linked, withDestinationPath: valid)
        check(!accepted(startupItem(linked, "it.ammugghia.prova", .globalAgent)),
              String(localized: "avvio: un file che è un collegamento viene rifiutato"))
        let overrides = StartupScanner.parseOverrides("""
            disabled services = {
                "com.tizio.uno" => disabled
                "com.tizio.due" => enabled
            }
            """)
        check(overrides == ["com.tizio.uno": true, "com.tizio.due": false],
              "avvio: lettura dello stato da launchctl print-disabled")

        // Esclusioni: possono solo togliere. Il motore rifiuta un percorso
        // escluso anche se PathGuard lo consentirebbe, e rifiuta la cartella
        // che contiene qualcosa di escluso.
        let keep = sandbox + "/da-tenere"
        try? fm.createDirectory(atPath: keep + "/dentro", withIntermediateDirectories: true)
        fm.createFile(atPath: keep + "/dentro/importante.dat", contents: Data(repeating: 5, count: 1_000))
        fm.createFile(atPath: sandbox + "/nota.importante", contents: Data(repeating: 6, count: 1_000))
        let rules = ExclusionSet(rules: [ExclusionRule(pattern: keep + "/dentro"),
                                         ExclusionRule(pattern: "*.importante")])
        let excludingEngine = DeletionEngine()
        excludingEngine.exclusions = rules
        let parentItem = CleanupItem(title: String(localized: "Cartella che contiene un'esclusione"), detail: "Autotest.",
                                     consequence: String(localized: "Deve essere rifiutata."), action: .removePaths([keep]),
                                     risk: .safe, size: 0)
        let globItem = CleanupItem(title: String(localized: "File escluso per nome"), detail: "Autotest.",
                                   consequence: String(localized: "Deve essere rifiutato."),
                                   action: .removePaths([sandbox + "/nota.importante"]), risk: .safe, size: 0)
        let excludedRun = excludingEngine.execute(items: [parentItem, globItem], mode: .permanent, dryRun: false)
        check(excludedRun.allSatisfy { !$0.succeeded } && fm.fileExists(atPath: keep + "/dentro/importante.dat")
              && fm.fileExists(atPath: sandbox + "/nota.importante"),
              String(localized: "esclusioni: il motore rifiuta la cartella che contiene un'esclusione e il file escluso per nome"))
        let mixed = CleanupItem(title: String(localized: "Voce mista"), detail: "Autotest.", consequence: "Autotest.",
                                action: .removePaths([sandbox + "/nota.importante", probe]), risk: .safe, size: 2,
                                perPathSize: [sandbox + "/nota.importante": 1, probe: 1])
        check(mixed.applying(rules)?.action.displayPaths == [probe],
              String(localized: "esclusioni: da una voce si tolgono solo i percorsi esclusi"))

        // Cronologia: scritta, riletta, e un file corrotto messo da parte
        // invece che sovrascritto. Ripristino dal Cestino verificato davvero.
        let historyFile = URL(fileURLWithPath: tmp + "/cronologia.json")
        let restoreProbe = sandbox + "/da-ripristinare.dat"
        fm.createFile(atPath: restoreProbe, contents: Data(repeating: 7, count: 2_000))
        let trashItem = CleanupItem(title: String(localized: "File da ripristinare"), detail: "Autotest.",
                                    consequence: String(localized: "Torna al suo posto."), action: .removePaths([restoreProbe]),
                                    risk: .safe, size: 2_000)
        let trashRun = engine.execute(items: [trashItem], mode: .trash, dryRun: false)
        let recorded = trashRun.first?.trashed[restoreProbe]
        check(recorded != nil && !fm.fileExists(atPath: restoreProbe),
              String(localized: "cronologia: lo spostamento nel Cestino registra dove è finito il file"))
        let history = HistoryStore(storage: historyFile)
        let entry = HistoryEntry(date: Date(), kind: .cleanup, origin: "Autotest", title: "Prova",
                                 paths: [restoreProbe], freed: 2_000, succeeded: true, skipped: false,
                                 message: "ok", mode: "Cestino", trashed: trashRun.first?.trashed ?? [:])
        history.append([entry])
        check(HistoryStore(storage: historyFile).all.count == 1, String(localized: "cronologia: la voce viene salvata e riletta"))
        try? HistoryStore(storage: historyFile).restore(entryID: entry.id, path: restoreProbe)
        check(fm.fileExists(atPath: restoreProbe) && recorded.map { !fm.fileExists(atPath: $0) } == true,
              String(localized: "cronologia: il ripristino rimette il file al suo posto"))
        try? Data("{ non è json".utf8).write(to: historyFile)
        // La lettura avviene al primo accesso: prima si legge, poi si guarda.
        let damagedIsEmpty = HistoryStore(storage: historyFile).all.isEmpty
        let aside = (try? fm.contentsOfDirectory(atPath: tmp))?.contains { $0.hasPrefix("history-v1.invalid-") } ?? false
        check(damagedIsEmpty && aside,
              String(localized: "cronologia: un file illeggibile viene messo da parte, non sovrascritto"))

        failures += engineFailures

        print(String(repeating: "─", count: 72))
        let total = cases.count + artifactCases.count + engineChecks
        if failures == 0 {
            print(String(localized: "✓ Tutti i \(total) controlli superati."))
            return 0
        }
        print(String(localized: "✗ \(failures) controlli su \(total) NON superati. Non usare questa build."))
        return 1
    }
}
