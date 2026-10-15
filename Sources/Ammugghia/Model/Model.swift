import Foundation

// MARK: - Livelli di rischio

/// Quanto costa sbagliare. Determina il colore, se un elemento è
/// preselezionabile e quante conferme servono prima di eseguire.
enum RiskLevel: Int, Comparable, CaseIterable, Identifiable {
    /// Cache rigenerata automaticamente dal sistema o dal tool che la possiede.
    case safe = 0
    /// Contenuto valido ma che va riscaricato o ricostruito (banda e tempo).
    case redownload = 1
    /// Dati creati dall'utente o non recuperabili. Mai preselezionato.
    case userData = 2

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .safe: return String(localized: "Sicuro")
        case .redownload: return String(localized: "Da riscaricare")
        case .userData: return String(localized: "Dati utente")
        }
    }

    var explanation: String {
        switch self {
        case .safe:
            return String(localized: "Cache rigenerata automaticamente. L'unica conseguenza è che la prossima operazione sarà più lenta.")
        case .redownload:
            return String(localized: "Contenuto valido ma ricostruibile: dopo l'eliminazione va riscaricato o ricompilato. Consumo di banda e tempo.")
        case .userData:
            return String(localized: "Contiene dati tuoi o non recuperabili automaticamente. Non viene mai selezionato da solo e richiede una conferma scritta.")
        }
    }

    /// Solo gli elementi sicuri possono essere preselezionati all'avvio.
    var autoSelectable: Bool { self == .safe }

    static func < (a: RiskLevel, b: RiskLevel) -> Bool { a.rawValue < b.rawValue }
}

// MARK: - Azioni

/// Ogni elemento eliminabile dichiara *come* va eliminato. Tenere le azioni
/// esplicite (invece di un generico `rm -rf`) permette di usare lo strumento
/// giusto — `simctl` per i simulatori, `brew` per Homebrew — e di validare
/// i percorsi prima di toccare il disco.
enum CleanupAction {
    /// Percorsi da spostare nel Cestino o eliminare, validati da `PathGuard`.
    case removePaths([String])
    /// Artefatti di build dentro una cartella di progetto (node_modules, Pods…).
    case removeProjectArtifacts([String])
    /// Bundle applicazione più i file collegati trovati dallo scanner.
    case removeApp(appPath: String, related: [String])
    case simctlDeleteDevice(udid: String)
    case simctlEraseDevice(udid: String)
    case simctlDeleteRuntime(id: String)
    case shell(tool: String, args: [String])
    /// Richiede privilegi di amministratore: mostra il comando letterale
    /// prima di chiedere la password.
    case privileged(shellCommand: String, displayPaths: [String])
    case dockerPrune(kind: DockerPruneKind)
    /// Solo visualizzazione: il software mostra il percorso e offre «Mostra nel
    /// Finder», ma non lo elimina in nessun caso. Usato per le aree in cui la
    /// decisione deve restare all'utente, nel Finder, file per file.
    case revealOnly([String])
    /// File singoli più vecchi di N giorni dentro una cartella temporanea
    /// dell'utente (`/var/folders/…`). Ogni file viene ricontrollato al
    /// momento dell'esecuzione: se nel frattempo è stato usato, si salta.
    case removeAgedFiles(root: String, olderThanDays: Int, files: [String: AgedFile])

    /// I percorsi che l'utente vedrà nel riepilogo. È la fonte di verità
    /// dell'interfaccia: se un percorso non compare qui, non viene toccato.
    var displayPaths: [String] {
        switch self {
        case .removePaths(let p): return p
        case .removeProjectArtifacts(let p): return p
        case .removeApp(let app, let related): return [app] + related
        case .privileged(_, let p): return p
        case .revealOnly(let p): return p
        // La cartella, non i singoli file: possono essere migliaia, e il
        // riepilogo li riassume nel comando.
        case .removeAgedFiles(let root, _, _): return [root]
        case .simctlDeleteDevice, .simctlEraseDevice, .simctlDeleteRuntime,
             .shell, .dockerPrune: return []
        }
    }

    var needsAdmin: Bool {
        if case .privileged = self { return true }
        return false
    }

