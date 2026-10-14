import Foundation
import SwiftUI
import AppKit

enum SidebarSection: Hashable {
    case overview
    case category(CategoryID)
    case versions
    case diskMap
    case uninstall
    case log
}

@MainActor
final class AppModel: ObservableObject {

    @Published var categories: [CleanupCategory] = AppModel.buildCategories()
    @Published var versionGroups: [VersionGroup] = []
    @Published var apps: [AppEntry] = []

    @Published var disk = DiskInfo.current()
    @Published var isScanning = false
    @Published var scanProgress: String = ""
    @Published var scanFraction: Double = 0
    @Published var didScan = false

    @Published var selection: SidebarSection? = .overview
    @Published var selectedApp: AppEntry?

    @Published var removalMode: RemovalMode = .trash
    @Published var outcomes: [DeletionOutcome] = []
    @Published var logLines: [String] = []
    @Published var isExecuting = false
    @Published var executionProgress: String = ""
    @Published var lastFreed: Int64 = 0

    @Published var confirmPlan: [CleanupItem]?
    @Published var confirmIsDryRun = false

    @Published var notes: [String] = []

    // MARK: Mappa del disco

    @Published var isIndexing = false
    @Published var indexProgress = ""
    /// Cambia a ogni aggiornamento dell'indice: la mappa ricarica il livello.
    @Published var indexGeneration = 0
    @Published var indexStatus: String?

    /// Aggiorna l'indice del disco in background.
    func refreshIndex(forceFull: Bool = false) {
        guard !isIndexing else { return }
        isIndexing = true
        indexProgress = "Preparazione…"
        Task.detached(priority: .userInitiated) {
            let report = DiskIndexStore.shared.refresh(forceFull: forceFull) { count in
                Task { @MainActor in
                    self.indexProgress = "\(count.formatted()) cartelle lette…"
                }
            }
            await MainActor.run {
                self.isIndexing = false
                self.indexProgress = ""
                self.indexStatus = report.map(AppModel.describe)
                self.indexGeneration += 1
            }
        }
    }

    nonisolated static func describe(_ report: DiskIndexStore.Report) -> String {
        let time = report.finishedAt.formatted(date: .omitted, time: .shortened)
        let seconds = String(format: "%.1f", report.duration)
        switch report.mode {
        case .full(let reason):
            return "Analisi completa alle \(time) in \(seconds) s (\(reason))."
        case .incremental(let changed):
            return "Aggiornata alle \(time) in \(seconds) s: \(Plural.of(changed, "cartella riletta", "cartelle rilette")) grazie alla storia delle modifiche di macOS."
        }
    }

    private let engine = DeletionEngine()
    var logFilePath: String? { engine.logFilePath }

    // MARK: - Categorie

