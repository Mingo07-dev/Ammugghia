import Foundation

/// Rileva più versioni installate della stessa cosa. È il caso dei runtime
/// iOS: tre versioni da 8 GB, di cui una non usata da mesi, invisibili nel
/// Finder e non segnalate da nessuna parte nel sistema.
enum DuplicateScanner {

    /// Usato anche per riconoscere il gruppo da `AppModel`: un confronto sul
    /// titolo scritto a mano si romperebbe cambiando lingua.
    static var simulatorRuntimesTitle: String { String(localized: "Runtime dei simulatori iOS") }

    static func scan() -> [VersionGroup] {
        var groups: [VersionGroup] = []
        if let g = simulatorRuntimes() { groups.append(g) }
        if let g = xcodeInstalls() { groups.append(g) }
        groups.append(contentsOf: androidSdkComponents())
        if let g = gradleDistributions() { groups.append(g) }
        if let g = javaRuntimes() { groups.append(g) }
        if let g = pythonFrameworks() { groups.append(g) }
        if let g = nodeVersions() { groups.append(g) }
        if let g = homebrewFormulas() { groups.append(g) }
        if let g = flutterSdks() { groups.append(g) }
        if let g = duplicateApps() { groups.append(g) }
        if let g = duplicateSimulatorDevices() { groups.append(g) }
        return groups.filter { $0.entries.count > 1 }
    }

    // MARK: Runtime dei simulatori

    static func simulatorRuntimes() -> VersionGroup? {
        let runtimes = SimulatorScanner.runtimes()
        guard runtimes.count > 1 else { return nil }
        let newest = runtimes.first?.version

        let entries = runtimes.map { rt -> VersionEntry in
            var notes: [String] = []
            if rt.isCurrent { notes.append(String(localized: "corrisponde all'SDK dell'Xcode attivo")) }
            if rt.version == newest { notes.append(String(localized: "versione più recente installata")) }
            if let used = rt.lastUsed { notes.append(DateFormat.relative(used)) }
            return VersionEntry(
                label: rt.name,
                version: rt.version,
                paths: rt.assetPath.map { [$0] } ?? [],
                size: rt.size,
                lastUsed: rt.lastUsed,
                action: .simctlDeleteRuntime(id: rt.identifier),
                risk: .redownload,
                note: notes.isEmpty ? nil : notes.joined(separator: " · "),
                recommendedToKeep: rt.isCurrent || rt.version == newest)
        }

        return VersionGroup(
            title: simulatorRuntimesTitle,
            symbol: "iphone",
            rationale: String(localized: "Ogni runtime pesa circa 8 GB e serve solo se vuoi testare su quella specifica versione di iOS. Vivono in /System/Library/AssetsV2, quindi non compaiono nel Finder e le Impostazioni li contano fra i «dati di sistema».\n\nSono la voce che più spesso spiega decine di GB inspiegabili su un Mac usato per sviluppo mobile. Tieni la versione dell'Xcode attivo, più eventuali versioni su cui devi davvero garantire compatibilità."),
            entries: entries)
    }

    // MARK: Xcode

    static func xcodeInstalls() -> VersionGroup? {
        var candidates: [String] = []
        for dir in ["/Applications", ScanSupport.home + "/Applications"] {
            candidates += ScanSupport.children(of: dir).filter {
                let n = (($0 as NSString).lastPathComponent)
                return n.hasPrefix("Xcode") && n.hasSuffix(".app")
            }
        }
        guard candidates.count > 1 else { return nil }
        let sizes = Shell.diskSizes(candidates)

        // Quale Xcode è quello selezionato da xcode-select.
        var activePath: String?
        if let xcodeSelect = Shell.which("xcode-select") {
            let r = Shell.run(xcodeSelect, ["-p"], timeout: 20)
            let devDir = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if devDir.hasSuffix("/Contents/Developer") {
                activePath = String(devDir.dropLast("/Contents/Developer".count))
            }
        }

        let entries = candidates.map { path -> VersionEntry in
            let version = ScanSupport.plistValue(path + "/Contents/Info.plist", key: "CFBundleShortVersionString") ?? "?"
            let isActive = activePath.map { PathGuard.normalize($0) == PathGuard.normalize(path) } ?? false
            return VersionEntry(
                label: (path as NSString).lastPathComponent + " (\(version))",
                version: version,
                paths: [path],
                size: sizes[path] ?? 0,
                lastUsed: Shell.lastUsedDate(path),
                action: .removeApp(appPath: path, related: []),
                risk: .redownload,
                note: isActive ? String(localized: "selezionato da xcode-select") : nil,
                recommendedToKeep: isActive)
        }

        return VersionGroup(
            title: String(localized: "Installazioni di Xcode"),
            symbol: "hammer",
            rationale: String(localized: "Ogni Xcode occupa diversi GB. Avere due versioni ha senso solo mentre migri un progetto o se devi mantenere una build con una toolchain vecchia. Ricorda che ogni Xcode porta con sé i propri runtime di simulatore."),
            entries: entries)
    }