    /// Gli elementi informativi non sono selezionabili né eseguibili.
    var isInformationalOnly: Bool {
        if case .revealOnly = self { return true }
        return false
    }

    /// Descrizione tecnica dell'operazione, mostrata nel riepilogo accanto ai percorsi.
    var commandDescription: String {
        switch self {
        case .removePaths, .removeProjectArtifacts, .removeApp:
            return String(localized: "eliminazione file")
        case .simctlDeleteDevice(let u):
            return "xcrun simctl delete \(u)"
        case .simctlEraseDevice(let u):
            return "xcrun simctl erase \(u)"
        case .simctlDeleteRuntime(let i):
            return "xcrun simctl runtime delete \(i)"
        case .shell(let tool, let args):
            return ([tool] + args).joined(separator: " ")
        case .privileged(let cmd, _):
            return "sudo: \(cmd)"
        case .dockerPrune(let kind):
            return kind.command
        case .revealOnly:
            return String(localized: "solo visualizzazione — nessuna eliminazione")
        case .removeAgedFiles(_, let days, let files):
            return String(localized: "eliminazione di \(Plural.of(files.count, "file", "file")) non usati da più di \(days) giorni")
        }
    }
}

/// Un file temporaneo candidato all'eliminazione, con l'identità e lo spazio
/// occupato registrati durante l'analisi.
struct AgedFile: Hashable {
    let identity: FileIdentity
    let size: Int64
}

enum DockerPruneKind: String {
    case stoppedContainers
    case unusedImages
    case buildCache

    var command: String {
        switch self {
        case .stoppedContainers: return "docker container prune -f"
        case .unusedImages: return "docker image prune -a -f"
        case .buildCache: return "docker builder prune -a -f"
        }
    }

    var args: [String] {
        switch self {
        case .stoppedContainers: return ["container", "prune", "-f"]
        case .unusedImages: return ["image", "prune", "-a", "-f"]
        case .buildCache: return ["builder", "prune", "-a", "-f"]
        }
    }
}

// MARK: - Elemento eliminabile

final class CleanupItem: Identifiable, ObservableObject, Hashable {
    let id = UUID()
    /// Nome breve mostrato in elenco.
    let title: String
    /// Che cos'è questo dato.
    let detail: String
    /// Che cosa succede concretamente dopo l'eliminazione.
    let consequence: String
    let action: CleanupAction
    let risk: RiskLevel
    /// Data d'uso più recente, quando ricavabile. È l'informazione che ha
    /// permesso di capire che il runtime iOS 26.4 era abbandonato.
    let lastUsed: Date?
    /// Dimensione per singolo percorso, per mostrare il dettaglio nel riepilogo.
    let perPathSize: [String: Int64]
    let size: Int64
    /// Nota di avvertimento specifica, mostrata in evidenza (es. il salvaschermo
    /// ancora impostato sugli sfondi aerial che li farebbe riscaricare).
    let warning: String?
    /// Elementi che si escludono a vicenda condividono questa chiave: p.es.
    /// «elimina il simulatore» e «azzeralo» agiscono sullo stesso spazio, e
    /// selezionarli entrambi conterebbe due volte gli stessi GB.
    let exclusiveGroup: String?
    /// Identità fisica di ogni percorso al momento dell'analisi. Il motore la
    /// ricontrolla prima di eliminare: un percorso sostituito nel frattempo
    /// viene rifiutato anche se ha lo stesso nome.
    let identities: [String: FileIdentity]
    /// Bundle id delle app che devono essere chiuse prima di eseguire: la
    /// cache di un programma aperto può essere riscritta a metà eliminazione.
    let requiredStoppedApps: [String]

    @Published var isSelected: Bool
    @Published var isExpanded: Bool = false
    /// Categoria o scheda da cui proviene l'elemento. Serve a raggruppare il
    /// riepilogo di conferma per provenienza invece di mostrare un elenco
    /// piatto. Assegnata dal modello dopo l'analisi.
    var origin: String = String(localized: "Pulizia")