    static func buildCategories() -> [CleanupCategory] {
        [
            CleanupCategory(id: .xcode, name: "Xcode", symbol: "hammer.fill",
                explanation: "Cache e sottoprodotti di Xcode. Per chi compila app mobile è quasi sempre la voce più pesante del disco, e quasi tutto qui si rigenera da solo alla prossima compilazione."),
            CleanupCategory(id: .simulators, name: "Simulatori iOS", symbol: "iphone",
                explanation: "Dispositivi simulati e loro contenuto. Xocde ne crea uno per ogni combinazione di modello e versione di iOS, e quelli avviati almeno una volta accumulano app di test e database.\n\nI runtime (il sistema operativo simulato, ~8 GB ciascuno) si trovano nella scheda «Versioni multiple»."),
            CleanupCategory(id: .android, name: "Android", symbol: "cpu",
                explanation: "SDK Android, emulatori e cache Gradle. Il NDK e le immagini di sistema sono i componenti più grossi e servono solo in casi specifici."),
            CleanupCategory(id: .packageManagers, name: "Gestori di pacchetti", symbol: "shippingbox.fill",
                explanation: "Cache di npm, pip, Homebrew, CocoaPods, pub, Maven e simili. Singolarmente piccole, insieme spesso diversi GB. Tutto qui si riscarica: costa banda e tempo, non dati."),
            CleanupCategory(id: .projectArtifacts, name: "Artefatti dei progetti", symbol: "folder.badge.gearshape",
                explanation: "Cartelle `node_modules`, `Pods`, `.dart_tool` e `build` nei tuoi progetti. Sono la ragione per cui le Impostazioni di macOS dichiarano decine di GB di «Documenti» che non riesci a trovare.\n\nIl codice sorgente non viene mai toccato: una cartella viene proposta solo se il suo nome è in un elenco chiuso E la cartella padre contiene un file di progetto riconoscibile (package.json, pubspec.yaml, Podfile…)."),
            CleanupCategory(id: .browsers, name: "Browser", symbol: "globe",
                explanation: "Solo le cartelle di cache dei browser. Cronologia, segnalibri, password, cookie di sessione ed estensioni non vengono mai toccati: restano fuori dall'elenco per costruzione."),
            CleanupCategory(id: .appCaches, name: "App", symbol: "app.badge",
                explanation: "Cache di Slack, Discord, Teams, VS Code, Notion, Figma, degli IDE JetBrains e di altre app comuni.\n\nLe app costruite su Electron tengono la cache dentro «Application Support», accanto ai dati veri, dove le pulizie generiche non guardano. Qui si elencano solo le cartelle che l'app ricostruisce da sola: messaggi, documenti, accessi e impostazioni non vengono toccati. Ogni voce richiede che l'app sia chiusa."),
            CleanupCategory(id: .aiModels, name: "Modelli AI", symbol: "brain",
                explanation: "Modelli scaricati da Ollama, Hugging Face, LM Studio, PyTorch, Whisper e Keras, uno per voce con la data dell'ultima attività. Spesso sono la voce più pesante di un Mac da sviluppo, in cartelle nascoste.\n\nPer Ollama si usa il comando ufficiale `ollama rm`. Un modello eliminato va riscaricato se ti serve di nuovo."),
            CleanupCategory(id: .orphans, name: "Residui di app", symbol: "app.dashed",
                explanation: "File lasciati da applicazioni che non risultano più installate: container sandbox, preferenze, cache, stato delle finestre.\n\nUn'app è considerata rimossa solo se nessuna app con quell'identificatore è presente, registrata nel sistema o in esecuzione, nemmeno come estensione di un'altra. Si raccolgono solo i file il cui nome è esattamente l'identificatore. Nessuna voce è preselezionata."),
            CleanupCategory(id: .system, name: "Sistema", symbol: "gearshape.fill",
                explanation: "Residui e cache che macOS contabilizza come «dati di sistema» senza mostrarli da nessuna parte: l'installer rimasto dopo un aggiornamento, i log, lo stato delle finestre, i backup dei dispositivi iOS."),
            CleanupCategory(id: .wallpapers, name: "Sfondi dinamici", symbol: "photo.fill",
                explanation: "Video 4K scaricati da Apple per gli sfondi animati e il salvaschermo, circa 500 MB l'uno.\n\nQuesta categoria legge la tua configurazione prima di proporre qualcosa: se lo sfondo o il salvaschermo usano ancora la rotazione automatica, eliminarli è inutile perché macOS li riscarica in pochi giorni."),
            CleanupCategory(id: .docker, name: "Docker", symbol: "cube.box.fill",
                explanation: "Immagini e cache di build di Docker.\n\nI volumi non vengono mai eliminati da questo software: contengono database e stato delle applicazioni, e `--volumes` non è implementato di proposito."),
            CleanupCategory(id: .largeFiles, name: "File grandi", symbol: "doc.text.magnifyingglass",
                explanation: "Elenco dei file più grossi nelle tue cartelle di documenti, con la data dell'ultimo utilizzo.\n\nSolo informativo: questo software non elimina nulla dalle cartelle Documenti, Scrivania, Download e Filmati. Usa «Mostra nel Finder» e decidi tu, file per file."),
        ]
    }

    func category(_ id: CategoryID) -> CleanupCategory {
        categories.first { $0.id == id } ?? categories[0]
    }

    /// Categorie mostrate nella barra laterale. Quelle il cui programma non è
    /// installato e non ha lasciato niente vengono nascoste, salvo che
    /// l'utente chieda di vederle tutte.
    var visibleCategories: [CleanupCategory] {
        showAllCategories ? categories : categories.filter { $0.presence.isRelevant }
    }

    var hiddenCategoryCount: Int {
        categories.filter { !$0.presence.isRelevant }.count
    }

    /// Mostra anche le categorie dei programmi non installati.
    @Published var showAllCategories = false

