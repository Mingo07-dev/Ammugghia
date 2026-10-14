import Foundation

/// Cache dei gestori di pacchetti. Singolarmente piccole, insieme spesso
/// diversi GB.
enum PackageManagerScanner {

    static func scan() -> [CleanupItem] {
        let home = ScanSupport.home
        var items: [CleanupItem] = []

        let entries: [(String, [String], String, String, RiskLevel)] = [
            ("Cache npm", [home + "/.npm/_cacache"],
             "Pacchetti npm scaricati, condivisi tra tutti i progetti Node.",
             "Il prossimo `npm install` riscarica i pacchetti dal registry.", .redownload),
            ("Cache Yarn", [home + "/Library/Caches/Yarn", home + "/.yarn/berry/cache"],
             "Pacchetti scaricati da Yarn.",
             "Il prossimo `yarn install` riscarica le dipendenze.", .redownload),
            ("Store pnpm", [home + "/Library/pnpm/store"],
             "Archivio condiviso dei pacchetti pnpm.",
             "Il prossimo `pnpm install` riscarica i pacchetti. Attenzione: pnpm collega i node_modules a questo store, quindi i progetti esistenti vanno reinstallati.", .redownload),
            ("Cache pip", [home + "/Library/Caches/pip"],
             "Ruote e archivi dei pacchetti Python scaricati.",
             "Il prossimo `pip install` riscarica i pacchetti.", .redownload),
            ("Cache Homebrew", [home + "/Library/Caches/Homebrew"],
             "Archivi delle formule e dei cask scaricati da Homebrew.",
             "Nessuna: Homebrew riscarica al bisogno. È la cache che `brew cleanup` svuota.", .safe),
            ("Cache node-gyp", [home + "/Library/Caches/node-gyp"],
             "Header di Node scaricati per compilare i moduli nativi.",
             "La prossima compilazione di un modulo nativo li riscarica.", .redownload),
            ("Cache pub / Dart", [home + "/.pub-cache"],
             "Pacchetti Dart e Flutter scaricati, condivisi tra i progetti.",
             "Il prossimo `flutter pub get` riscarica le dipendenze di tutti i progetti.", .redownload),
            ("Repository Maven", [home + "/.m2/repository"],
             "Dipendenze Java e Kotlin scaricate da Maven.",
             "Il prossimo build Maven o Gradle riscarica le dipendenze.", .redownload),
            ("Registry Cargo", [home + "/.cargo/registry"],
             "Crate Rust scaricati.",
             "Il prossimo `cargo build` riscarica i crate.", .redownload),
            ("Cache RubyGems", [home + "/.gem"],
             "Gem Ruby scaricate.",
             "Il prossimo `gem install` o `bundle install` riscarica le gem.", .redownload),
            ("Server di analisi Dart", [home + "/.dartServer", home + "/.dart-tool"],
             "Indice e cache dell'analizzatore Dart.",
             "L'analizzatore ricostruisce l'indice all'apertura del progetto.", .safe),
            ("Cache Go", [home + "/Library/Caches/go-build", home + "/go/pkg/mod/cache"],
             "Cache di compilazione e moduli Go.",
             "La prossima compilazione Go è più lenta e riscarica i moduli.", .redownload),
            ("Cache Swift Package Manager (progetti)", [home + "/Library/org.swift.swiftpm"],
             "Copie di lavoro dei pacchetti Swift.",
             "Vengono ririsolte al prossimo build.", .redownload),
            ("Cache Bun", [home + "/.bun/install/cache"],
             "Pacchetti scaricati da Bun, condivisi tra i progetti.",
             "Il prossimo `bun install` riscarica i pacchetti.", .redownload),
            ("Cache Deno", [home + "/Library/Caches/deno"],
             "Moduli remoti e codice compilato da Deno.",
             "Deno riscarica e ricompila i moduli al prossimo avvio di uno script.", .redownload),
            ("Pacchetti eseguiti con npx", [home + "/.npm/_npx"],
             "Copie temporanee dei pacchetti avviati con `npx` senza installarli.",
             "Il prossimo `npx` dello stesso pacchetto lo riscarica.", .safe),
            ("Cache uv", [home + "/.cache/uv", home + "/Library/Caches/uv"],
             "Pacchetti Python e interpreti scaricati da uv.",
             "Il prossimo `uv sync` o `uv pip install` riscarica i pacchetti.", .redownload),
            ("Cache Poetry", [home + "/Library/Caches/pypoetry/artifacts", home + "/Library/Caches/pypoetry/cache"],
             "Archivi dei pacchetti Python scaricati da Poetry.",
             "Il prossimo `poetry install` riscarica i pacchetti.", .redownload),
            ("Download di pyenv", [home + "/.pyenv/cache"],
             "Sorgenti di Python scaricati da pyenv per compilare le versioni installate.",
             "Una nuova installazione della stessa versione li riscarica.", .redownload),
            ("Cache ruff e mypy", [home + "/.cache/ruff", home + "/.cache/mypy"],
             "Risultati delle analisi del codice Python.",
             "La prossima analisi riparte da zero ed è più lenta una volta.", .safe),
            ("Browser per i test (Playwright, Cypress)",
             [home + "/Library/Caches/ms-playwright", home + "/Library/Caches/ms-playwright-go",
              home + "/Library/Caches/Cypress"],
             "Copie di Chromium, Firefox e WebKit scaricate per i test automatici, una per versione della libreria.",
             "Il prossimo `npx playwright install` o `cypress install` li riscarica (centinaia di MB).", .redownload),
            ("Download di Electron", [home + "/Library/Caches/electron", home + "/.cache/electron"],
             "Pacchetti di Electron scaricati per compilare app desktop.",
             "Il prossimo build di un progetto Electron li riscarica.", .redownload),
            ("Corepack", [home + "/.cache/node/corepack"],
             "Versioni di Yarn e pnpm scaricate da Corepack.",
             "Corepack le riscarica al primo utilizzo.", .redownload),
            ("Cache di compilazione C/C++ (ccache, sccache)",
             [home + "/Library/Caches/ccache", home + "/Library/Caches/Mozilla.sccache"],
             "Oggetti compilati riutilizzati fra una build e l'altra.",
             "La prossima compilazione completa è più lenta.", .safe),
            ("Cache Composer", [home + "/Library/Caches/composer", home + "/.composer/cache"],
             "Pacchetti PHP scaricati da Composer.",
             "Il prossimo `composer install` riscarica i pacchetti.", .redownload),
            ("Pacchetti NuGet", [home + "/.nuget/packages"],
             "Pacchetti .NET scaricati, condivisi tra i progetti.",
             "Il prossimo `dotnet restore` riscarica i pacchetti.", .redownload),
            ("Cache Hex (Elixir)", [home + "/.hex/cache"],
             "Pacchetti Elixir ed Erlang scaricati.",
             "Il prossimo `mix deps.get` riscarica i pacchetti.", .redownload),
            ("Cache sbt e Ivy (Scala)", [home + "/.sbt/boot", home + "/.ivy2/cache"],
             "Dipendenze e versioni di sbt scaricate.",
             "Il prossimo build Scala riscarica le dipendenze.", .redownload),
            ("Cache mise", [home + "/Library/Caches/mise"],
             "Archivi scaricati da mise per installare le versioni degli strumenti.",
             "Una nuova installazione li riscarica.", .redownload),
            ("Repository git di Cargo", [home + "/.cargo/git/db"],
             "Copie dei repository git usati come dipendenze dai progetti Rust.",
             "Il prossimo `cargo build` li riclona.", .redownload),
        ]

        for (title, paths, detail, consequence, risk) in entries {
            if let item = ScanSupport.item(title: title, detail: detail,
                                           consequence: consequence, paths: paths, risk: risk) {
                items.append(item)
            }
        }

        // `~/.cache` è condivisa da molti strumenti: quelli riconosciuti hanno
        // una voce propria qui sopra, il resto finisce in una voce unica.
        // Elencare i figli uno per uno, invece della cartella intera, evita di
        // contare due volte gli stessi byte.
        let dotCache = home + "/.cache"
        let others = ScanSupport.children(of: dotCache, includeHidden: true).filter {
            !dotCacheHandled.contains(($0 as NSString).lastPathComponent)
        }
        if let item = ScanSupport.item(
            title: "Altre cache degli strumenti",
            detail: "Cartelle in ~/.cache usate da strumenti a riga di comando non riconosciuti singolarmente.",
            consequence: "Ogni strumento ricrea la propria cache al primo utilizzo.",
            paths: others, risk: .safe) {
            items.append(item)
        }

        // Homebrew: usa il comando ufficiale invece di cancellare a mano,
        // così l'indice interno resta coerente.
        if let brew = Shell.which("brew") {
            let dry = Shell.run(brew, ["cleanup", "--dry-run", "--prune=all"], timeout: 180)
            if dry.ok {
                let freed = parseBrewSize(dry.stdout)
                if freed > 5_000_000 {
                    items.append(CleanupItem(
                        title: "Pulizia Homebrew (versioni superate)",
                        detail: "Versioni vecchie delle formule installate e archivi scaricati. Homebrew conserva la versione precedente di ogni pacchetto dopo un aggiornamento.\n\nEsegue il comando ufficiale `brew cleanup --prune=all`, non un'eliminazione manuale: l'indice di Homebrew resta coerente.",
                        consequence: "Non puoi più tornare alla versione precedente di un pacchetto con `brew switch`. I pacchetti attivi non vengono toccati.",
                        action: .shell(tool: "brew", args: ["cleanup", "--prune=all"]),
                        risk: .safe, size: freed))
                }
            }
        }

        return items.sorted { $0.size > $1.size }
    }