    init(title: String,
         detail: String,
         consequence: String,
         action: CleanupAction,
         risk: RiskLevel,
         size: Int64,
         perPathSize: [String: Int64] = [:],
         lastUsed: Date? = nil,
         warning: String? = nil,
         exclusiveGroup: String? = nil,
         requiredStoppedApps: [String] = [],
         preselect: Bool? = nil) {
        self.exclusiveGroup = exclusiveGroup
        self.requiredStoppedApps = requiredStoppedApps
        // Gli elementi nascono durante l'analisi: catturare qui l'identità
        // vale per tutti gli scanner senza che ciascuno debba ricordarsene.
        var identities: [String: FileIdentity] = [:]
        for path in action.displayPaths {
            if let identity = FileIdentity.of(path) { identities[path] = identity }
        }
        self.identities = identities
        self.title = title
        self.detail = detail
        self.consequence = consequence
        self.action = action
        self.risk = risk
        self.size = size
        self.perPathSize = perPathSize
        self.lastUsed = lastUsed
        self.warning = warning
        // Un elemento con un avvertimento non viene mai preselezionato, anche
        // se tecnicamente è una cache sicura: l'utente deve leggere la nota.
        let defaultSelection = risk.autoSelectable && warning == nil && !action.isInformationalOnly
        self.isSelected = action.isInformationalOnly ? false : (preselect ?? defaultSelection)
    }

    static func == (a: CleanupItem, b: CleanupItem) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Categoria

final class CleanupCategory: Identifiable, ObservableObject {
    let id: CategoryID
    let name: String
    let symbol: String
    /// Spiegazione mostrata in testa alla categoria: che cosa contiene e
    /// perché occupa spazio.
    let explanation: String
    @Published var items: [CleanupItem] = []
    @Published var didScan: Bool = false
    @Published var scanNote: String?
    /// Se il programma di riferimento è installato, rimosso a metà o assente.
    @Published var presence: ToolPresence = .installed
    /// Analisi in corso solo per questa categoria.
    @Published var isScanning: Bool = false

    init(id: CategoryID, name: String, symbol: String, explanation: String) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.explanation = explanation
    }

    /// Elementi con una sola alternativa per gruppo esclusivo. Serve per i
    /// totali: «elimina il simulatore» e «azzeralo» riguardano gli stessi GB,
    /// sommarli gonfierebbe il recuperabile del doppio.
    var deduplicatedItems: [CleanupItem] {
        var seen = Set<String>()
        return items.filter { item in
            guard let group = item.exclusiveGroup else { return true }
            return seen.insert(group).inserted
        }
    }

    var totalSize: Int64 {
        deduplicatedItems.filter { !$0.action.isInformationalOnly }.reduce(0) { $0 + $1.size }
    }
    var selectedItems: [CleanupItem] { items.filter(\.isSelected) }
    var selectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.size } }

    /// Dopo una selezione in blocco, lascia attiva una sola alternativa per
    /// ciascun gruppo esclusivo.
    func enforceExclusivity() {
        var seen = Set<String>()
        for item in items {
            guard item.isSelected, let group = item.exclusiveGroup else { continue }
            if seen.contains(group) { item.isSelected = false } else { seen.insert(group) }
        }
    }
}

enum CategoryID: String, CaseIterable, Identifiable {
    case xcode
    case simulators
    case android
    case packageManagers
    case projectArtifacts
    case browsers
    case appCaches
    case aiModels
    case orphans
    case system
    case wallpapers
    case docker
    case largeFiles

    var id: String { rawValue }
}

// MARK: - Versioni multiple

/// Un elemento all'interno di un gruppo di versioni duplicate.
struct VersionEntry: Identifiable {
    let id = UUID()
    let label: String
    /// Versione normalizzata per l'ordinamento (es. "26.5", "28.2.13676358").
    let version: String
    let paths: [String]
    let size: Int64
    let lastUsed: Date?
    let action: CleanupAction
    let risk: RiskLevel
    /// Note come "in uso dal progetto corrente" o "runtime dell'Xcode attivo".
    let note: String?
    /// `true` quando lo strumento sconsiglia di eliminarlo (versione più
    /// recente, o attualmente in uso).
    let recommendedToKeep: Bool
}