    /// Lo scanner associato a ciascuna categoria. Un unico registro, usato sia
    /// dall'analisi completa sia dalla rianalisi di una singola categoria.
    ///
    /// `nonisolated` perché va invocato dai task in background: l'analisi non
    /// deve girare sul thread principale o l'interfaccia si blocca.
    nonisolated static func scanner(for id: CategoryID) -> () -> [CleanupItem] {
        switch id {
        case .xcode:            return XcodeScanner.scan
        case .simulators:       return SimulatorScanner.scan
        case .android:          return AndroidScanner.scan
        case .packageManagers:  return PackageManagerScanner.scan
        case .browsers:         return BrowserScanner.scan
        case .appCaches:        return AppCacheScanner.scan
        case .aiModels:         return AIModelScanner.scan
        case .orphans:          return OrphanScanner.scan
        case .system:           return SystemScanner.scan
        case .wallpapers:       return WallpaperScanner.scan
        case .docker:           return DockerScanner.scan
        case .projectArtifacts: return { ProjectArtifactScanner.scan() }
        case .largeFiles:       return { LargeFileScanner.scan() }
        }
    }

    /// Nota informativa in testa alla categoria, ricalcolata a ogni analisi.
    nonisolated static func note(for id: CategoryID) -> String? {
        switch id {
        case .wallpapers: return WallpaperScanner.statusSummary()
        case .docker:     return DockerScanner.summary()
        case .system:     return SystemScanner.localSnapshotsNote()
        case .orphans:    return OrphanScanner.summary()
        default:          return nil
        }
    }

    /// Rianalizza una sola categoria, lasciando intatte le altre e le
    /// selezioni già fatte altrove.
    func rescan(_ id: CategoryID) {
        let category = self.category(id)
        guard !category.isScanning, !isScanning, !isExecuting else { return }
        category.isScanning = true

        Task.detached(priority: .userInitiated) {
            let items = AppModel.scanner(for: id)()
            let presence = Relevance.detect(id)
            let note = AppModel.note(for: id)
            await MainActor.run {
                for item in items { item.origin = category.name }
                category.items = items
                category.presence = presence
                category.scanNote = note
                category.didScan = true
                category.isScanning = false
                self.disk = DiskInfo.current()
                self.objectWillChange.send()
            }
        }
    }

    // MARK: - Analisi

