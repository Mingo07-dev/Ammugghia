import Foundation

/// Cache e sottoprodotti di Xcode. Per chi compila app mobile è quasi sempre
/// la categoria più pesante del disco.
enum XcodeScanner {

    static let xcodeBundleID = "com.apple.dt.Xcode"

    static func scan() -> [CleanupItem] {
        let home = ScanSupport.home
        let dev = home + "/Library/Developer"
        var items: [CleanupItem] = []

        // DerivedData: un elemento per progetto, così si vede quale pesa.
        let derived = dev + "/Xcode/DerivedData"
        if ScanSupport.isDirectory(derived) {
            let kids = ScanSupport.children(of: derived, includeHidden: true)
            let sizes = Shell.diskSizes(kids)
            for kid in kids {
                let size = sizes[kid] ?? 0
                guard size >= 5_000_000 else { continue }
                let name = (kid as NSString).lastPathComponent
                let isShared = name.hasSuffix(".noindex")
                let project = isShared ? name : String(name.split(separator: "-").dropLast().joined(separator: "-"))
                items.append(CleanupItem(
                    title: isShared ? "DerivedData: \(name)" : "DerivedData: \(project.isEmpty ? name : project)",
                    detail: isShared
                        ? String(localized: "Cache condivisa tra progetti generata dal compilatore.")
                        : String(localized: "Prodotti di compilazione, indice e log del progetto «\(project.isEmpty ? name : project)»."),
                    consequence: String(localized: "La prossima compilazione del progetto sarà completa invece che incrementale: qualche minuto in più una volta sola."),
                    action: .removePaths([kid]), risk: .safe, size: size,
                    perPathSize: [kid: size],
                    lastUsed: ScanSupport.modificationDate(kid),
                    requiredStoppedApps: [xcodeBundleID]))
            }
        }

        // DeviceSupport: simboli di debug, uno per versione di OS vista.
        for (platform, label) in [("iOS", "iOS"), ("watchOS", "watchOS"), ("tvOS", "tvOS"), ("visionOS", "visionOS")] {
            let base = dev + "/Xcode/\(platform) DeviceSupport"
            guard ScanSupport.isDirectory(base) else { continue }
            let kids = ScanSupport.children(of: base)
            let sizes = Shell.diskSizes(kids)
            for kid in kids {
                let size = sizes[kid] ?? 0
                guard size >= 5_000_000 else { continue }
                let version = (kid as NSString).lastPathComponent
                items.append(CleanupItem(
                    title: String(localized: "Simboli \(label) \(version)"),
                    detail: String(localized: "Simboli di debug copiati da un dispositivo \(label) con questa versione di sistema. Xcode li ricrea al primo collegamento del device."),
                    consequence: String(localized: "Ricollegando un dispositivo con \(label) \(version), Xcode rifarà la copia dei simboli: qualche minuto di attesa."),
                    action: .removePaths([kid]), risk: .safe, size: size,
                    perPathSize: [kid: size],
                    lastUsed: ScanSupport.modificationDate(kid)))
            }
        }

        // Archivi: contengono i dSYM necessari a simbolizzare i crash delle
        // build già distribuite. Dato non riproducibile.
        if let archives = ScanSupport.item(
            title: String(localized: "Archivi Xcode"),
            detail: String(localized: "Archivi .xcarchive delle build distribuite, con i simboli dSYM necessari a leggere i report di crash già in produzione."),
            consequence: String(localized: "Perdi la possibilità di simbolizzare i crash delle versioni già pubblicate. Non è ricostruibile: la stessa build va ricompilata identica."),
            path: dev + "/Xcode/Archives", risk: .userData) {
            items.append(archives)
        }

        // Cache varie di Xcode.
        let caches: [(String, String, String, String, RiskLevel)] = [
            (String(localized: "Cache modulo e indice di Xcode"), home + "/Library/Caches/com.apple.dt.Xcode",
             String(localized: "Indice del codice, cache dei moduli precompilati e anteprime."),
             String(localized: "Xcode ricostruisce l'indice alla prossima apertura del progetto: l'autocompletamento è lento per qualche minuto."), .safe),
            (String(localized: "Anteprime SwiftUI"), dev + "/Xcode/UserData/Previews",
             String(localized: "Cache delle anteprime live di SwiftUI."),
             String(localized: "La prima anteprima dopo la pulizia richiede una ricompilazione."), .safe),
            (String(localized: "Cache Swift Package Manager"), home + "/Library/Caches/org.swift.swiftpm",
             String(localized: "Copie dei pacchetti Swift scaricati, condivise tra i progetti."),
             String(localized: "Al prossimo build i pacchetti vengono riscaricati dai repository: serve la rete."), .redownload),
            (String(localized: "Cache CocoaPods"), home + "/Library/Caches/CocoaPods",
             String(localized: "Archivi delle pod scaricate."),
             String(localized: "Il prossimo `pod install` riscarica le dipendenze."), .redownload),
            (String(localized: "Specifiche CocoaPods"), home + "/.cocoapods/repos",
             String(localized: "Copia locale dell'intero indice delle pod pubbliche."),
             String(localized: "Il prossimo `pod install` riscarica l'indice: parecchi minuti la prima volta."), .redownload),
            (String(localized: "Log dei dispositivi"), dev + "/Xcode/DeviceLogs",
             String(localized: "Log e report di crash raccolti dai dispositivi collegati."),
             String(localized: "Perdi i report di crash non ancora esaminati."), .redownload),
            (String(localized: "Prodotti di build esportati"), dev + "/Xcode/Products",
             String(localized: "Binari esportati dalle compilazioni."),
             String(localized: "Vanno ricompilati se ti servono."), .redownload),
            (String(localized: "Documentazione scaricata"), dev + "/Xcode/DocumentationCache",
             String(localized: "Copia locale della documentazione Apple consultata da Xcode."),
             String(localized: "Xcode la riscarica quando apri la documentazione."), .redownload),
            (String(localized: "Indice della documentazione"), dev + "/Xcode/DocumentationIndex",
             String(localized: "Indice di ricerca della documentazione di Xcode."),
             String(localized: "Xcode lo ricostruisce alla prima ricerca nella documentazione."), .safe),
            (String(localized: "Log dei dispositivi iOS"), dev + "/Xcode/iOS Device Logs",
             String(localized: "Log e report di crash copiati da iPhone e iPad collegati."),
             String(localized: "Perdi i report di crash non ancora esaminati."), .redownload),
            (String(localized: "Log dei dispositivi watchOS"), dev + "/Xcode/watchOS Device Logs",
             String(localized: "Log e report di crash copiati da Apple Watch abbinati."),
             String(localized: "Perdi i report di crash non ancora esaminati."), .redownload),
            (String(localized: "File temporanei dei simulatori"), dev + "/CoreSimulator/Temp",
             String(localized: "File temporanei di CoreSimulator rimasti da avvii precedenti."),
             String(localized: "Nessuna: vengono ricreati quando servono."), .safe),
            (String(localized: "Assistente al codice"), dev + "/Xcode/CodingAssistant",
             String(localized: "Cache e modelli locali dell'assistente al codice di Xcode."),
             String(localized: "Xcode li riscarica quando serve."), .redownload),
        ]
        // Indice e anteprime vengono riscritti continuamente mentre Xcode è
        // aperto: eliminarli sotto i suoi piedi lo lascia in uno stato confuso.
        let needsXcodeClosed: Set<String> = [
            home + "/Library/Caches/com.apple.dt.Xcode",
            dev + "/Xcode/UserData/Previews",
        ]
        for (title, path, detail, consequence, risk) in caches {
            if let item = ScanSupport.item(title: title, detail: detail,
                                           consequence: consequence, path: path, risk: risk,
                                           requiredStoppedApps: needsXcodeClosed.contains(path) ? [xcodeBundleID] : []) {
                items.append(item)
            }
        }

        // Cache dyld dei simulatori: richiede privilegi. È la voce che nel
        // caso reale valeva 10 GB.
        let dyld = "/Library/Developer/CoreSimulator/Caches/dyld"
        if ScanSupport.isDirectory(dyld) {
            let size = Shell.diskSize(dyld)
            if size >= 100_000_000 {
                let cmd = "rm -rf " + Shell.shellQuote(dyld) + "/*"
                items.append(CleanupItem(
                    title: String(localized: "Cache dyld dei simulatori"),
                    detail: String(localized: "Cache delle librerie condivise generata per ogni runtime di simulatore installato. Vive fuori dalla cartella utente, quindi Finder e Impostazioni non la mostrano."),
                    consequence: String(localized: "Si rigenera da sola: il primo avvio di ogni simulatore dopo la pulizia richiede uno o due minuti in più."),
                    action: .privileged(shellCommand: cmd, displayPaths: [dyld]),
                    risk: .safe, size: size, perPathSize: [dyld: size],
                    lastUsed: ScanSupport.modificationDate(dyld),
                    warning: String(localized: "Richiede la password di amministratore: la cartella è di proprietà del sistema.")))
            }
        }

        // Strumenti a riga di comando duplicati rispetto a Xcode.
        let clt = "/Library/Developer/CommandLineTools"
        if ScanSupport.isDirectory(clt), ScanSupport.exists("/Applications/Xcode.app") {
            let size = Shell.diskSize(clt)
            if size >= 100_000_000 {
                let cmd = "rm -rf " + Shell.shellQuote(clt)
                items.append(CleanupItem(
                    title: String(localized: "Command Line Tools separati"),
                    detail: String(localized: "Copia autonoma dei compilatori a riga di comando. Hai anche Xcode installato, che li contiene già: sono due copie della stessa toolchain."),
                    consequence: String(localized: "Va eseguito `sudo xcode-select -s /Applications/Xcode.app` per puntare gli strumenti a Xcode. Alcuni installer (Homebrew su sistemi nuovi) si aspettano questa cartella e chiederebbero di reinstallarla."),
                    action: .privileged(shellCommand: cmd, displayPaths: [clt]),
                    risk: .redownload, size: size, perPathSize: [clt: size],
                    warning: String(localized: "Elimina solo se compili con Xcode. Dopo, esegui: sudo xcode-select -s /Applications/Xcode.app")))
            }
        }

        return items.sorted { $0.size > $1.size }
    }
}