    /// Sottocartelle di `~/.cache` con una voce dedicata.
    static let dotCacheHandled: Set<String> = ["uv", "ruff", "mypy", "electron", "node"]

    /// Nomi in `~/Library/Caches` gestiti qui: lo scanner di sistema li esclude.
    static let libraryCacheNames = [
        "pip", "Homebrew", "node-gyp", "Yarn", "go-build", "deno", "uv", "pypoetry",
        "ms-playwright", "ms-playwright-go", "Cypress", "electron", "ccache", "Mozilla.sccache", "composer", "mise",
    ]

    /// Estrae il totale dalla riga «This operation would free approximately
    /// 1.2GB of disk space».
    static func parseBrewSize(_ output: String) -> Int64 {
        let pattern = #"free approximately ([0-9.]+)\s?([KMGT]B)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              match.numberOfRanges == 3,
              let numRange = Range(match.range(at: 1), in: output),
              let unitRange = Range(match.range(at: 2), in: output),
              let value = Double(output[numRange]) else { return 0 }
        let multiplier: Double
        switch output[unitRange] {
        case "KB": multiplier = 1_000
        case "MB": multiplier = 1_000_000
        case "GB": multiplier = 1_000_000_000
        default: multiplier = 1_000_000_000_000
        }
        return Int64(value * multiplier)
    }
}