    func scanAll() {
        guard !isScanning else { return }
        isScanning = true
        didScan = false
        scanFraction = 0
        notes = []
        outcomes = []

        let steps = categories.map { ($0.name, $0.id) }
        let totalSteps = Double(steps.count + 2)

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            for (offset, step) in steps.enumerated() {
                let (label, categoryID) = step
                let fraction = Double(offset) / totalSteps
                await MainActor.run {
                    self.scanProgress = "Analisi: \(label)…"
                    self.scanFraction = fraction
                }
                let items = AppModel.scanner(for: categoryID)()
                let presence = Relevance.detect(categoryID)
                let note = AppModel.note(for: categoryID)
                await MainActor.run {
                    let category = self.category(categoryID)
                    for item in items { item.origin = category.name }
                    category.items = items
                    category.presence = presence
                    category.scanNote = note
                    category.didScan = true
                }
            }

            let versionsFraction = Double(steps.count) / totalSteps
            await MainActor.run {
                self.scanProgress = "Analisi: versioni multiple…"
                self.scanFraction = versionsFraction
            }
            let groups = DuplicateScanner.scan()

            let appsFraction = Double(steps.count + 1) / totalSteps
            await MainActor.run {
                self.scanProgress = "Analisi: applicazioni installate…"
                self.scanFraction = appsFraction
            }
            let apps = AppInventory.applications()

            await MainActor.run {
                self.versionGroups = groups
                self.apps = apps
                self.disk = DiskInfo.current()
                self.isScanning = false
                self.didScan = true
                self.scanFraction = 1
                self.scanProgress = ""
                self.collectNotes()
            }
        }
    }

    /// Osservazioni generali mostrate nella panoramica: sono i suggerimenti
    /// che nel caso reale hanno fatto la differenza.
    private func collectNotes() {
        var out: [String] = []

        if let runtimes = versionGroups.first(where: { $0.title.contains("Runtime dei simulatori") }) {
            let unused = runtimes.entries.filter { entry in
                guard let last = entry.lastUsed else { return false }
                return Date().timeIntervalSince(last) > 60 * 86_400
            }
            if !unused.isEmpty {
                let size = unused.reduce(0) { $0 + $1.size }
                out.append("Hai \(unused.count) runtime di simulatore iOS non usat\(unused.count == 1 ? "o" : "i") da oltre due mesi (\(unused.map(\.label).joined(separator: ", "))), per \(ByteFormat.string(size)). Sono la voce più pesante e meno visibile del disco: le Impostazioni li contano fra i «dati di sistema».")
            }
        }

        let config = WallpaperScanner.readConfig()
        if config.screensaverUsesAerials {
            out.append("Il salvaschermo usa gli sfondi dinamici con rotazione automatica: la cartella dei video 4K continuerà a crescere di ~500 MB alla volta finché non cambi l'impostazione in Impostazioni di Sistema → Salvaschermo.")
        }

        let dockerUsage = DockerScanner.usage()
        if dockerUsage.installed && !dockerUsage.volumeNames.isEmpty {
            out.append("Docker ha \(dockerUsage.volumeNames.count) volumi con dati (\(dockerUsage.volumeNames.prefix(3).joined(separator: ", "))). Questo software non li elimina mai: se cerchi comandi online, evita `docker system prune --volumes`, che li distruggerebbe.")
        }

        let totalSafe = categories.flatMap(\.items).filter { $0.risk == .safe }.reduce(0) { $0 + $1.size }
        if totalSafe > 1_000_000_000 {
            out.append("\(ByteFormat.string(totalSafe)) sono cache che si rigenerano da sole: è la parte che puoi eliminare senza conseguenze oltre a una compilazione più lenta la prima volta.")
        }

        if let snapshot = SystemScanner.localSnapshotsNote() { out.append(snapshot) }
        notes = out
    }

    // MARK: - Selezione

    var selectedItems: [CleanupItem] {
        var items = categories.flatMap(\.selectedItems)
        for group in versionGroups {
            for entry in group.entries where group.markedForRemoval.contains(entry.id) {
                let item = CleanupItem(
                    title: "\(group.title): \(entry.label)",
                    detail: entry.note ?? "Versione selezionata per la rimozione.",
                    consequence: "Rimozione di una versione fra le \(group.entries.count) installate. Ne restano \(group.remainingCount).",
                    action: entry.action,
                    risk: entry.risk,
                    size: entry.size,
                    perPathSize: Dictionary(uniqueKeysWithValues: entry.paths.map { ($0, entry.size) }),
                    lastUsed: entry.lastUsed,
                    preselect: true)
                item.origin = "Versioni multiple · \(group.title)"
                items.append(item)
            }
        }
        // Tutte le applicazioni contrassegnate, non solo quella aperta: si
        // possono accodare più disinstallazioni nello stesso piano.
        for app in markedApps {
            items.append(contentsOf: AppInventory.removalItems(for: app))
        }
        return items
    }

    var markedApps: [AppEntry] {
        apps.filter { $0.isMarkedForRemoval && !$0.isProtected }
    }

    var selectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.size } }
    var selectedHasUserData: Bool { selectedItems.contains { $0.risk == .userData } }
    var selectedNeedsAdmin: Bool { selectedItems.contains { $0.action.needsAdmin } }

    func selectAllSafe() {
        for category in categories {
            for item in category.items where item.risk == .safe && item.warning == nil
                && !item.action.isInformationalOnly {
                item.isSelected = true
            }
            category.enforceExclusivity()
            category.objectWillChange.send()
        }
        objectWillChange.send()
    }

    func deselectAll() {
        for category in categories {
            for item in category.items { item.isSelected = false }
            category.objectWillChange.send()
        }
        for group in versionGroups {
            group.markedForRemoval = []
        }
        for app in apps { app.isMarkedForRemoval = false }
        objectWillChange.send()
    }

    // MARK: - Esecuzione

    func requestExecution(dryRun: Bool) {
        let plan = selectedItems
        guard !plan.isEmpty else { return }
        confirmIsDryRun = dryRun
        confirmPlan = plan
    }

    /// Esecuzione di un piano specifico, indipendente dalle selezioni globali.
    /// Serve al pulsante «Disinstalla ora» della scheda applicazioni.
    func requestExecution(items: [CleanupItem], dryRun: Bool) {
        guard !items.isEmpty else { return }
        confirmIsDryRun = dryRun
        confirmPlan = items
    }

    func execute(items: [CleanupItem], dryRun: Bool) {
        guard !isExecuting else { return }
        isExecuting = true
        confirmPlan = nil
        let mode = removalMode
        let involvedApps = involvedApplications(in: items)

        // Backup dei dati, se richiesto, prima di qualsiasi rimozione.
        var backupMessages: [String] = []
        for app in involvedApps where app.backupUserData && app.hasUserDataSelected {
            let paths = app.selectedRelated.filter(\.holdsUserData).map(\.path)
            guard !paths.isEmpty else { continue }
            if dryRun {
                backupMessages.append("\(app.name): in esecuzione reale verrebbe creato un archivio di "
                    + "\(Plural.of(paths.count, "cartella", "cartelle")) in ~/Documents/Ammugghia Backup.")
            } else {
                backupMessages.append("\(app.name): " + engine.backup(paths: paths, appName: app.name).message)
            }
        }
        let backupMessage = backupMessages.isEmpty ? nil : backupMessages.joined(separator: "\n")

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let engine = await self.engine
            let results = engine.execute(items: items, mode: mode, dryRun: dryRun) { done, total, title in
                Task { @MainActor in
                    self.executionProgress = "\(done)/\(total) — \(title)"
                }
            }
            await MainActor.run {
                self.outcomes = results
                self.logLines = engine.log
                self.lastFreed = results.filter(\.succeeded).reduce(0) { $0 + $1.freed }
                self.isExecuting = false
                self.executionProgress = ""
                if let backupMessage {
                    self.logLines.append("BACKUP: " + backupMessage)
                }
                self.disk = DiskInfo.current()
                self.selection = .log
                if !dryRun && !involvedApps.isEmpty {
                    // Le app rimosse devono sparire dall'elenco.
                    self.reloadApplications()
                }
                if !dryRun {
                    OrphanScanner.invalidate()
                    // Le dimensioni non sono più attendibili dopo
                    // l'eliminazione: meglio invitare a rianalizzare che
                    // mostrare numeri sbagliati.
                    self.didScan = false
                    for category in self.categories {
                        category.items = []
                        category.didScan = false
                    }
                    self.versionGroups = []
                    self.deselectAll()
                }
            }
        }
    }

    // MARK: - Utilità

    func reveal(_ path: String) {
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }

    func exportPlan(_ items: [CleanupItem]) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "piano-pulizia.txt"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var text = "Ammugghia — piano di pulizia\n"
        text += "Generato: \(DateFormatter.localizedString(from: Date(), dateStyle: .full, timeStyle: .medium))\n"
        text += "Modalità: \(removalMode.label)\n"
        text += "Totale: \(ByteFormat.string(items.reduce(0) { $0 + $1.size }))\n\n"
        for item in items {
            text += "─────────────────────────────────────────────\n"
            text += "\(item.title)  [\(item.risk.label)]  \(ByteFormat.string(item.size))\n"
            text += "Operazione: \(item.action.commandDescription)\n"
            text += "Cos'è: \(item.detail)\n"
            text += "Conseguenza: \(item.consequence)\n"
            if let w = item.warning { text += "Avvertimento: \(w)\n" }
            if !item.action.displayPaths.isEmpty {
                text += "Percorsi:\n"
                for p in item.action.displayPaths {
                    text += "  • \(p)  (\(ByteFormat.string(item.perPathSize[p] ?? 0)))\n"
                }
            }
        }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    func exportLog() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "registro-pulizia.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? logLines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// Le applicazioni toccate da un piano: individuate dal percorso del
    /// bundle, così funziona anche per un piano costruito dal pulsante
    /// «Disinstalla ora» che non passa dalle selezioni globali.
    private func involvedApplications(in items: [CleanupItem]) -> [AppEntry] {
        var paths = Set<String>()
        for item in items {
            if case .removeApp(let appPath, _) = item.action { paths.insert(appPath) }
        }
        return apps.filter { paths.contains($0.path) }
    }

    /// Rilegge l'elenco delle applicazioni installate.
    func reloadApplications() {
        Task.detached(priority: .userInitiated) {
            let fresh = AppInventory.applications()
            await MainActor.run {
                let previouslySelected = self.selectedApp?.path
                self.apps = fresh
                self.selectedApp = fresh.first { $0.path == previouslySelected }
                if let app = self.selectedApp { self.loadRelated(for: app) }
            }
        }
    }

    /// Carica i file collegati per l'app selezionata, se non è già stato fatto.
    func loadRelated(for app: AppEntry) {
        guard !app.didScanRelated else { return }
        Task.detached(priority: .userInitiated) {
            let related = AppInventory.relatedFiles(for: app)
            let running = AppRuntime.isRunning(bundlePath: app.path)
            let lastUsed = Shell.lastUsedDate(app.path)
            await MainActor.run {
                app.related = related
                app.didScanRelated = true
                app.isRunning = running
                app.lastUsed = lastUsed
            }
        }
    }
}
