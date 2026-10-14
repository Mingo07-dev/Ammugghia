import Foundation

/// Residui e cache di sistema, comprese le voci che le Impostazioni di macOS
/// contano come «dati di sistema» senza mostrarle da nessuna parte.
enum SystemScanner {

    static func scan() -> [CleanupItem] {
        let home = ScanSupport.home
        var items: [CleanupItem] = []

        // Installer di macOS rimasto sul disco dopo un aggiornamento.
        let installData = "/System/Volumes/Data/macOS Install Data"
        if ScanSupport.isDirectory(installData) {
            let size = Shell.diskSize(installData)
            if size >= 100_000_000 {
                let pending = pendingSystemUpdate()
                let installedDate = ScanSupport.modificationDate(installData)
                let isStale: Bool = {
                    guard let installedDate else { return false }
                    return Date().timeIntervalSince(installedDate) > 14 * 86_400
                }()
                var warning: String?
                if let pending, !isStale {
                    warning = "C'è un aggiornamento in attesa (\(pending)) e questa cartella è recente: "
                            + "potrebbe contenerne il download. Eliminandola l'aggiornamento va riscaricato. "
                            + "Meglio installare prima l'aggiornamento."
                } else if let pending {
                    warning = "C'è un aggiornamento in attesa (\(pending)) ma questa cartella risale a "
                            + "\(DateFormat.string(installedDate)), quindi è il residuo di un'installazione già completata."
                }
                let cmd = "rm -rf " + Shell.shellQuote(installData)
                items.append(CleanupItem(
                    title: "Installer di macOS residuo",
                    detail: "Copia del programma di installazione di macOS lasciata sul disco dopo un aggiornamento di sistema. Non è visibile nel Finder e le Impostazioni la contano fra i «dati di sistema».\n\nCartella creata il \(DateFormat.string(installedDate)). Sistema attualmente installato: \(currentSystemVersion()).",
                    consequence: "Nessuna, se l'aggiornamento a cui si riferisce è già stato installato. Se invece è un download in attesa, l'aggiornamento va riscaricato.",
                    action: .privileged(shellCommand: cmd, displayPaths: [installData]),
                    risk: .safe, size: size, perPathSize: [installData: size],
                    lastUsed: installedDate, warning: warning))
            }
        }

        // Cache utente generiche: un elemento per le più grosse, così si vede
        // a chi appartengono.
        let cachesRoot = home + "/Library/Caches"
        if ScanSupport.isDirectory(cachesRoot) {
            let kids = ScanSupport.children(of: cachesRoot)
            let sizes = Shell.diskSizes(kids)
            // Le cache già gestite da scanner dedicati non vanno duplicate qui.
            let handled = ["Google", "CocoaPods", "com.apple.dt.Xcode", "org.swift.swiftpm",
                           "Firefox", "com.apple.Safari", "Microsoft Edge", "BraveSoftware"]
                + PackageManagerScanner.libraryCacheNames
                + AppCacheScanner.libraryCacheNames
                + OrphanScanner.orphanBundleIDs()
                + systemServiceCaches + ["com.apple.e5rt.e5bundlecache",
                                         "com.apple.QuickLook.thumbnailcache", "com.apple.iTunes"]
            for kid in kids {
                let name = (kid as NSString).lastPathComponent
                guard !handled.contains(name) else { continue }
                let size = sizes[kid] ?? 0
                guard size >= 200_000_000 else { continue }
                items.append(CleanupItem(
                    title: "Cache di \(friendlyName(name))",
                    detail: "Cartella di cache dell'applicazione «\(name)».",
                    consequence: "L'applicazione ricostruisce la propria cache al prossimo avvio. Alcune app perdono contenuti scaricati per l'uso offline.",
                    action: .removePaths([kid]), risk: .safe, size: size,
                    perPathSize: [kid: size], lastUsed: ScanSupport.modificationDate(kid)))
            }
        }

        // Stato delle finestre e log.
        let misc: [(String, [String], String, String, RiskLevel)] = [
            ("Stato salvato delle applicazioni", [home + "/Library/Saved Application State"],
             "Posizione delle finestre e documenti riaperti automaticamente da ciascuna app.",
             "Le app si riaprono con le finestre in posizione predefinita invece di ripristinare la sessione precedente.", .safe),
            ("Log delle applicazioni", [home + "/Library/Logs"],
             "Log diagnostici scritti dalle applicazioni.",
             "Perdi le informazioni utili a diagnosticare problemi già avvenuti.", .safe),
            ("Cache anteprime QuickLook", [home + "/Library/Caches/com.apple.QuickLook.thumbnailcache"],
             "Miniature generate per l'anteprima dei file nel Finder.",
             "Il Finder rigenera le miniature scorrendo le cartelle.", .safe),
            ("Allegati Mail scaricati", [home + "/Library/Containers/com.apple.mail/Data/Library/Mail Downloads"],
             "Allegati aperti da Mail e salvati in una cartella temporanea.",
             "Gli allegati restano sul server e si riscaricano aprendo di nuovo il messaggio.", .safe),
            ("Cache dei servizi di sistema",
             systemServiceCaches.map { home + "/Library/Caches/" + $0 }
                + [home + "/Library/Containers/com.apple.mediaanalysisd/Data/Library/Caches"],
             "Cache di Mappe e posizione (GeoServices), App Store e Apple Music (AppleMediaServices), Aiuto di macOS, suggerimenti di Spotlight e analisi delle foto.",
             "macOS le ricostruisce in background: Mappe e Spotlight possono essere un po' più lenti per qualche minuto.", .safe),
            ("Modelli di Apple Intelligence (cache)", [home + "/Library/Caches/com.apple.e5rt.e5bundlecache"],
             "Versioni compilate dei modelli di Apple Intelligence per questo Mac.",
             "macOS le ricompila al prossimo utilizzo delle funzioni di Apple Intelligence: la prima richiesta è più lenta.", .redownload),
            ("Cache di iOS/iPadOS in Finder", [home + "/Library/Caches/com.apple.iTunes", home + "/Library/iTunes/iPhone Software Updates", home + "/Library/iTunes/iPad Software Updates"],
             "File .ipsw degli aggiornamenti iOS scaricati per il ripristino dei dispositivi.",
             "Vengono riscaricati al prossimo ripristino di un dispositivo (diversi GB).", .redownload),
        ]
        for (title, paths, detail, consequence, risk) in misc {
            if let item = ScanSupport.item(title: title, detail: detail,
                                           consequence: consequence, paths: paths, risk: risk) {
                items.append(item)
            }
        }

        // Backup dei dispositivi iOS: dati dell'utente, spesso decine di GB.
        let backupBase = home + "/Library/Application Support/MobileSync/Backup"
        if ScanSupport.isDirectory(backupBase) {
            let backups = ScanSupport.children(of: backupBase)
            let sizes = Shell.diskSizes(backups)
            for backup in backups {
                let size = sizes[backup] ?? 0
                guard size >= 100_000_000 else { continue }
                let deviceName = ScanSupport.plistValue(backup + "/Info.plist", key: "Device Name")
                    ?? (backup as NSString).lastPathComponent
                items.append(CleanupItem(
                    title: "Backup di «\(deviceName)»",
                    detail: "Backup locale completo di un dispositivo iOS: foto, messaggi, dati delle app.",
                    consequence: "IRREVERSIBILE. Se il dispositivo si guasta o viene smarrito non puoi ripristinarlo da questo backup. Verifica di avere un backup su iCloud prima di procedere.",
                    action: .removePaths([backup]), risk: .userData, size: size,
                    perPathSize: [backup: size], lastUsed: ScanSupport.modificationDate(backup),
                    warning: "Questa cartella è normalmente protetta. Viene mostrata solo per informazione: valuta con attenzione prima di selezionarla."))
            }
        }

        // Cestino.
        let trash = home + "/.Trash"
        if ScanSupport.isDirectory(trash) {
            let kids = ScanSupport.children(of: trash, includeHidden: true)
            if !kids.isEmpty {
                let sizes = Shell.diskSizes(kids)
                let total = sizes.values.reduce(0, +)
                if total >= 10_000_000 {
                    items.append(CleanupItem(
                        title: "Svuota il Cestino (\(kids.count) element\(kids.count == 1 ? "o" : "i"))",
                        detail: "Contenuto del Cestino. Finché resta qui, occupa spazio sul disco.",
                        consequence: "IRREVERSIBILE: i file nel Cestino vengono eliminati definitivamente.",
                        action: .removePaths(kids), risk: .userData, size: total,
                        perPathSize: sizes, lastUsed: ScanSupport.modificationDate(trash)))
                }
            }
        }

        items += stalePartialDownloads()
        items += agedTemporaryFiles()

        // Solo informativo: snapshot locali di Time Machine.
        return items.sorted { $0.size > $1.size }
    }

