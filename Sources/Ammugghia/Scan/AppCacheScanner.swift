import Foundation

/// Cache delle applicazioni costruite su Electron o Chromium (Slack, Discord,
/// VS Code, Notion…) e di alcune app di uso comune.
///
/// Le app Electron non tengono la cache in `~/Library/Caches` ma dentro
/// `~/Library/Application Support/<app>`, accanto ai dati veri: per questo lo
/// scanner generico delle cache non le vede. Qui si elencano solo le
/// sottocartelle che Chromium ricostruisce da sé; database, impostazioni,
/// sessioni e `Local Storage` restano fuori per costruzione.
enum AppCacheScanner {

    /// Sottocartelle che Chromium rigenera senza perdita di dati. Valgono sia
    /// nella radice dell'app sia dentro ogni `Partitions/<nome>`.
    static let chromiumCacheNames = [
        "Cache", "Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache",
        "DawnWebGPUCache", "GrShaderCache", "GraphiteDawnCache", "ShaderCache",
        "Shared Dictionary/cache",
    ]

    /// Contenuti salvati per l'uso offline dai service worker: si riscaricano,
    /// ma finché non succede alcune app non funzionano senza rete.
    static let offlineCacheNames = ["Service Worker/CacheStorage", "Service Worker/ScriptCache"]

    struct ElectronApp {
        let name: String
        /// Cartella in `~/Library/Application Support`.
        let support: String?
        /// Cartelle in `~/Library/Caches`.
        let caches: [String]
        let bundleIDs: [String]
        /// Cache proprie dell'app, relative a `support`.
        var extra: [String] = []
    }

    static let electronApps: [ElectronApp] = [
        .init(name: "Slack", support: "Slack", caches: ["com.tinyspeck.slackmacgap"],
              bundleIDs: ["com.tinyspeck.slackmacgap"]),
        .init(name: "Discord", support: "discord", caches: ["com.hnc.Discord"],
              bundleIDs: ["com.hnc.Discord"]),
        .init(name: "Microsoft Teams", support: "Microsoft/Teams", caches: ["com.microsoft.teams2"],
              bundleIDs: ["com.microsoft.teams2"]),
        // VS Code e derivati condividono la struttura: `CachedData` è il codice
        // JavaScript precompilato per ogni versione, `CachedExtensionVSIXs` le
        // copie dei pacchetti delle estensioni già installate.
        .init(name: "Visual Studio Code", support: "Code", caches: ["com.microsoft.VSCode"],
              bundleIDs: ["com.microsoft.VSCode"], extra: ["CachedData", "CachedExtensionVSIXs"]),
        .init(name: "Cursor", support: "Cursor", caches: ["com.todesktop.230313mzl4w4u92"],
              bundleIDs: ["com.todesktop.230313mzl4w4u92"], extra: ["CachedData", "CachedExtensionVSIXs"]),
        .init(name: "VSCodium", support: "VSCodium", caches: ["com.vscodium"],
              bundleIDs: ["com.vscodium"], extra: ["CachedData", "CachedExtensionVSIXs"]),
        .init(name: "Windsurf", support: "Windsurf", caches: ["com.exafunction.windsurf"],
              bundleIDs: ["com.exafunction.windsurf"], extra: ["CachedData", "CachedExtensionVSIXs"]),
        .init(name: "Notion", support: "Notion", caches: ["notion.id"], bundleIDs: ["notion.id"]),
        .init(name: "Obsidian", support: "obsidian", caches: ["md.obsidian"], bundleIDs: ["md.obsidian"]),
        .init(name: "Figma", support: "Figma", caches: ["com.figma.Desktop"], bundleIDs: ["com.figma.Desktop"]),
        .init(name: "Postman", support: "Postman", caches: ["com.postmanlabs.mac"],
              bundleIDs: ["com.postmanlabs.mac"]),
        .init(name: "Insomnia", support: "Insomnia", caches: ["com.insomnia.app"],
              bundleIDs: ["com.insomnia.app"]),
        .init(name: "GitHub Desktop", support: "GitHub Desktop", caches: ["com.github.GitHubClient"],
              bundleIDs: ["com.github.GitHubClient"]),
        .init(name: "Claude", support: "Claude", caches: ["com.anthropic.claudefordesktop"],
              bundleIDs: ["com.anthropic.claudefordesktop"]),
        .init(name: "ChatGPT", support: nil, caches: ["com.openai.chat"], bundleIDs: ["com.openai.chat"]),
        .init(name: "Zoom", support: nil, caches: ["us.zoom.xos"], bundleIDs: ["us.zoom.xos"]),
        .init(name: "WhatsApp", support: nil, caches: ["net.whatsapp.WhatsApp"],
              bundleIDs: ["net.whatsapp.WhatsApp"]),
        .init(name: "Telegram", support: nil, caches: ["ru.keepcoder.Telegram"],
              bundleIDs: ["ru.keepcoder.Telegram"]),
    ]

