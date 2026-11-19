import Foundation

/// Residui a livello di sistema lasciati da programmi rimossi: servizi
/// launchd il cui programma non esiste più, driver audio e kext di un
/// produttore sparito, ricevute d'installazione senza file. Si appoggia alle
/// stesse prove di `OrphanScanner`. Nessuna voce è preselezionata.
///
/// Le cartelle `/Library/Application Support/<produttore>` non si propongono:
/// non c'è modo di dimostrare che nessun altro programma le usi.
enum SystemLeftoverScanner {

    private static let helperToolsDirectory = "/Library/PrivilegedHelperTools"

    /// Prefissi segnaposto: non dimostrano nessun produttore.
    private static let placeholderPrefixes: Set<String> = ["com.local", "com.example", "org.example"]

    /// Prefissi condivisi da molti autori diversi (piattaforme di hosting,
    /// framework, grandi aziende con prodotti indipendenti): per questi il
    /// produttore si riconosce solo con tre componenti.
    private static let sharedPrefixes: Set<String> = [
        "io.github", "com.github", "org.gnu", "net.sf", "com.electron", "com.todesktop",
        "org.mozilla", "com.google", "com.microsoft", "org.apache", "org.eclipse",
    ]

    private static let memo = ScanMemo<[CleanupItem]>()

    static func scan() -> [CleanupItem] { memo.value(compute) }

    static func invalidate() { memo.invalidate() }

    private static func compute() -> [CleanupItem] {
        let services = orphanServices()
        var items = services.compactMap(serviceItem)
        items += driverItems(services: services)
        if let receipts = receiptsItem() { items.append(receipts) }
        return items
    }

    // MARK: - Servizi launchd

    struct OrphanService {
        let label: String
        let plistPath: String
        let domain: StartupItem.Domain
        let program: String?
    }

    /// Servizi non Apple il cui programma è dimostrabilmente sparito. Legge
    /// solo i plist: niente `launchctl` né firme, perché serve anche come prova
    /// per i driver e va ripetuto al momento dell'eliminazione.
    static func orphanServices(roots: StartupScanner.Roots = .standard) -> [OrphanService] {
        var services: [OrphanService] = []
        for domain in [StartupItem.Domain.userAgent, .globalAgent, .daemon] {
            for path in ScanSupport.children(of: roots.directory(for: domain)) where path.hasSuffix(".plist") {
                guard let plist = ScanSupport.plistAsJSON(path) as? [String: Any],
                      let label = plist["Label"] as? String,
                      StartupGuard.isValidLabel(label), !label.lowercased().hasPrefix("com.apple.") else { continue }
                let program = StartupScanner.program(in: plist)
                guard StartupScanner.isOrphanProgram(program) else { continue }
                services.append(OrphanService(label: label, plistPath: path, domain: domain, program: program))
            }
        }
        return services
    }

    private static func serviceItem(_ service: OrphanService) -> CleanupItem? {
        var paths = [service.plistPath]
        let helper = helperToolsDirectory + "/" + service.label
        let hasHelper = service.domain != .userAgent && ScanSupport.exists(helper)
        if hasHelper { paths.append(helper) }
        let sizes = Shell.diskSizes(paths)
        let total = sizes.values.reduce(0, +)
        let program = service.program ?? "?"

        let action: CleanupAction = service.domain == .userAgent
            ? .removePaths(paths)
            : .removeSystemComponents([.launchService(label: service.label, plistPath: service.plistPath,
                                                      helperPath: hasHelper ? helper : nil)])
        return CleanupItem(
            title: String(localized: "Servizio d'avvio orfano «\(service.label)»"),
            detail: String(localized: "\(service.domain.label): il file di configurazione chiede a launchd di avviare un programma che non esiste più (\(program)). È il resto di un'app rimossa.")
                + (paths.count > 1 ? String(localized: " Si include anche il programma di supporto in \(helperToolsDirectory).") : ""),
            consequence: service.domain == .userAgent
                ? String(localized: "Launchd smette di cercare di avviare un programma assente. Va nel Cestino: lo recuperi da lì.")
                : String(localized: "Il servizio viene fermato e i file vanno nel Cestino (serve la password di amministratore). Se reinstalli l'app lo ricrea da sola."),
            action: action, risk: .redownload, size: total, perPathSize: sizes, preselect: false)
    }