    /// Cache di servizi Apple in `~/Library/Caches` raccolte in una voce.
    static let systemServiceCaches = [
        "GeoServices", "com.apple.AppleMediaServices", "com.apple.helpd", "com.apple.parsecd",
    ]

    /// Download interrotti in `~/Downloads`. È un'area documenti: l'elenco
    /// serve solo a mostrarli, l'eliminazione resta all'utente nel Finder.
    static func stalePartialDownloads(olderThanDays days: Int = 7) -> [CleanupItem] {
        let downloads = ScanSupport.home + "/Downloads"
        guard let findTool = Shell.which("find"), ScanSupport.isDirectory(downloads) else { return [] }
        let r = Shell.run(findTool, [downloads, "-maxdepth", "3",
                                     "(", "-name", "*.crdownload", "-o", "-name", "*.download",
                                     "-o", "-name", "*.part", "-o", "-name", "*.partial", ")",
                                     "-mtime", "+\(days)", "-prune", "-print"], timeout: 60)
        let paths = r.stdout.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        guard !paths.isEmpty else { return [] }
        let sizes = Shell.diskSizes(paths)
        return paths.prefix(30).map { path in
            CleanupItem(
                title: "Download interrotto: \((path as NSString).lastPathComponent)",
                detail: "File lasciato da un download mai completato in \((path as NSString).deletingLastPathComponent).",
                consequence: "Questo software non elimina file nella cartella Download: usa «Mostra nel Finder» e decidi tu.",
                action: .revealOnly([path]), risk: .userData, size: sizes[path] ?? 0,
                perPathSize: [path: sizes[path] ?? 0],
                lastUsed: ScanSupport.modificationDate(path), preselect: false)
        }
    }