    // MARK: Componenti del SDK Android

    static func androidSdkComponents() -> [VersionGroup] {
        let sdk = AndroidScanner.sdkPath
        var groups: [VersionGroup] = []

        let components: [(String, String, String, String)] = [
            ("ndk", String(localized: "NDK Android"), "cpu",
             String(localized: "Il NDK serve solo per compilare codice nativo C/C++. Un progetto usa una versione alla volta, indicata in build.gradle: le altre sono peso morto da qualche GB ciascuna.")),
            ("build-tools", String(localized: "Build Tools Android"), "wrench.and.screwdriver",
             String(localized: "Gradle usa la versione dichiarata nel progetto. Le versioni più vecchie restano installate dopo ogni aggiornamento dell'SDK.")),
            ("platforms", String(localized: "Piattaforme Android"), "square.stack.3d.up",
             String(localized: "Una piattaforma per livello di API. Servono quelle su cui compili (compileSdk) e quelle minime che supporti.")),
            ("cmake", "CMake", "gearshape.2",
             String(localized: "Usato solo con il NDK per i progetti nativi.")),
        ]

        for (dir, title, symbol, rationale) in components {
            let base = sdk + "/" + dir
            guard ScanSupport.isDirectory(base) else { continue }
            let versions = ScanSupport.children(of: base).filter(ScanSupport.isDirectory)
            guard versions.count > 1 else { continue }
            let sizes = Shell.diskSizes(versions)
            let names = versions.map { ($0 as NSString).lastPathComponent }
            let newest = names.max { VersionGroup.compare($0, $1) < 0 }

            let entries = versions.map { path -> VersionEntry in
                let name = (path as NSString).lastPathComponent
                return VersionEntry(
                    label: name,
                    version: name,
                    paths: [path],
                    size: sizes[path] ?? 0,
                    lastUsed: ScanSupport.modificationDate(path),
                    action: .removePaths([path]),
                    risk: .redownload,
                    note: name == newest ? String(localized: "versione più recente") : nil,
                    recommendedToKeep: name == newest)
            }
            groups.append(VersionGroup(title: title, symbol: symbol, rationale: rationale, entries: entries))
        }

        // Immagini di sistema: raggruppate per livello di API.
        let sysImages = sdk + "/system-images"
        if ScanSupport.isDirectory(sysImages) {
            var entries: [VersionEntry] = []
            var allPaths: [String] = []
            for api in ScanSupport.children(of: sysImages) {
                allPaths += ScanSupport.children(of: api)
            }
            let sizes = Shell.diskSizes(allPaths)
            for path in allPaths {
                let variant = (path as NSString).lastPathComponent
                let api = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
                let apiNumber = api.replacingOccurrences(of: "android-", with: "")
                entries.append(VersionEntry(
                    label: "\(api) / \(variant)",
                    version: apiNumber,
                    paths: [path],
                    size: sizes[path] ?? 0,
                    lastUsed: ScanSupport.modificationDate(path),
                    action: .removePaths([path]),
                    risk: .redownload,
                    note: nil,
                    recommendedToKeep: false))
            }
            if entries.count > 1 {
                groups.append(VersionGroup(
                    title: String(localized: "Immagini di sistema per gli emulatori"),
                    symbol: "square.on.square",
                    rationale: String(localized: "Ogni immagine pesa 1–4 GB. Servono solo quelle usate dagli emulatori che tieni davvero: se testi su dispositivi reali, nessuna serve."),
                    entries: entries))
            }
        }

        return groups
    }