    /// Bundle id degli IDE JetBrains: le loro cache stanno tutte sotto
    /// `~/Library/Caches/JetBrains`, una cartella per prodotto e versione, e
    /// non c'è un modo affidabile di risalire dal nome della cartella all'app.
    /// Si chiede quindi di chiuderli tutti.
    static let jetBrainsBundleIDs = [
        "com.jetbrains.intellij", "com.jetbrains.intellij.ce", "com.jetbrains.pycharm",
        "com.jetbrains.pycharm.ce", "com.jetbrains.WebStorm", "com.jetbrains.goland",
        "com.jetbrains.CLion", "com.jetbrains.rider", "com.jetbrains.PhpStorm",
        "com.jetbrains.rubymine", "com.jetbrains.datagrip", "com.jetbrains.rustrover",
        "com.jetbrains.fleet",
    ]

    /// Nomi in `~/Library/Caches` gestiti qui: lo scanner di sistema li esclude
    /// per non contarli due volte.
    static var libraryCacheNames: [String] {
        electronApps.flatMap(\.caches) + [
            "com.spotify.client", "JetBrains", "Google/AndroidStudio",
            "com.microsoft.Word", "com.microsoft.Excel", "com.microsoft.Powerpoint",
            "com.microsoft.Outlook", "Adobe",
        ]
    }