/// Simulatori iOS: dispositivi e runtime. Il caso in cui le Impostazioni di
/// macOS sono più fuorvianti, perché i runtime stanno in
/// /System/Library/AssetsV2 e vengono contati come «dati di sistema».
enum SimulatorScanner {

    struct RuntimeInfo {
        let identifier: String      // UUID immagine, per simctl runtime delete
        let build: String
        let version: String
        let name: String
        let lastUsed: Date?
        let assetPath: String?
        var size: Int64 = 0
        let isCurrent: Bool
    }

    struct DeviceInfo {
        let udid: String
        let name: String
        let runtime: String
        let path: String
        var size: Int64 = 0
        let lastBooted: Date?
        let isAvailable: Bool
    }

    // MARK: Dispositivi

    static func devices() -> [DeviceInfo] {
        let base = ScanSupport.home + "/Library/Developer/CoreSimulator/Devices"
        guard ScanSupport.isDirectory(base) else { return [] }

        let dirs = ScanSupport.children(of: base).filter(ScanSupport.isDirectory)
        let sizes = Shell.diskSizes(dirs)

        // `simctl list -j` dice quali runtime sono ancora disponibili.
        var availableRuntimes = Set<String>()
        if let xcrun = Shell.which("xcrun") {
            let r = Shell.run(xcrun, ["simctl", "list", "runtimes", "-j"], timeout: 60)
            if let root = ScanSupport.jsonObject(fromString: r.stdout) as? [String: Any],
               let list = root["runtimes"] as? [[String: Any]] {
                for rt in list {
                    if let id = rt["identifier"] as? String,
                       (rt["isAvailable"] as? Bool) ?? false {
                        availableRuntimes.insert(id)
                    }
                }
            }
        }

        var result: [DeviceInfo] = []
        for dir in dirs {
            let plist = dir + "/device.plist"
            guard let name = ScanSupport.plistValue(plist, key: "name") else { continue }
            let runtimeRaw = ScanSupport.plistValue(plist, key: "runtime") ?? ""
            // "com.apple.CoreSimulator.SimRuntime.iOS-26-5" → "iOS 26.5":
            // la piattaforma resta separata, solo la versione usa i punti.
            let runtime: String = {
                let short = runtimeRaw
                    .replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.", with: "")
                let parts = short.split(separator: "-")
                guard let platform = parts.first else { return short }
                let version = parts.dropFirst().joined(separator: ".")
                return version.isEmpty ? String(platform) : "\(platform) \(version)"
            }()
            var lastBooted: Date?
            if let raw = ScanSupport.plistValue(plist, key: "lastBootedAt") {
                let f = DateFormatter()
                f.dateFormat = "EEE MMM d HH:mm:ss zzz yyyy"
                f.locale = Locale(identifier: "en_US_POSIX")
                lastBooted = f.date(from: raw)
            }
            if lastBooted == nil { lastBooted = ScanSupport.modificationDate(dir + "/data") }
            result.append(DeviceInfo(
                udid: (dir as NSString).lastPathComponent,
                name: name,
                runtime: runtime.isEmpty ? String(localized: "sconosciuto") : runtime,
                path: dir,
                size: sizes[dir] ?? 0,
                lastBooted: lastBooted,
                isAvailable: availableRuntimes.isEmpty ? true : availableRuntimes.contains(runtimeRaw)))
        }
        return result.sorted { $0.size > $1.size }
    }