    // MARK: - Driver audio e kext

    /// I produttori che risultano rimossi, e quelli che hanno ancora un'app.
    private struct VendorEvidence {
        let orphaned: Set<String>
        let installed: Set<String>

        init(services: [OrphanService]) {
            var orphaned = Set(services.compactMap { vendorPrefix(of: $0.label) })
            orphaned.formUnion(OrphanScanner.orphanBundleIDs().compactMap(vendorPrefix))
            self.orphaned = orphaned
            installed = Set(OrphanScanner.installedBundleIDs().compactMap(vendorPrefix))
        }

        /// Il bundle ha un identificatore il cui produttore risulta rimosso e
        /// non ha più nessuna app installata.
        func proves(bundleAt path: String) -> Bool {
            guard let id = ScanSupport.plistValue(path + "/Contents/Info.plist", key: "CFBundleIdentifier"),
                  let prefix = vendorPrefix(of: id) else { return false }
            return orphaned.contains(prefix) && !installed.contains(prefix)
        }
    }

    private static func driverItems(services: [OrphanService]) -> [CleanupItem] {
        let evidence = VendorEvidence(services: services)
        guard !evidence.orphaned.isEmpty else { return [] }

        var items: [CleanupItem] = []
        for (directory, ext) in PathGuard.systemBundleDirectories {
            let isKext = ext == "kext"
            for path in ScanSupport.children(of: directory) where isRealBundle(path) && evidence.proves(bundleAt: path) {
                let id = ScanSupport.plistValue(path + "/Contents/Info.plist", key: "CFBundleIdentifier") ?? "?"
                let sizes = Shell.diskSizes([path])
                let name = (path as NSString).lastPathComponent
                items.append(CleanupItem(
                    title: isKext ? String(localized: "Estensione del kernel orfana «\(name)»")
                                  : String(localized: "Driver audio orfano «\(name)»"),
                    detail: String(localized: "Il produttore «\(vendorPrefix(of: id) ?? id)» risulta rimosso: ha lasciato un servizio d'avvio o i dati di un'app che non esiste più, e nessuna app installata ha quel prefisso. Identificatore del componente: \(id).")
                        + String(localized: "\n\nLa prova è indiretta: controlla che non ti serva prima di procedere."),
                    consequence: isKext
                        ? String(localized: "L'estensione va nel Cestino (serve la password di amministratore). Perché smetta di essere caricata occorre riavviare il Mac.")
                        : String(localized: "Il driver va nel Cestino (serve la password di amministratore) e il dispositivo audio sparisce dopo il riavvio dell'audio o del Mac."),
                    action: .removeSystemComponents([.bundle(path: path)]),
                    risk: .userData, size: sizes[path] ?? 0, perPathSize: sizes,
                    warning: isKext ? String(localized: "Serve riavviare il Mac.") : nil,
                    preselect: false))
            }
        }
        return items
    }

    /// Un bundle vero (cartella, non un collegamento) con il nome giusto.
    private static func isRealBundle(_ path: String) -> Bool {
        var info = stat()
        return PathGuard.isSystemBundle(path) && lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }

    /// Il produttore di un identificatore: le prime due componenti in
    /// minuscolo (`com.vendor`), tre per i prefissi condivisi da molti autori
    /// (`io.github.autore`). Mai per Apple né per i prefissi segnaposto.
    static func vendorPrefix(of id: String) -> String? {
        let parts = id.lowercased().split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        let two = parts[0] + "." + parts[1]
        if two == "com.apple" || placeholderPrefixes.contains(two) { return nil }
        guard sharedPrefixes.contains(two) else { return two }
        guard parts.count >= 3, !parts[2].isEmpty else { return nil }
        return two + "." + parts[2]
    }

    // MARK: - Verifica all'esecuzione

    /// La cartella di launchd che dà il dominio del servizio.
    static func serviceTarget(forPlist plist: String) -> String? {
        switch (plist as NSString).deletingLastPathComponent {
        case "/Library/LaunchDaemons": return "system"
        case "/Library/LaunchAgents": return "gui/\(getuid())"
        default: return nil
        }
    }