    static func gradleDistributions() -> VersionGroup? {
        let base = ScanSupport.home + "/.gradle/wrapper/dists"
        guard ScanSupport.isDirectory(base) else { return nil }
        // Solo cartelle: la cartella contiene anche CACHEDIR.TAG, che non è
        // una versione di Gradle.
        let versions = ScanSupport.children(of: base)
            .filter { ScanSupport.isDirectory($0) && ($0 as NSString).lastPathComponent.hasPrefix("gradle-") }
        guard versions.count > 1 else { return nil }
        let sizes = Shell.diskSizes(versions)
        let names = versions.map { ($0 as NSString).lastPathComponent }
        let newest = names.max { VersionGroup.compare($0, $1) < 0 }

        let entries = versions.map { path -> VersionEntry in
            let name = (path as NSString).lastPathComponent
            return VersionEntry(
                label: name,
                version: name.replacingOccurrences(of: "gradle-", with: ""),
                paths: [path],
                size: sizes[path] ?? 0,
                lastUsed: ScanSupport.modificationDate(path),
                action: .removePaths([path]),
                risk: .redownload,
                note: name == newest ? String(localized: "versione più recente") : nil,
                recommendedToKeep: name == newest)
        }
        return VersionGroup(
            title: String(localized: "Distribuzioni Gradle"),
            symbol: "shippingbox",
            rationale: String(localized: "Ogni progetto Android scarica la versione di Gradle indicata nel proprio wrapper. Con più progetti si accumulano copie complete da ~150 MB. Il wrapper riscarica automaticamente quella che serve."),
            entries: entries)
    }

    // MARK: Runtime di linguaggi

    static func javaRuntimes() -> VersionGroup? {
        let base = "/Library/Java/JavaVirtualMachines"
        guard ScanSupport.isDirectory(base) else { return nil }
        let jdks = ScanSupport.children(of: base)
        guard jdks.count > 1 else { return nil }
        let sizes = Shell.diskSizes(jdks)
        let entries = jdks.map { path -> VersionEntry in
            let name = (path as NSString).lastPathComponent
            let version = ScanSupport.plistValue(path + "/Contents/Info.plist", key: "CFBundleShortVersionString") ?? name
            let cmd = "rm -rf " + Shell.shellQuote(path)
            return VersionEntry(
                label: name,
                version: version,
                paths: [path],
                size: sizes[path] ?? 0,
                lastUsed: ScanSupport.modificationDate(path),
                action: .privileged(shellCommand: cmd, displayPaths: [path]),
                risk: .redownload,
                note: String(localized: "richiede la password di amministratore"),
                recommendedToKeep: false)
        }
        return VersionGroup(
            title: String(localized: "Java Development Kit"),
            symbol: "cup.and.saucer",
            rationale: String(localized: "Android Studio porta con sé un JDK proprio, quindi i JDK installati a parte spesso non servono. Verifica cosa usa JAVA_HOME e cosa richiedono i tuoi progetti prima di rimuoverne uno."),
            entries: entries)
    }

    static func pythonFrameworks() -> VersionGroup? {
        let base = "/Library/Frameworks/Python.framework/Versions"
        guard ScanSupport.isDirectory(base) else { return nil }
        let versions = ScanSupport.children(of: base).filter {
            ($0 as NSString).lastPathComponent != "Current"
        }
        guard versions.count > 1 else { return nil }
        let sizes = Shell.diskSizes(versions)
        let names = versions.map { ($0 as NSString).lastPathComponent }
        let newest = names.max { VersionGroup.compare($0, $1) < 0 }
        let entries = versions.map { path -> VersionEntry in
            let name = (path as NSString).lastPathComponent
            let cmd = "rm -rf " + Shell.shellQuote(path)
            return VersionEntry(
                label: "Python \(name)",
                version: name,
                paths: [path],
                size: sizes[path] ?? 0,
                lastUsed: ScanSupport.modificationDate(path),
                action: .privileged(shellCommand: cmd, displayPaths: [path]),
                risk: .redownload,
                note: name == newest ? String(localized: "versione più recente") : String(localized: "richiede la password di amministratore"),
                recommendedToKeep: name == newest)
        }
        return VersionGroup(
            title: String(localized: "Versioni di Python (python.org)"),
            symbol: "chevron.left.forwardslash.chevron.right",
            rationale: String(localized: "Le installazioni da python.org non si sovrascrivono fra loro. Attenzione: gli ambienti virtuali creati con una versione smettono di funzionare se quella versione viene rimossa."),
            entries: entries)
    }