    /// File temporanei dell'utente in `/var/folders` non usati da più di una
    /// settimana. Si raccolgono qui i candidati con la stessa funzione che il
    /// motore userà per ricontrollarli: un solo criterio, in un solo punto.
    static func agedTemporaryFiles(olderThanDays days: Int = 7) -> [CleanupItem] {
        var items: [CleanupItem] = []
        for (index, root) in PathGuard.ageGatedRoots.enumerated() {
            let files = agedFiles(in: root, olderThanDays: days)
            let total = files.values.reduce(0) { $0 + $1.size }
            guard total >= 10_000_000 else { continue }
            let isTemp = index == 0
            items.append(CleanupItem(
                title: isTemp ? "File temporanei vecchi" : "Cache temporanee vecchie",
                detail: (isTemp
                    ? "File temporanei che le app lasciano nella cartella riservata al tuo utente in /var/folders, e che macOS non sempre rimuove."
                    : "Cache per utente che macOS e le app tengono in /var/folders.")
                    + "\n\nSolo file singoli non modificati né letti da più di \(days) giorni. Database, preferenze, file di blocco e cartelle di sistema restano esclusi. Ogni file viene ricontrollato al momento dell'eliminazione.",
                consequence: "Nessuna per le app chiuse. Un'app che tiene aperto un file da più di una settimana continua a usarlo finché non lo chiude. Lo spazio si libera subito solo con «Elimina definitivamente».",
                action: .removeAgedFiles(root: root, olderThanDays: days, files: files),
                risk: .safe, size: total, perPathSize: [root: total],
                // Area nuova e poco visibile: l'utente la sceglie leggendo la nota.
                preselect: false))
        }
        return items
    }