    static func scan() -> [CleanupItem] {
        let home = ScanSupport.home
        let support = home + "/Library/Application Support"
        let caches = home + "/Library/Caches"
        var items: [CleanupItem] = []

        for app in electronApps {
            var cachePaths: [String] = app.caches.map { caches + "/" + $0 }
            var offlinePaths: [String] = []
            if let folder = app.support {
                let root = support + "/" + folder
                let partitions = ScanSupport.children(of: root + "/Partitions")
                for base in [root] + partitions {
                    cachePaths += chromiumCacheNames.map { base + "/" + $0 }
                    offlinePaths += offlineCacheNames.map { base + "/" + $0 }
                }
                cachePaths += app.extra.map { root + "/" + $0 }
                // Rapporti di crash già inviati o in attesa: utili solo a chi
                // sviluppa l'app.
                cachePaths += ["Crashpad/completed", "Crashpad/pending"].map { root + "/" + $0 }
            }

            if let item = ScanSupport.item(
                title: "Cache di \(app.name)",
                detail: "Cache del motore web di \(app.name): pagine, immagini, codice JavaScript compilato e shader della scheda grafica.\n\nNON include messaggi, documenti, impostazioni, accessi o archivi locali dell'app: quelle cartelle non vengono toccate.",
                consequence: "Al prossimo avvio \(app.name) ricostruisce la cache: il primo avvio è più lento e le immagini si ricaricano. Resti connesso e non perdi dati.",
                paths: cachePaths, risk: .safe,
                requiredStoppedApps: app.bundleIDs, minBytes: 10_000_000) {
                items.append(item)
            }
            if let item = ScanSupport.item(
                title: "Contenuti offline di \(app.name)",
                detail: "Pagine e risorse che \(app.name) salva per funzionare anche senza connessione (cache dei service worker).",
                consequence: "\(app.name) li riscarica alla prossima apertura con la rete attiva. Finché non succede, i contenuti potrebbero non essere disponibili offline.",
                paths: offlinePaths, risk: .redownload,
                requiredStoppedApps: app.bundleIDs, minBytes: 10_000_000) {
                items.append(item)
            }
        }

        // Spotify tiene nella cache anche i brani scaricati per l'ascolto
        // offline: per questo non è una cache «sicura».
        if let item = ScanSupport.item(
            title: "Cache di Spotify",
            detail: "Brani ascoltati di recente e, se li hai scaricati, i brani disponibili offline.",
            consequence: "Spotify riscarica i brani quando li ascolti. Le playlist scaricate per l'uso offline vanno riscaricate.",
            paths: [caches + "/com.spotify.client"], risk: .redownload,
            requiredStoppedApps: ["com.spotify.client"], minBytes: 10_000_000) {
            items.append(item)
        }

        // IDE JetBrains e Android Studio: indici e cache dei progetti.
        let ideCaches = ScanSupport.children(of: caches + "/JetBrains")
        if let item = ScanSupport.item(
            title: "Cache degli IDE JetBrains",
            detail: "Indici dei progetti e cache di IntelliJ IDEA, PyCharm, WebStorm e degli altri IDE JetBrains, una cartella per prodotto e versione: quelle delle versioni non più installate restano sul disco.",
            consequence: "Alla prossima apertura di un progetto l'IDE ricostruisce l'indice: qualche minuto con autocompletamento e ricerca rallentati.",
            paths: ideCaches, risk: .safe,
            requiredStoppedApps: jetBrainsBundleIDs, minBytes: 10_000_000) {
            items.append(item)
        }
        let studioCaches = ScanSupport.children(of: caches + "/Google")
            .filter { ($0 as NSString).lastPathComponent.hasPrefix("AndroidStudio") }
        if let item = ScanSupport.item(
            title: "Cache di Android Studio",
            detail: "Indici e cache dei progetti di Android Studio, una cartella per versione: quelle delle versioni precedenti restano dopo ogni aggiornamento.",
            consequence: "Alla prossima apertura di un progetto Android Studio ricostruisce l'indice: qualche minuto più lento.",
            paths: studioCaches, risk: .safe,
            requiredStoppedApps: ["com.google.android.studio"], minBytes: 10_000_000) {
            items.append(item)
        }

        // Microsoft Office e Adobe: cache grandi ma lente da ricostruire.
        let officeIDs = ["com.microsoft.Word", "com.microsoft.Excel",
                         "com.microsoft.Powerpoint", "com.microsoft.Outlook"]
        if let item = ScanSupport.item(
            title: "Cache di Microsoft Office",
            detail: "Cache di Word, Excel, PowerPoint e Outlook: modelli, caratteri e componenti scaricati.",
            consequence: "Le app di Office riscaricano modelli e componenti quando servono. I documenti non vengono toccati.",
            paths: officeIDs.map { caches + "/" + $0 }, risk: .redownload,
            requiredStoppedApps: officeIDs, minBytes: 10_000_000) {
            items.append(item)
        }
        if let item = ScanSupport.item(
            title: "Cache multimediale di Adobe",
            detail: "File di anteprima audio e video generati da Premiere Pro, After Effects e Media Encoder (Media Cache).",
            consequence: "Alla riapertura dei progetti Adobe rigenera le anteprime: può richiedere parecchio tempo su progetti grandi. I progetti e i file originali non vengono toccati.",
            paths: [support + "/Adobe/Common/Media Cache Files", support + "/Adobe/Common/Media Cache"],
            risk: .redownload,
            warning: "Chiudi Premiere Pro, After Effects e Media Encoder prima di procedere.",
            minBytes: 10_000_000) {
            items.append(item)
        }

        return items.sorted { $0.size > $1.size }
    }
}