    // MARK: Runtime

    static func runtimes() -> [RuntimeInfo] {
        guard let xcrun = Shell.which("xcrun") else { return [] }

        // Date d'ultimo uso e percorso dell'asset stanno in images.plist.
        var lastUsedByUUID: [String: Date] = [:]
        var assetByUUID: [String: String] = [:]
        let imagesPlist = "/Library/Developer/CoreSimulator/Images/images.plist"
        if let root = ScanSupport.plistAsJSON(imagesPlist) as? [String: Any],
           let images = root["images"] as? [[String: Any]] {
            for img in images {
                guard let uuid = img["uuid"] as? String else { continue }
                if let d = img["lastUsedAt"] as? Date { lastUsedByUUID[uuid] = d }
                if let pathDict = img["path"] as? [String: Any],
                   let rel = pathDict["relative"] as? String,
                   let url = URL(string: rel) {
                    // …/<hash>.asset/AssetData/Restore/xxx.dmg → risali a .asset
                    var dir = url.path
                    while !dir.hasSuffix(".asset") && dir.contains("/") && dir != "/" {
                        dir = (dir as NSString).deletingLastPathComponent
                    }
                    if dir.hasSuffix(".asset") { assetByUUID[uuid] = dir }
                }
            }
        }

        let r = Shell.run(xcrun, ["simctl", "runtime", "list", "-j"], timeout: 60)
        guard let root = ScanSupport.jsonObject(fromString: r.stdout) as? [String: Any] else { return [] }

        // La versione di Xcode attiva determina il runtime "corrente", che
        // conviene non toccare.
        let activeVersion = activeXcodeSDKVersion()

        var result: [RuntimeInfo] = []
        for (uuid, raw) in root {
            guard let dict = raw as? [String: Any] else { continue }
            let build = dict["build"] as? String ?? "?"
            let version = dict["version"] as? String ?? "?"
            let identifier = dict["runtimeIdentifier"] as? String ?? ""
            let platform = identifier
                .replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.", with: "")
                .split(separator: "-").first.map(String.init) ?? "iOS"
            let state = dict["state"] as? String ?? ""
            guard state.lowercased() != "deleting" else { continue }

            let assetPath = assetByUUID[uuid]
            var size: Int64 = 0
            if let assetPath { size = Shell.diskSize(assetPath) }
            if size == 0, let bytes = dict["sizeBytes"] as? Int64 { size = bytes }

            let isCurrent: Bool = {
                guard let activeVersion else { return false }
                return VersionGroup.compare(version, activeVersion) == 0
            }()

            result.append(RuntimeInfo(
                identifier: uuid,
                build: build,
                version: version,
                name: "\(platform) \(version)",
                lastUsed: lastUsedByUUID[uuid],
                assetPath: assetPath,
                size: size,
                isCurrent: isCurrent))
        }
        return result.sorted { VersionGroup.compare($0.version, $1.version) > 0 }
    }