    static func nodeVersions() -> VersionGroup? {
        let base = ScanSupport.home + "/.nvm/versions/node"
        guard ScanSupport.isDirectory(base) else { return nil }
        let versions = ScanSupport.children(of: base)
        guard versions.count > 1 else { return nil }
        let sizes = Shell.diskSizes(versions)
        let names = versions.map { ($0 as NSString).lastPathComponent }
        let newest = names.max { VersionGroup.compare($0, $1) < 0 }
        let entries = versions.map { path -> VersionEntry in
            let name = (path as NSString).lastPathComponent
            return VersionEntry(
                label: "Node \(name)",
                version: name,
                paths: [path],
                size: sizes[path] ?? 0,
                lastUsed: ScanSupport.modificationDate(path),
                action: .removePaths([path]),
                risk: .redownload,
                note: name == newest ? String(localized: "versione più recente") : nil,
                recommendedToKeep: name == newest)
        }
        return VersionGroup(
            title: String(localized: "Versioni di Node (nvm)"),
            symbol: "hexagon",
            rationale: String(localized: "Ogni versione di Node installata con nvm porta i propri pacchetti globali. Controlla il file .nvmrc dei tuoi progetti prima di rimuoverne una."),
            entries: entries)
    }

    static func homebrewFormulas() -> VersionGroup? {
        let cellar = "/opt/homebrew/Cellar"
        guard ScanSupport.isDirectory(cellar) else { return nil }
        var multi: [(formula: String, path: String, version: String)] = []
        for formula in ScanSupport.children(of: cellar) {
            let versions = ScanSupport.children(of: formula)
            guard versions.count > 1 else { continue }
            let name = (formula as NSString).lastPathComponent
            // La più recente resta, le altre sono candidate.
            let sorted = versions.sorted {
                VersionGroup.compare(($0 as NSString).lastPathComponent,
                                     ($1 as NSString).lastPathComponent) > 0
            }
            for old in sorted.dropFirst() {
                multi.append((name, old, (old as NSString).lastPathComponent))
            }
        }
        guard multi.count > 1 else { return nil }
        let sizes = Shell.diskSizes(multi.map(\.path))
        let entries = multi.map { entry in
            VersionEntry(
                label: "\(entry.formula) \(entry.version)",
                version: entry.version,
                paths: [entry.path],
                size: sizes[entry.path] ?? 0,
                lastUsed: ScanSupport.modificationDate(entry.path),
                action: .removePaths([entry.path]),
                risk: .safe,
                note: String(localized: "versione superata"),
                recommendedToKeep: false)
        }
        return VersionGroup(
            title: String(localized: "Versioni superate di Homebrew"),
            symbol: "mug",
            rationale: String(localized: "Homebrew conserva la versione precedente di ogni formula dopo un aggiornamento. Qui sono elencate solo le versioni NON attive.\n\nIn alternativa, la categoria «Gestori di pacchetti» offre `brew cleanup --prune=all`, che fa la stessa cosa passando dal comando ufficiale: è la via preferibile."),
            entries: entries)
    }

