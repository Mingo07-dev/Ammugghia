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

        let artifactCases: [Case] = [
            .init(path: tmp + "/con-manifest/node_modules", shouldPass: true,
                  why: "node_modules accanto a package.json"),
            .init(path: tmp + "/senza-manifest/node_modules", shouldPass: false,
                  why: "node_modules senza file di progetto nel padre"),
            .init(path: tmp + "/con-manifest/src", shouldPass: false,
                  why: "cartella «src»: nome non in elenco, potrebbe essere sorgente"),
            .init(path: home + "/Pictures/finto/node_modules", shouldPass: false,
                  why: "protezione assoluta: mai nella libreria Foto"),
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
        func check(_ condition: Bool, _ description: String) {
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

        failures += engineFailures

        print(String(repeating: "─", count: 72))
        let total = cases.count + artifactCases.count + 7
        if failures == 0 {
            print("✓ Tutti i \(total) controlli superati.")
            return 0
        }
        print("✗ \(failures) controlli su \(total) NON superati. Non usare questa build.")
        return 1
    }
}