    /// Versione dell'SDK iOS dell'Xcode selezionato: serve a capire quale
    /// runtime è quello "in uso".
    static func activeXcodeSDKVersion() -> String? {
        guard let xcrun = Shell.which("xcrun") else { return nil }
        let r = Shell.run(xcrun, ["--sdk", "iphonesimulator", "--show-sdk-version"], timeout: 30)
        let v = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    // MARK: Elementi di pulizia

    static func scan() -> [CleanupItem] {
        var items: [CleanupItem] = []
        let all = devices()

        // Simulatori rimasti senza Xcode: `simctl` non è disponibile, quindi
        // l'eliminazione avviene sui file, non tramite lo strumento ufficiale.
        if case .residual = Relevance.simulators() {
            let dirs = [
                ScanSupport.home + "/Library/Developer/CoreSimulator/Devices",
                ScanSupport.home + "/Library/Developer/CoreSimulator/Caches",
            ].filter(ScanSupport.exists)
            let sizes = Shell.diskSizes(dirs)
            let total = sizes.values.reduce(0, +)
            if total >= 1_000_000 {
                items.append(CleanupItem(
                    title: String(localized: "Residui dei simulatori iOS"),
                    detail: String(localized: "Xcode non è installato ma i dispositivi simulati e le loro cache sono rimasti sul disco. Senza Xcode non sono avviabili né gestibili."),
                    consequence: String(localized: "Nessuna: sono file inerti. Reinstallando Xcode i simulatori vengono ricreati da zero."),
                    action: .removePaths(dirs),
                    risk: .safe, size: total, perPathSize: sizes,
                    lastUsed: dirs.compactMap(ScanSupport.modificationDate).max()))
            }
            return items
        }

        // I dispositivi mai avviati occupano pochi MB a testa ma sono decine:
        // un unico elemento cumulativo evita di allungare l'elenco.
        let empty = all.filter { $0.size < 50_000_000 }
        if empty.count > 3 {
            let paths = empty.map(\.path)
            let total = empty.reduce(0) { $0 + $1.size }
            items.append(CleanupItem(
                title: String(localized: "\(empty.count) simulatori mai usati"),
                detail: String(localized: "Dispositivi creati automaticamente da Xcode e mai avviati: \(Set(empty.map(\.name)).sorted().prefix(6).joined(separator: ", "))\(Set(empty.map(\.name)).count > 6 ? "…" : ""). Occupano poco singolarmente ma sono \(empty.count)."),
                consequence: String(localized: "Xcode li ricrea automaticamente quando servono, oppure li ricrei da Window → Devices and Simulators."),
                action: .removePaths(paths), risk: .safe, size: total,
                perPathSize: Dictionary(uniqueKeysWithValues: empty.map { ($0.path, $0.size) })))
        }

        // Dispositivi con dati: due opzioni distinte, eliminare o azzerare.
        for device in all where device.size >= 50_000_000 {
            let unavailable = !device.isAvailable
            items.append(CleanupItem(
                title: unavailable
                    ? String(localized: "Simulatore \(device.name) (\(device.runtime)) — runtime non più installato")
                    : String(localized: "Simulatore \(device.name) (\(device.runtime))"),
                detail: String(localized: "Dispositivo con dati: app installate, database, foto e impostazioni accumulate durante i test.")
                    + (unavailable ? String(localized: " Il runtime di questo simulatore non è più installato, quindi il dispositivo non è avviabile.") : ""),
                consequence: String(localized: "Il dispositivo scompare da Xcode. Al prossimo avvio ne crei uno nuovo e le app di test vanno reinstallate."),
                action: .simctlDeleteDevice(udid: device.udid),
                risk: unavailable ? .safe : .redownload,
                size: device.size,
                perPathSize: [device.path: device.size],
                lastUsed: device.lastBooted,
                exclusiveGroup: "device-\(device.udid)",
                preselect: unavailable))

            if !unavailable {
                items.append(CleanupItem(
                    title: String(localized: "Azzera contenuto di \(device.name) (\(device.runtime))"),
                    detail: String(localized: "Riporta il simulatore allo stato di fabbrica mantenendolo nell'elenco di Xcode. Alternativa all'eliminazione: recupera lo stesso spazio ma conserva il dispositivo."),
                    consequence: String(localized: "Il dispositivo resta disponibile ma vuoto: le app di test vanno reinstallate al prossimo avvio."),
                    action: .simctlEraseDevice(udid: device.udid),
                    risk: .redownload, size: device.size,
                    perPathSize: [device.path: device.size],
                    lastUsed: device.lastBooted,
                    exclusiveGroup: "device-\(device.udid)",
                    preselect: false))
            }
        }

        return items
    }
}