final class VersionGroup: Identifiable, ObservableObject {
    let id = UUID()
    let title: String
    let symbol: String
    /// Perché avere più versioni è normale, e quando invece è solo spreco.
    let rationale: String
    let entries: [VersionEntry]
    /// Insieme degli id da eliminare. Parte vuoto: nessuna preselezione.
    @Published var markedForRemoval: Set<UUID> = []

    init(title: String, symbol: String, rationale: String, entries: [VersionEntry]) {
        self.title = title
        self.symbol = symbol
        self.rationale = rationale
        self.entries = entries.sorted { a, b in
            VersionGroup.compare(a.version, b.version) > 0
        }
    }

    var totalSize: Int64 { entries.reduce(0) { $0 + $1.size } }
    var reclaimableSize: Int64 {
        entries.filter { markedForRemoval.contains($0.id) }.reduce(0) { $0 + $1.size }
    }
    /// Quante versioni resterebbero dopo l'eliminazione. Se scende a zero
    /// l'interfaccia mostra un avviso: si sta rimuovendo tutto.
    var remainingCount: Int { entries.count - markedForRemoval.count }

    var suggestion: String {
        guard entries.count > 1 else { return String(localized: "Una sola versione installata: niente da consolidare.") }
        let keep = entries.first
        let extra = entries.dropFirst()
        let extraSize = extra.reduce(0) { $0 + $1.size }
        let formatted = ByteFormat.string(extraSize)
        let newest = keep?.label ?? "?"
        return String(localized: "\(entries.count) versioni installate. Tenendo solo \(newest) recuperi \(formatted).")
    }

    /// Confronto di versioni numeriche a segmenti: "26.10" > "26.9".
    static func compare(_ a: String, _ b: String) -> Int {
        let pa = a.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }
}

// MARK: - Applicazioni

/// Quanto siamo sicuri che un file appartenga davvero all'app selezionata.
enum MatchConfidence: Int, Comparable {
    /// Il nome del file o della cartella è esattamente il bundle identifier.
    case exact = 2
    /// Il bundle identifier è un prefisso (helper, estensioni, XPC).
    case prefix = 1
    /// Corrispondenza sul nome dell'app. Può produrre falsi positivi.
    case name = 0

    var label: String {
        switch self {
        case .exact: return String(localized: "Corrispondenza esatta")
        case .prefix: return String(localized: "Sotto-identificatore")
        case .name: return String(localized: "Corrispondenza sul nome")
        }
    }

    var caveat: String? {
        switch self {
        case .exact, .prefix: return nil
        case .name:
            return String(localized: "Trovato confrontando il nome dell'app, non l'identificatore: verifica che appartenga davvero a questa applicazione.")
        }
    }

    /// Le corrispondenze per nome non vengono mai preselezionate.
    var autoSelectable: Bool { self != .name }

    static func < (a: MatchConfidence, b: MatchConfidence) -> Bool { a.rawValue < b.rawValue }
}

final class RelatedFile: Identifiable, ObservableObject {
    let id = UUID()
    let path: String
    let kind: String
    let size: Int64
    let confidence: MatchConfidence
    let needsAdmin: Bool
    /// `true` se la cartella sembra contenere documenti o database dell'utente.
    let holdsUserData: Bool
    @Published var isSelected: Bool

    init(path: String, kind: String, size: Int64, confidence: MatchConfidence,
         needsAdmin: Bool = false, holdsUserData: Bool = false) {
        self.path = path
        self.kind = kind
        self.size = size
        self.confidence = confidence
        self.needsAdmin = needsAdmin
        self.holdsUserData = holdsUserData
        self.isSelected = confidence.autoSelectable
    }
}

final class AppEntry: Identifiable, ObservableObject {
    let id = UUID()
    let name: String
    let path: String
    let bundleID: String
    let version: String
    let size: Int64
    /// App di sistema o firmate Apple: elencate ma non eliminabili.
    let isProtected: Bool
    let protectionReason: String?