    static func agedFiles(in root: String, olderThanDays days: Int) -> [String: AgedFile] {
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: [.isDirectoryKey, .totalFileAllocatedSizeKey],
            options: [],
            errorHandler: { _, _ in true }) else { return [:] }
        var files: [String: AgedFile] = [:]
        let now = Date()
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .totalFileAllocatedSizeKey])
            if values?.isDirectory == true {
                if PathGuard.isExcludedTemporaryComponent(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            let path = url.path
            guard (try? PathGuard.validateAgedFile(path, root: root, olderThanDays: days, now: now)) != nil,
                  let identity = FileIdentity.of(path) else { continue }
            files[path] = AgedFile(identity: identity,
                                   size: Int64(values?.totalFileAllocatedSize ?? 0))
        }
        return files
    }

    /// Snapshot APFS locali. Non li elimina: mostra solo quanto occupano,
    /// perché macOS li rimuove da sé quando lo spazio serve.
    static func localSnapshotsNote() -> String? {
        guard let tmutil = Shell.which("tmutil") else { return nil }
        let r = Shell.run(tmutil, ["listlocalsnapshots", "/"], timeout: 30)
        let lines = r.stdout.split(separator: "\n")
            .filter { $0.contains("com.apple.TimeMachine") }
        guard !lines.isEmpty else { return nil }
        return "\(lines.count) snapshot locali di Time Machine presenti. Non vengono eliminati da questo software: "
             + "macOS li rimuove automaticamente quando lo spazio serve. Per forzarne la rimozione: "
             + "sudo tmutil thinlocalsnapshots / 10000000000 4"
    }

    static func currentSystemVersion() -> String {
        let r = Shell.run("/usr/bin/sw_vers", ["-productVersion"], timeout: 15)
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Titolo dell'aggiornamento di sistema in attesa, se presente.
    static func pendingSystemUpdate() -> String? {
        let r = Shell.run("/usr/sbin/softwareupdate", ["--list"], timeout: 120)
        let combined = r.stdout + r.stderr
        guard combined.contains("Label:") else { return nil }
        for line in combined.split(separator: "\n") where line.contains("Title:") {
            let parts = line.split(separator: ",")
            if let titlePart = parts.first(where: { $0.contains("Title:") }) {
                return titlePart.replacingOccurrences(of: "Title:", with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return "aggiornamento disponibile"
    }

    /// Nomi tecnici in qualcosa di leggibile: «com.spotify.client» → «Spotify».
    static func friendlyName(_ bundleName: String) -> String {
        guard bundleName.contains(".") else { return bundleName }
        let parts = bundleName.split(separator: ".")
        guard parts.count >= 2 else { return bundleName }
        let candidate = parts.count >= 3 ? String(parts[2]) : String(parts[1])
        return candidate.prefix(1).uppercased() + candidate.dropFirst() + " (\(bundleName))"
    }
}

/// Sfondi dinamici. Questa categoria esiste per un motivo specifico: la
/// cartella si riempie da sola e la configurazione va letta prima di
/// cancellare, altrimenti macOS riscarica tutto.
enum WallpaperScanner {

    struct Config {
        var desktopUsesAerials = false
        var screensaverUsesAerials = false
        var desktopShuffle: String?
        var screensaverShuffle: String?
        var activeAssetIDs: Set<String> = []
    }

    static func readConfig() -> Config {
        var config = Config()
        let path = ScanSupport.home + "/Library/Application Support/com.apple.wallpaper/Store/Index.plist"
        guard let root = ScanSupport.plistAsJSON(path) as? [String: Any] else { return config }

        // La configurazione compare in AllSpacesAndDisplays e ripetuta per
        // ogni schermo: basta che uno slot usi gli aerial.
        var slots: [(String, [String: Any])] = []
        func collect(_ container: [String: Any]) {
            for key in ["Desktop", "Idle"] {
                if let slot = container[key] as? [String: Any] { slots.append((key, slot)) }
            }
        }
        if let all = root["AllSpacesAndDisplays"] as? [String: Any] { collect(all) }
        if let displays = root["Displays"] as? [String: Any] {
            for (_, v) in displays { if let d = v as? [String: Any] { collect(d) } }
        }
        if let spaces = root["Spaces"] as? [String: Any] {
            for (_, v) in spaces { if let d = v as? [String: Any] { collect(d) } }
        }

        for (kind, slot) in slots {
            guard let content = slot["Content"] as? [String: Any] else { continue }
            let choices = content["Choices"] as? [[String: Any]] ?? []
            for choice in choices {
                let provider = choice["Provider"] as? String ?? ""
                let isAerial = provider.contains("aerials")
                if isAerial {
                    if kind == "Desktop" { config.desktopUsesAerials = true }
                    else { config.screensaverUsesAerials = true }
                }
                // L'assetID è in un plist annidato dentro un Data.
                if let data = choice["Configuration"] as? Data,
                   let inner = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                   let assetID = inner["assetID"] as? String {
                    config.activeAssetIDs.insert(assetID)
                }
            }
            // La frequenza di rotazione spiega perché la cartella cresce.
            if let data = content["EncodedOptionValues"] as? Data,
               let inner = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
               let values = inner["values"] as? [String: Any],
               let freq = values["aerialShuffleFrequency"] as? [String: Any],
               let picker = freq["picker"] as? [String: Any],
               let zero = picker["_0"] as? [String: Any],
               let id = zero["id"] as? String {
                if kind == "Desktop" { config.desktopShuffle = id } else { config.screensaverShuffle = id }
            }
        }
        return config
    }

    /// I nomi leggibili dei video scaricati, letti dal catalogo del sistema.
    static func assetNames() -> [String: String] {
        let manifest = ScanSupport.home
            + "/Library/Application Support/com.apple.wallpaper/aerials/manifest/entries.json"
        guard let root = ScanSupport.jsonObject(fromFile: manifest) as? [String: Any],
              let assets = root["assets"] as? [[String: Any]] else { return [:] }
        var map: [String: String] = [:]
        for asset in assets {
            guard let id = asset["id"] as? String else { continue }
            map[id] = asset["accessibilityLabel"] as? String ?? "sfondo dinamico"
        }
        return map
    }

    static func scan() -> [CleanupItem] {
        let videos = ScanSupport.home
            + "/Library/Application Support/com.apple.wallpaper/aerials/videos"
        guard ScanSupport.isDirectory(videos) else { return [] }
        let files = ScanSupport.children(of: videos).filter { $0.hasSuffix(".mov") }
        guard !files.isEmpty else { return [] }

        let config = readConfig()
        let names = assetNames()
        let sizes = Shell.diskSizes(files)
        var items: [CleanupItem] = []

        // L'avvertimento che vale l'intera categoria: se uno dei due slot usa
        // ancora gli aerial, cancellare è inutile perché si riscaricano.
        var stillInUse: [String] = []
        if config.desktopUsesAerials { stillInUse.append("lo sfondo del desktop") }
        if config.screensaverUsesAerials { stillInUse.append("il salvaschermo") }

        let shuffleNote: String = {
            var parts: [String] = []
            if let f = config.desktopShuffle { parts.append("desktop: \(shuffleLabel(f))") }
            if let f = config.screensaverShuffle { parts.append("salvaschermo: \(shuffleLabel(f))") }
            return parts.isEmpty ? "" : " Rotazione impostata su — " + parts.joined(separator: ", ") + "."
        }()

        let warning: String? = stillInUse.isEmpty ? nil :
            "Attenzione: \(stillInUse.joined(separator: " e ")) usa\(stillInUse.count > 1 ? "no" : "") ancora "
            + "gli sfondi dinamici.\(shuffleNote) Se elimini i video ora, macOS li riscarica automaticamente "
            + "e in poche settimane la cartella torna come prima. Cambia prima l'impostazione in "
            + "Impostazioni di Sistema → Sfondo e → Salvaschermo, scegliendo un'immagine statica."

        for file in files {
            let id = ((file as NSString).lastPathComponent as NSString).deletingPathExtension
            let size = sizes[file] ?? 0
            let name = names[id] ?? "sfondo dinamico"
            let isActive = config.activeAssetIDs.contains(id)
            items.append(CleanupItem(
                title: "Sfondo dinamico «\(name)»" + (isActive ? " — attualmente selezionato" : ""),
                detail: "Video 4K scaricato da Apple per lo sfondo dinamico o il salvaschermo."
                    + (isActive ? " Questo è l'elemento indicato come attivo nella configurazione." : ""),
                consequence: isActive
                    ? "È lo sfondo attivo: macOS lo riscarica subito, quindi non recuperi spazio in modo stabile."
                    : "Nessuna, se né lo sfondo né il salvaschermo usano gli sfondi dinamici. Altrimenti viene riscaricato.",
                action: .removePaths([file]),
                risk: isActive ? .redownload : .safe,
                size: size, perPathSize: [file: size],
                lastUsed: ScanSupport.modificationDate(file),
                warning: isActive ? "Risulta selezionato nella configurazione attuale." : warning,
                preselect: false))
        }

        return items.sorted { $0.size > $1.size }
    }

    static func shuffleLabel(_ id: String) -> String {
        switch id {
        case "shuffle_continuously": return "continua"
        case "shuffle_every_12_hours": return "ogni 12 ore"
        case "shuffle_daily": return "ogni giorno"
        case "shuffle_never": return "nessuna rotazione"
        default: return id.replacingOccurrences(of: "shuffle_", with: "")
                          .replacingOccurrences(of: "_", with: " ")
        }
    }

    /// Riepilogo mostrato in testa alla categoria.
    static func statusSummary() -> String? {
        let config = readConfig()
        if config.desktopUsesAerials || config.screensaverUsesAerials {
            var who: [String] = []
            if config.desktopUsesAerials { who.append("sfondo del desktop") }
            if config.screensaverUsesAerials { who.append("salvaschermo") }
            return "In uso da: \(who.joined(separator: " e ")). Cancellare i video adesso è inefficace: vanno prima cambiate le impostazioni."
        }
        return "Né lo sfondo né il salvaschermo usano più gli sfondi dinamici: i video scaricati sono eliminabili in sicurezza e non torneranno."
    }
}

/// Docker. Le immagini e la cache di build sono recuperabili; i volumi
/// contengono database e stato delle applicazioni e questo software non li
/// elimina mai.
enum DockerScanner {

    struct Usage {
        var images: Int64 = 0
        var reclaimableImages: Int64 = 0
        var containers: Int64 = 0
        var buildCache: Int64 = 0
        var volumes: Int64 = 0
        var volumeNames: [String] = []
        var daemonRunning = false
        var installed = false
    }

    static func usage() -> Usage {
        var u = Usage()
        guard let docker = Shell.which("docker") else { return u }
        u.installed = true

        let info = Shell.run(docker, ["info", "--format", "{{.ServerVersion}}"], timeout: 30)
        guard info.ok, !info.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return u
        }
        u.daemonRunning = true

        // `docker system df -v` in JSON per riga.
        let df = Shell.run(docker, ["system", "df", "--format", "{{json .}}"], timeout: 60)
        for line in df.stdout.split(separator: "\n") {
            guard let obj = ScanSupport.jsonObject(fromString: String(line)) as? [String: Any],
                  let type = obj["Type"] as? String else { continue }
            let size = parseDockerSize(obj["Size"] as? String ?? "0B")
            let reclaimable = parseDockerSize(obj["Reclaimable"] as? String ?? "0B")
            switch type {
            case "Images": u.images = size; u.reclaimableImages = reclaimable
            case "Containers": u.containers = size
            case "Build Cache": u.buildCache = size
            case "Local Volumes": u.volumes = size
            default: break
            }
        }

        let vols = Shell.run(docker, ["volume", "ls", "--format", "{{.Name}}"], timeout: 30)
        u.volumeNames = vols.stdout.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        return u
    }

    static func scan() -> [CleanupItem] {
        let u = usage()

        // Docker rimosso a metà: l'app non c'è più ma il disco virtuale sì.
        // Questi file vengono offerti SOLO in assenza di Docker: se fosse
        // installato, cancellare il disco virtuale distruggerebbe immagini e
        // volumi, cioè esattamente ciò che questo software si impegna a non
        // toccare.
        if case .residual = Relevance.docker() {
            return residualItems()
        }

        guard u.installed, u.daemonRunning else { return [] }
        var items: [CleanupItem] = []

        if u.containers > 1_000_000 {
            items.append(CleanupItem(
                title: "Container fermi",
                detail: "Livelli di scrittura dei container non più in esecuzione. Non include i volumi.",
                consequence: "I container fermi vengono rimossi. Se li riavviavi con `docker start`, va rifatto `docker compose up`. I dati nei volumi restano.",
                action: .dockerPrune(kind: .stoppedContainers),
                risk: .redownload, size: u.containers, preselect: false))
        }

        if u.images > 1_000_000 {
            items.append(CleanupItem(
                title: "Immagini non utilizzate",
                detail: "Immagini Docker a cui nessun container in esecuzione fa riferimento.\n\nEsegue `docker image prune -a -f`.",
                consequence: "Le immagini vanno riscaricate al prossimo `docker compose up` (dipende dalla dimensione: spesso centinaia di MB). I volumi con i dati NON vengono toccati.",
                action: .dockerPrune(kind: .unusedImages),
                risk: .redownload, size: u.images,
                warning: u.containers > 0
                    ? "Include le immagini usate da container fermi: se elimini le immagini, quei container non riparteranno finché non le riscarichi."
                    : nil,
                preselect: false))
        }

        if u.buildCache > 1_000_000 {
            items.append(CleanupItem(
                title: "Cache di build Docker",
                detail: "Livelli intermedi prodotti dalle build delle immagini.",
                consequence: "La prossima `docker build` non riusa i livelli in cache: più lenta una volta sola.",
                action: .dockerPrune(kind: .buildCache),
                risk: .safe, size: u.buildCache))
        }

        return items
    }

    /// Residui di un Docker disinstallato: il disco virtuale contiene ancora
    /// le vecchie immagini e gli eventuali volumi, quindi l'operazione è
    /// classificata come dato dell'utente nonostante il programma sia assente.
    static func residualItems() -> [CleanupItem] {
        let paths = Relevance.dockerLeftoverPaths()
        guard !paths.isEmpty else { return [] }
        let sizes = Shell.diskSizes(paths)
        let total = sizes.values.reduce(0, +)
        guard total >= 1_000_000 else { return [] }

        return [CleanupItem(
            title: "Residui di Docker Desktop",
            detail: "Docker non è più installato, ma sono rimasti il disco virtuale della macchina Linux e i dati di supporto. Il disco virtuale contiene le immagini scaricate e **tutti i volumi** creati quando Docker era in uso.",
            consequence: "IRREVERSIBILE: se in quei volumi c'erano database o dati di applicazioni (per esempio uno stack avviato con docker compose), spariscono. Non sono recuperabili reinstallando Docker.",
            action: .removePaths(paths),
            risk: .userData, size: total, perPathSize: sizes,
            lastUsed: paths.compactMap(ScanSupport.modificationDate).max(),
            warning: "Prima di procedere, assicurati che nei volumi Docker non ci fosse niente che ti serve: una volta eliminato il disco virtuale non c'è modo di rileggerlo.",
            preselect: false)]
    }

    /// Nota sempre visibile: cosa Docker occupa e cosa non verrà toccato.
    static func summary() -> String {
        let u = usage()
        if case .residual(let detail) = Relevance.docker() { return detail }
        guard u.installed else { return "Docker non è installato." }
        guard u.daemonRunning else {
            return "Docker è installato ma il demone non è in esecuzione. Avvia Docker Desktop per analizzare immagini e cache. "
                 + "Se non lo usi, il disco virtuale resta comunque su disco in ~/Library/Containers/com.docker.docker."
        }
        var s = "Immagini \(ByteFormat.string(u.images)) · container fermi \(ByteFormat.string(u.containers)) · "
              + "cache di build \(ByteFormat.string(u.buildCache)) · volumi \(ByteFormat.string(u.volumes))."
        if !u.volumeNames.isEmpty {
            s += "\n\nI \(u.volumeNames.count) volumi (\(u.volumeNames.prefix(4).joined(separator: ", "))"
               + "\(u.volumeNames.count > 4 ? "…" : "")) contengono database e stato delle applicazioni e "
               + "NON vengono mai eliminati da questo software: `docker volume prune` e l'opzione "
               + "`--volumes` non sono implementati di proposito. Per rimuoverne uno, usa il comando "
               + "Docker a mano dopo aver fatto un backup."
        }
        return s
    }

    static func parseDockerSize(_ s: String) -> Int64 {
        // Formati tipo "2.479GB", "57.94MB", "0B", "1.2GB (100%)".
        let cleaned = s.split(separator: " ").first.map(String.init) ?? s
        let pattern = #"^([0-9.]+)\s*([KMGT]?i?B)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned)),
              m.numberOfRanges == 3,
              let numRange = Range(m.range(at: 1), in: cleaned),
              let unitRange = Range(m.range(at: 2), in: cleaned),
              let value = Double(cleaned[numRange]) else { return 0 }
        let unit = String(cleaned[unitRange])
        let multiplier: Double
        switch unit {
        case "B": multiplier = 1
        case "kB", "KB": multiplier = 1_000
        case "KiB": multiplier = 1_024
        case "MB": multiplier = 1_000_000
        case "MiB": multiplier = 1_048_576
        case "GB": multiplier = 1_000_000_000
        case "GiB": multiplier = 1_073_741_824
        case "TB": multiplier = 1_000_000_000_000
        default: multiplier = 1
        }
        return Int64(value * multiplier)
    }
}