    static func flutterSdks() -> VersionGroup? {
        let home = ScanSupport.home
        let candidates = [
            home + "/flutter", home + "/development/flutter", home + "/sdk/flutter",
            "/opt/flutter", "/usr/local/flutter", home + "/fvm/versions",
        ].filter { ScanSupport.isDirectory($0 + "/bin") || ScanSupport.isDirectory($0) }
        var paths = candidates.filter { ScanSupport.exists($0 + "/bin/flutter") }
        // fvm gestisce più versioni in sottocartelle.
        let fvm = home + "/fvm/versions"
        if ScanSupport.isDirectory(fvm) {
            paths += ScanSupport.children(of: fvm).filter { ScanSupport.exists($0 + "/bin/flutter") }
        }
        guard paths.count > 1 else { return nil }
        let sizes = Shell.diskSizes(paths)
        let entries = paths.map { path -> VersionEntry in
            var version = "?"
            if ScanSupport.exists(path + "/version"),
               let v = try? String(contentsOfFile: path + "/version", encoding: .utf8) {
                version = v.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return VersionEntry(
                label: "Flutter \(version) — \(path)",
                version: version,
                paths: [path],
                size: sizes[path] ?? 0,
                lastUsed: ScanSupport.modificationDate(path),
                action: .removePaths([path]),
                risk: .redownload,
                note: nil,
                recommendedToKeep: false)
        }
        return VersionGroup(
            title: String(localized: "SDK Flutter"),
            symbol: "bird",
            rationale: String(localized: "Più copie dell'SDK Flutter in cartelle diverse: capita installandolo a mano e poi di nuovo con un gestore. Verifica quale è nel PATH prima di rimuovere le altre."),
            entries: entries)
    }

    // MARK: Applicazioni duplicate

    static func duplicateApps() -> VersionGroup? {
        var byBundleID: [String: [String]] = [:]
        for dir in ["/Applications", "/Applications/Utilities", ScanSupport.home + "/Applications"] {
            // I collegamenti simbolici verso lo stesso bundle non sono una
            // doppia installazione: senza questo filtro un'app installata in
            // una sottocartella con un link in /Applications risulterebbe
            // duplicata a torto.
            let candidates = AppInventory.deduplicateResolvingLinks(
                ScanSupport.children(of: dir).filter { $0.hasSuffix(".app") })
            for app in candidates {
                guard let id = ScanSupport.plistValue(app + "/Contents/Info.plist", key: "CFBundleIdentifier") else { continue }
                byBundleID[id, default: []].append(app)
            }
        }
        let duplicates = byBundleID.filter { $0.value.count > 1 }
        guard !duplicates.isEmpty else { return nil }

        var entries: [VersionEntry] = []
        let allPaths = duplicates.values.flatMap { $0 }
        let sizes = Shell.diskSizes(allPaths)
        for (bundleID, paths) in duplicates {
            for path in paths {
                let version = ScanSupport.plistValue(path + "/Contents/Info.plist", key: "CFBundleShortVersionString") ?? "?"
                entries.append(VersionEntry(
                    label: String(localized: "\((path as NSString).lastPathComponent) \(version) — \((path as NSString).deletingLastPathComponent)"),
                    version: version,
                    paths: [path],
                    size: sizes[path] ?? 0,
                    lastUsed: Shell.lastUsedDate(path),
                    action: .removeApp(appPath: path, related: []),
                    risk: .redownload,
                    note: bundleID,
                    recommendedToKeep: false))
            }
        }
        return VersionGroup(
            title: String(localized: "Applicazioni installate due volte"),
            symbol: "square.on.square.dashed",
            rationale: String(localized: "Stesso identificatore di bundle in più posizioni: succede scaricando un'app che era già stata installata dall'App Store, o copiandola in una sottocartella. Le due copie condividono le stesse preferenze, quindi tenere una sola non fa perdere nulla.\n\nQui viene rimosso solo il bundle: per eliminare anche i dati usa la scheda «Disinstalla app»."),
            entries: entries)
    }

    static func duplicateSimulatorDevices() -> VersionGroup? {
        let devices = SimulatorScanner.devices()
        let byName = Dictionary(grouping: devices, by: \.name).filter { $0.value.count > 1 }
        guard !byName.isEmpty else { return nil }

        var entries: [VersionEntry] = []
        for (name, list) in byName {
            for device in list {
                entries.append(VersionEntry(
                    label: "\(name) — \(device.runtime)",
                    version: device.runtime,
                    paths: [device.path],
                    size: device.size,
                    lastUsed: device.lastBooted,
                    action: .simctlDeleteDevice(udid: device.udid),
                    risk: device.isAvailable ? .redownload : .safe,
                    note: device.isAvailable ? nil : String(localized: "runtime non più installato: dispositivo inutilizzabile"),
                    recommendedToKeep: device.isAvailable && device.size > 50_000_000))
            }
        }
        return VersionGroup(
            title: String(localized: "Simulatori dello stesso modello"),
            symbol: "iphone.gen3",
            rationale: String(localized: "Xcode crea un dispositivo per ogni combinazione modello + versione di iOS. Con tre runtime installati hai tre «iPhone 17» distinti. Quelli il cui runtime non è più installato non sono nemmeno avviabili."),
            entries: entries)
    }
}
