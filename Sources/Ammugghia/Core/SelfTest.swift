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
            .init(path: "/", shouldPass: false, why: "radice del disco"),
            .init(path: home, shouldPass: false, why: "cartella utente"),
            .init(path: "/Users", shouldPass: false, why: "cartella di tutti gli utenti"),
            .init(path: "/System", shouldPass: false, why: "sistema operativo"),
            .init(path: "/usr/bin", shouldPass: false, why: "binari di sistema"),
            .init(path: "/etc", shouldPass: false, why: "configurazione di sistema"),
            .init(path: home + "/Library", shouldPass: false, why: "intera libreria utente"),
            .init(path: "/Library", shouldPass: false, why: "intera libreria di sistema"),
            .init(path: "/Applications", shouldPass: false, why: "cartella Applicazioni"),

            // Deve rifiutare: dati personali.
            .init(path: home + "/Documents", shouldPass: false, why: "Documenti"),
            .init(path: home + "/Documents/fattura.pdf", shouldPass: false, why: "file in Documenti"),
            .init(path: home + "/Desktop/progetto", shouldPass: false, why: "cartella sulla Scrivania"),
            .init(path: home + "/Pictures/Foto Library.photoslibrary", shouldPass: false, why: "libreria Foto"),
            .init(path: home + "/Movies/vacanze.mov", shouldPass: false, why: "filmato personale"),
            .init(path: home + "/Music", shouldPass: false, why: "Musica"),
            .init(path: home + "/Downloads/installer.dmg", shouldPass: false, why: "file scaricato"),
            .init(path: home + "/.ssh/id_rsa", shouldPass: false, why: "chiave SSH"),
            .init(path: home + "/.gnupg", shouldPass: false, why: "chiavi GPG"),
            .init(path: home + "/.aws/credentials", shouldPass: false, why: "credenziali AWS"),
            .init(path: home + "/.config/qualcosa", shouldPass: false, why: "configurazioni"),
            .init(path: home + "/.claude", shouldPass: false, why: "dati di Claude Code"),
            .init(path: home + "/Library/Mobile Documents", shouldPass: false, why: "iCloud Drive"),
            .init(path: home + "/Library/Keychains", shouldPass: false, why: "portachiavi"),
            .init(path: home + "/Library/Mail", shouldPass: false, why: "archivio Mail"),
            .init(path: home + "/Library/Messages", shouldPass: false, why: "cronologia Messaggi"),
            .init(path: home + "/Library/Photos", shouldPass: false, why: "libreria Foto"),
            .init(path: home + "/Library/Safari/History.db", shouldPass: false, why: "cronologia Safari"),
            .init(path: home + "/Library/Application Support/MobileSync/Backup",
                  shouldPass: false, why: "backup dei dispositivi iOS"),

            // Deve rifiutare: percorsi malformati o fuori area.
            .init(path: "relativo/non/assoluto", shouldPass: false, why: "percorso relativo"),
            .init(path: "/opt", shouldPass: false, why: "fuori dalle aree consentite"),
            .init(path: "/private/var/vm/swapfile0", shouldPass: false, why: "file di swap"),
            .init(path: "/Volumes/Disco Esterno/dati", shouldPass: false, why: "disco esterno"),

            // Deve accettare: aree di cache legittime.
            .init(path: home + "/Library/Caches/qualcosa", shouldPass: true, why: "cache utente"),
            .init(path: home + "/Library/Developer/Xcode/DerivedData/App-abc",
                  shouldPass: true, why: "DerivedData di Xcode"),
            .init(path: home + "/Library/Developer/CoreSimulator/Devices/UUID",
                  shouldPass: true, why: "dispositivo simulato"),
            .init(path: home + "/.gradle/caches", shouldPass: true, why: "cache Gradle"),
            .init(path: home + "/.npm/_cacache", shouldPass: true, why: "cache npm"),
            .init(path: home + "/Library/Android/sdk/ndk/28.0", shouldPass: true, why: "NDK Android"),
            .init(path: "/Library/Developer/CoreSimulator/Caches/dyld",
                  shouldPass: true, why: "cache dyld dei simulatori"),
            .init(path: "/Library/Developer/CommandLineTools",
                  shouldPass: true, why: "Command Line Tools (reinstallabili da Apple)"),
            .init(path: "/Library/Preferences/com.apple.loginwindow.plist",
                  shouldPass: false, why: "preferenze di sistema: fuori allowlist di proposito"),
            .init(path: "/System/Volumes/Data/macOS Install Data",
                  shouldPass: true, why: "installer residuo (eccezione esplicita)"),
            .init(path: (PathGuard.ageGatedRoots.first ?? "/private/var/folders/xx/T") + "/qualcosa",
                  shouldPass: false, why: "cartelle temporanee: solo tramite la regola dei 7 giorni"),
            .init(path: "/private/var/folders", shouldPass: false,
                  why: "radice delle cartelle temporanee di tutti gli utenti"),
        ]

        print("Ammugghia — verifica delle protezioni")
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
        print("Artefatti di progetto (richiedono nome in elenco + file di progetto nel padre)")

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
                  why: "node_modules accanto a package.json"),
            .init(path: tmp + "/senza-manifest/node_modules", shouldPass: false,
                  why: "node_modules senza file di progetto nel padre"),
            .init(path: tmp + "/con-manifest/src", shouldPass: false,
                  why: "cartella «src»: nome non in elenco, potrebbe essere sorgente"),
            .init(path: home + "/Pictures/finto/node_modules", shouldPass: false,
                  why: "protezione assoluta: mai nella libreria Foto"),
            .init(path: tmp + "/rust/target", shouldPass: true,
                  why: "target accanto a Cargo.toml"),
            .init(path: tmp + "/node-target/target", shouldPass: false,
                  why: "target accanto al solo package.json: manifest non corrispondente"),
            .init(path: tmp + "/repo-build/build", shouldPass: false,
                  why: "build che contiene un .git: è un repository, non un output"),
            .init(path: tmp + "/progetto-build/build", shouldPass: false,
                  why: "build che contiene un proprio package.json: è un progetto"),
            .init(path: tmp + "/unity/Library", shouldPass: true,
                  why: "Library di Unity con ProjectSettings/ProjectVersion.txt"),
            .init(path: tmp + "/non-unity/Library", shouldPass: false,
                  why: "Library senza progetto Unity"),
            .init(path: tmp + "/xcode/DerivedData", shouldPass: true,
                  why: "DerivedData accanto a un .xcodeproj"),
            .init(path: tmp + "/swift/.build", shouldPass: true,
                  why: ".build accanto a Package.swift"),
            .init(path: tmp + "/collegamento/node_modules", shouldPass: false,
                  why: "node_modules che è un collegamento simbolico"),
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
        print("Motore di eliminazione (su un file di prova creato ora)")

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

        check(fm.fileExists(atPath: probe), "file di prova creato in \(sandbox)")

        let engine = DeletionEngine()
        let item = CleanupItem(
            title: "File di prova dell'autotest",
            detail: "Creato dall'autotest.",
            consequence: "Nessuna.",
            action: .removePaths([probe]),
            risk: .safe,
            size: 2_000_000,
            perPathSize: [probe: 2_000_000])

        let dry = engine.execute(items: [item], mode: .permanent, dryRun: true)
        check(dry.first?.succeeded == true, "la simulazione riporta esito positivo")
        check(fm.fileExists(atPath: probe), "dopo la simulazione il file è ancora al suo posto")

        let real = engine.execute(items: [item], mode: .permanent, dryRun: false)
        check(real.first?.succeeded == true, "l'eliminazione reale riporta esito positivo")
        check(!fm.fileExists(atPath: probe), "dopo l'eliminazione il file non esiste più")

        // Un percorso protetto deve essere rifiutato anche arrivando
        // direttamente al motore, non solo in interfaccia.
        let forbidden = CleanupItem(
            title: "Tentativo su percorso protetto",
            detail: "Verifica che il motore rifiuti anche ciò che l'interfaccia non permetterebbe.",
            consequence: "Deve essere rifiutato.",
            action: .removePaths([home + "/Documents"]),
            risk: .safe, size: 0)
        let blocked = engine.execute(items: [forbidden], mode: .permanent, dryRun: false)
        check(blocked.first?.succeeded == false,
              "il motore rifiuta ~/Documents anche se richiesto esplicitamente")
        check(fm.fileExists(atPath: home + "/Documents"),
              "la cartella Documenti è intatta")

        // Identità: l'oggetto analizzato viene sostituito da un altro con lo
        // stesso nome prima dell'esecuzione. Il motore deve rifiutarlo e il
        // sostituto deve restare intatto.
        let swapped = sandbox + "/sostituita"
        try? fm.createDirectory(atPath: swapped, withIntermediateDirectories: true)
        let analysed = CleanupItem(
            title: "Cartella analizzata e poi sostituita",
            detail: "Creata dall'autotest.", consequence: "Deve essere rifiutata.",
            action: .removePaths([swapped]), risk: .safe, size: 0)
        check(analysed.identities[swapped] != nil, "l'identità viene registrata alla creazione dell'elemento")
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
              "il motore rifiuta un percorso sostituito dopo l'analisi")
        check(fm.fileExists(atPath: swapped) || (try? fm.destinationOfSymbolicLink(atPath: swapped)) != nil,
              "il sostituto è ancora al suo posto")

        // App in esecuzione: un elemento che richiede un'app chiusa viene
        // saltato, anche in simulazione, e il file non viene toccato.
        let guarded = sandbox + "/cache-app-aperta.dat"
        fm.createFile(atPath: guarded, contents: Data(repeating: 0, count: 1_000))
        let appItem = CleanupItem(
            title: "Cache di un'app aperta",
            detail: "Creata dall'autotest.", consequence: "Deve essere saltata.",
            action: .removePaths([guarded]), risk: .safe, size: 1_000,
            requiredStoppedApps: ["it.ammugghia.selftest.app-finta"])
        let runningEngine = DeletionEngine()
        runningEngine.isAppRunning = { $0 == "it.ammugghia.selftest.app-finta" }
        let blockedRun = runningEngine.execute(items: [appItem], mode: .permanent, dryRun: false)
        check(blockedRun.first?.skipped == true, "l'elemento viene saltato se l'app richiesta è aperta")
        check(fm.fileExists(atPath: guarded), "il file dell'app aperta è intatto")
        runningEngine.isAppRunning = { _ in false }
        let freeRun = runningEngine.execute(items: [appItem], mode: .permanent, dryRun: false)
        check(freeRun.first?.succeeded == true && !fm.fileExists(atPath: guarded),
              "ad app chiusa la stessa eliminazione riesce")

        // Cartelle temporanee: solo file vecchi, singoli, non esclusi, dentro
        // la cartella dell'utente. Il motore riceve un elenco preparato qui,
        // così l'autotest tocca soltanto i propri file.
        check(PathGuard.ageGatedRoots.count == 2, "cartelle temporanee dell'utente ricavate dal sistema")
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
                  "lo scanner propone il file temporaneo vecchio")
            check(!listed.keys.contains { $0.hasSuffix("/recente.tmp") || $0.hasSuffix("/archivio.sqlite")
                                         || $0.hasSuffix("/profilo.bin") || $0.hasSuffix("/collegamento.tmp") },
                  "lo scanner esclude file recenti, database, cartelle di sistema e collegamenti")

            var files: [String: AgedFile] = [:]
            for path in [old, recent, database, sandboxed, link, outside] {
                if let identity = FileIdentity.of(path) {
                    files[path] = AgedFile(identity: identity, size: 4_096)
                }
            }
            let agedItem = CleanupItem(
                title: "File temporanei dell'autotest",
                detail: "Creati dall'autotest.", consequence: "Solo il file vecchio deve sparire.",
                action: .removeAgedFiles(root: tempRoot, olderThanDays: 7, files: files),
                risk: .safe, size: 0)
            let agedRun = engine.execute(items: [agedItem], mode: .permanent, dryRun: false)
            check(agedRun.first?.succeeded == true && !fm.fileExists(atPath: old),
                  "il file temporaneo vecchio viene eliminato")
            check(fm.fileExists(atPath: recent) && fm.fileExists(atPath: database)
                  && fm.fileExists(atPath: sandboxed) && fm.fileExists(atPath: outside)
                  && (try? fm.destinationOfSymbolicLink(atPath: link)) != nil,
                  "restano intatti: file recente, database, cartella di sistema, collegamento, file fuori area")
        }

        failures += engineFailures

        print(String(repeating: "─", count: 72))
        let total = cases.count + artifactCases.count + engineChecks
        if failures == 0 {
            print("✓ Tutti i \(total) controlli superati.")
            return 0
        }
        print("✗ \(failures) controlli su \(total) NON superati. Non usare questa build.")
        return 1
    }
}