    /// Calcolata su richiesta: `mdls` è troppo lento per l'intero elenco.
    @Published var lastUsed: Date?
    @Published var isRunning: Bool = false
    @Published var related: [RelatedFile] = []
    @Published var didScanRelated: Bool = false
    /// La casella richiesta: attiva per impostazione predefinita.
    @Published var removeRelatedData: Bool = true
    @Published var backupUserData: Bool = true
    /// Inclusione nel piano di pulizia. Sta qui, sull'applicazione, e non nel
    /// modello globale: così cambiando app e tornando indietro la scelta è
    /// ancora quella fatta, e si possono accodare più app nello stesso piano.
    @Published var isMarkedForRemoval: Bool = false

    init(name: String, path: String, bundleID: String, version: String,
         size: Int64, lastUsed: Date?, isProtected: Bool, protectionReason: String?) {
        self.name = name
        self.path = path
        self.bundleID = bundleID
        self.version = version
        self.size = size
        self.lastUsed = lastUsed
        self.isProtected = isProtected
        self.protectionReason = protectionReason
    }

    var selectedRelated: [RelatedFile] { removeRelatedData ? related.filter(\.isSelected) : [] }
    var relatedSize: Int64 { selectedRelated.reduce(0) { $0 + $1.size } }
    var totalRemovalSize: Int64 { size + relatedSize }
    var hasUserDataSelected: Bool { selectedRelated.contains(where: \.holdsUserData) }
}

// MARK: - Esito

struct DeletionOutcome: Identifiable {
    let id = UUID()
    let title: String
    let succeeded: Bool
    let skipped: Bool
    let message: String
    let freed: Int64
    /// Percorso originale → posizione nel Cestino, per poterlo ripristinare.
    var trashed: [String: String] = [:]
}

// MARK: - Formattazione

enum ByteFormat {
    private static let formatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB]
        return f
    }()

    static func string(_ bytes: Int64) -> String {
        if bytes <= 0 { return "—" }
        return formatter.string(fromByteCount: bytes)
    }
}

/// Concordanza singolare/plurale. Scritta a mano perché l'italiano non ha una
/// regola meccanica utilizzabile qui e le stringhe tipo «1 voci» si notano.
enum Plural {
    /// `Plural.of(1, "cartella", "cartelle")` → "1 cartella"
    ///
    /// Le due forme sono `LocalizationValue`: il compilatore le estrae come
    /// chiavi di traduzione. Italiano e inglese hanno la stessa regola (uno /
    /// tutti gli altri), quindi basta tradurre le due parole.
    static func of(_ count: Int, _ singular: String.LocalizationValue, _ plural: String.LocalizationValue) -> String {
        "\(count.formatted()) \(word(count, singular, plural))"
    }

    /// Solo il sostantivo concordato, senza il numero.
    static func word(_ count: Int, _ singular: String.LocalizationValue, _ plural: String.LocalizationValue) -> String {
        count == 1 ? String(localized: singular) : String(localized: plural)
    }
}

enum DateFormat {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        // La lingua dell'app, non più l'italiano fisso.
        f.locale = Locale.autoupdatingCurrent
        return f
    }()

    static func string(_ date: Date?) -> String {
        guard let date else { return String(localized: "mai / sconosciuto") }
        return formatter.string(from: date)
    }

    /// "ultima attività: 4 mesi fa" — il segnale più utile per decidere.
    ///
    /// La formulazione è deliberatamente neutra: per alcuni elementi la data
    /// viene dall'ultimo utilizzo registrato da Spotlight o da CoreSimulator,
    /// per altri dall'ultima modifica del file. Scrivere «usato» in entrambi i
    /// casi sarebbe impreciso.
    static func relative(_ date: Date?) -> String {
        guard let date else { return String(localized: "attività sconosciuta") }
        let days = Int(Date().timeIntervalSince(date) / 86_400)
        switch days {
        case ..<1: return String(localized: "ultima attività: oggi")
        case 1: return String(localized: "ultima attività: ieri")
        case 2..<30: return String(localized: "ultima attività: \(days) giorni fa")
        case 30..<365:
            let months = max(1, days / 30)
            return months == 1 ? String(localized: "ultima attività: 1 mese fa")
                               : String(localized: "ultima attività: \(months) mesi fa")
        default:
            let years = max(1, days / 365)
            return years == 1 ? String(localized: "ultima attività: 1 anno fa")
                              : String(localized: "ultima attività: \(years) anni fa")
        }
    }
}