/// Cache dei browser. Cronologia, segnalibri e password non vengono mai
/// toccati: solo le cartelle di cache.
enum BrowserScanner {

    /// Sottocartelle di un profilo che sono pura cache.
    static let cacheSubdirectories = [
        "Cache", "Code Cache", "GPUCache", "GrShaderCache", "ShaderCache",
        "Service Worker/CacheStorage", "Service Worker/ScriptCache",
        "DawnCache", "DawnWebGPUCache", "component_crx_cache",
        "optimization_guide_model_store",
    ]

    static func scan() -> [CleanupItem] {
        let home = ScanSupport.home
        var items: [CleanupItem] = []

        // Browser basati su Chromium: la cache sta nei profili.
        // Il bundle id serve a bloccare la pulizia finché il browser è aperto:
        // un browser in esecuzione riscrive la cache mentre la si elimina.
        let chromium: [(String, String, String)] = [
            ("Google Chrome", home + "/Library/Application Support/Google/Chrome", "com.google.Chrome"),
            ("Microsoft Edge", home + "/Library/Application Support/Microsoft Edge", "com.microsoft.edgemac"),
            ("Brave", home + "/Library/Application Support/BraveSoftware/Brave-Browser", "com.brave.Browser"),
            ("Arc", home + "/Library/Application Support/Arc/User Data", "company.thebrowser.Browser"),
            ("Chromium", home + "/Library/Application Support/Chromium", "org.chromium.Chromium"),
            ("Opera", home + "/Library/Application Support/com.operasoftware.Opera", "com.operasoftware.Opera"),
        ]

        for (name, base, bundleID) in chromium {
            guard ScanSupport.isDirectory(base) else { continue }
            var paths: [String] = []
            // I profili sono "Default", "Profile 1", … più la radice.
            let profiles = ["Default"] + ScanSupport.children(of: base)
                .filter { ($0 as NSString).lastPathComponent.hasPrefix("Profile ") }
                .map { ($0 as NSString).lastPathComponent }
            for profile in Set(profiles) {
                for sub in cacheSubdirectories {
                    let p = base + "/" + profile + "/" + sub
                    if ScanSupport.exists(p) { paths.append(p) }
                }
            }
            // Cache fuori dal profilo.
            let external = home + "/Library/Caches/" + {
                switch name {
                case "Google Chrome": return "Google/Chrome"
                case "Microsoft Edge": return "Microsoft Edge"
                case "Brave": return "BraveSoftware/Brave-Browser"
                default: return name
                }
            }()
            if ScanSupport.exists(external) { paths.append(external) }

            if let item = ScanSupport.item(
                title: "Cache \(name)",
                detail: "Pagine, immagini e script memorizzati da \(name), più le cache di compilazione JavaScript.\n\nNON include cronologia, segnalibri, password, cookie di sessione o estensioni: quelle cartelle non vengono toccate.",
                consequence: "I siti si ricaricano da zero la prima volta. Resti connesso ai servizi: le sessioni non sono nella cache.",
                paths: paths, risk: .safe, requiredStoppedApps: [bundleID]) {
                items.append(item)
            }
        }

        // Firefox.
        let firefoxCache = home + "/Library/Caches/Firefox/Profiles"
        if let item = ScanSupport.item(
            title: "Cache Firefox",
            detail: "Cache dei profili Firefox. Cronologia e password restano intatte (sono in Application Support).",
            consequence: "I siti si ricaricano da zero la prima volta.",
            path: firefoxCache, risk: .safe, requiredStoppedApps: ["org.mozilla.firefox"]) {
            items.append(item)
        }

        // Safari: solo la cache, mai la cronologia. Richiede spesso
        // «Accesso completo al disco».
        let safariCaches = [
            home + "/Library/Caches/com.apple.Safari",
            home + "/Library/Containers/com.apple.Safari/Data/Library/Caches",
        ]
        if let item = ScanSupport.item(
            title: "Cache Safari",
            detail: "Cache delle pagine di Safari. Cronologia, segnalibri, elenco Letture e password non vengono toccati.",
            consequence: "I siti si ricaricano da zero la prima volta.",
            paths: safariCaches, risk: .safe,
            warning: "Safari è protetto dal sistema: se l'eliminazione non riesce, concedi «Accesso completo al disco» a Ammugghia.",
            requiredStoppedApps: ["com.apple.Safari"]) {
            items.append(item)
        }

        return items.sorted { $0.size > $1.size }
    }
}