    /// Ricontrolla adesso che il componente sia ancora un orfano: stesse prove
    /// della ricerca, rilette dal disco.
    static func validate(_ component: SystemComponent) throws {
        func refuse(_ path: String, _ why: String) -> PathGuard.Violation {
            .notASystemLeftover(path, why)
        }
        switch component {
        case .launchService(let label, let plistPath, let helperPath):
            guard StartupGuard.isValidLabel(label), !label.lowercased().hasPrefix("com.apple.") else {
                throw refuse(plistPath, String(localized: "etichetta non valida o di Apple"))
            }
            guard serviceTarget(forPlist: plistPath) != nil else {
                throw refuse(plistPath, String(localized: "fuori dalle cartelle dei servizi di sistema"))
            }
            guard helperPath == nil || helperPath == helperToolsDirectory + "/" + label else {
                throw refuse(helperPath ?? plistPath, String(localized: "il programma di supporto non corrisponde all'etichetta"))
            }
            var info = stat()
            guard lstat(plistPath, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  let plist = ScanSupport.plistAsJSON(plistPath) as? [String: Any],
                  plist["Label"] as? String == label else {
                throw refuse(plistPath, String(localized: "il file non dichiara più questo servizio"))
            }
            guard StartupScanner.isOrphanProgram(StartupScanner.program(in: plist)) else {
                throw refuse(plistPath, String(localized: "il programma esiste ancora o non si può dimostrare che manchi"))
            }
        case .bundle(let path):
            guard isRealBundle(path) else {
                throw refuse(path, String(localized: "non è un bundle .driver o .kext direttamente nella sua cartella"))
            }
            guard VendorEvidence(services: orphanServices()).proves(bundleAt: path) else {
                throw refuse(path, String(localized: "il produttore non risulta più rimosso"))
            }
        }
    }

    // MARK: - Ricevute

    private static func receiptsItem() -> CleanupItem? {
        let ids = PackageReceipts.orphanIDs()
        guard !ids.isEmpty else { return nil }
        return CleanupItem(
            title: String(localized: "\(Plural.of(ids.count, "ricevuta d'installazione", "ricevute d'installazione")) senza più file"),
            detail: String(localized: "Il programma d'installazione di macOS ricorda questi pacchetti, ma nessuno dei loro file esiste più sul disco:\n\n") + ids.joined(separator: "\n"),
            consequence: String(localized: "Si elimina solo la ricevuta (`pkgutil --forget`, serve la password): nessun file viene toccato. Le ricevute di Apple non sono mai incluse."),
            action: .forgetReceipts(ids), risk: .safe, size: 0, preselect: false)
    }

    // MARK: - Comando con privilegi

    /// Il comando per un gruppo di componenti già validati.
    static func command(for components: [SystemComponent]) -> String {
        var bootouts: [String] = []
        for case .launchService(let label, let plist, _) in components {
            if let target = serviceTarget(forPlist: plist) { bootouts.append("\(target)/\(label)") }
        }
        return trashCommand(paths: components.flatMap(\.paths), bootouts: bootouts)
    }

    /// Ferma i servizi (se falliscono non importa: spesso non sono caricati),
    /// sposta i file in una cartella nuova nel Cestino dell'utente e ne
    /// restituisce la proprietà all'utente, così il Cestino si può svuotare.
    /// Percorso della home assoluto: lo script gira come root.
    static func trashCommand(paths: [String], bootouts: [String], now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let short = String(UUID().uuidString.prefix(6))
        let destination = Shell.shellQuote(ScanSupport.home + "/.Trash/Ammugghia \(formatter.string(from: now)) \(short)")
        let stops = bootouts.map { "/bin/launchctl bootout \(Shell.shellQuote($0)) 2>/dev/null; " }.joined()
        let move = paths.map(Shell.shellQuote).joined(separator: " ")
        return "\(stops)/bin/mkdir -p \(destination) && /bin/mv -n \(move) \(destination)/ && /usr/sbin/chown -R \(getuid()) \(destination)"
    }
}
