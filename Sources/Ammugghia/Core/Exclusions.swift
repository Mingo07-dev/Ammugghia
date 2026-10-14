import Foundation
import Darwin

/// Cartelle e nomi che l'utente vuole tenere fuori da Ammugghia.
///
/// Le esclusioni possono solo **restringere**: tolgono percorsi dall'analisi e
/// dall'eliminazione, non ne aggiungono mai. Per questo `PathGuard` non le
/// conosce: sono un filtro in più, mai un permesso.
struct ExclusionRule: Codable, Hashable, Identifiable {
    enum Scope: String, Codable, CaseIterable, Hashable {
        case cleanup, largeFiles, duplicates, map

        var label: String {
            switch self {
            case .cleanup: return "Pulizia"
            case .largeFiles: return "File grandi"
            case .duplicates: return "Duplicati"
            case .map: return "Mappa"
            }
        }
    }

    var id = UUID()
    /// Un percorso assoluto (o con `~`) indica una cartella o un file e tutto
    /// ciò che contiene. Altrimenti è uno schema sul nome (`*.sparsebundle`,
    /// `Archivio*`) confrontato con ogni componente del percorso.
    var pattern: String
    var scopes: Set<Scope> = Set(Scope.allCases)

    var isPath: Bool { pattern.hasPrefix("/") || pattern.hasPrefix("~") }
    var expandedPath: String { PathGuard.normalize((pattern as NSString).expandingTildeInPath) }
}

/// Fotografia delle regole valida per tutta un'operazione: chi lavora in
/// background non legge le preferenze a metà strada.
struct ExclusionSet: Hashable {
    let rules: [ExclusionRule]

    static let empty = ExclusionSet(rules: [])
    static let defaultsKey = "exclusionRules"

    static func current() -> ExclusionSet {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let rules = try? JSONDecoder().decode([ExclusionRule].self, from: data) else { return .empty }
        return ExclusionSet(rules: rules)
    }

    static func save(_ rules: [ExclusionRule]) {
        if let data = try? JSONEncoder().encode(rules) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    /// Il percorso è escluso (o sta dentro qualcosa di escluso).
    func excludes(_ rawPath: String, scope: ExclusionRule.Scope) -> Bool {
        let path = PathGuard.normalize(rawPath)
        for rule in rules where rule.scopes.contains(scope) {
            if rule.isPath {
                let p = rule.expandedPath
                if path == p || path.hasPrefix(p + "/") { return true }
            } else {
                for component in path.split(separator: "/") where fnmatch(rule.pattern, String(component), 0) == 0 {
                    return true
                }
            }
        }
        return false
    }

    /// Per eliminare non basta che il percorso non sia escluso: non deve
    /// nemmeno *contenere* qualcosa di escluso, altrimenti eliminare la
    /// cartella eliminerebbe anche ciò che l'utente ha chiesto di tenere.
    func blocksDeletion(of rawPath: String) -> Bool {
        if excludes(rawPath, scope: .cleanup) { return true }
        let path = PathGuard.normalize(rawPath)
        return rules.contains { rule in
            rule.scopes.contains(.cleanup) && rule.isPath && rule.expandedPath.hasPrefix(path + "/")
        }
    }

    /// Impronta delle regole che toccano la mappa: se cambia, l'indice va
    /// rifatto, perché FSEvents non sa nulla delle esclusioni.
    var mapFingerprint: String {
        rules.filter { $0.scopes.contains(.map) }.map(\.pattern).sorted().joined(separator: "\u{1F}")
    }
}

extension CleanupItem {
    /// Lo stesso elemento senza i percorsi esclusi, oppure `nil` se non
    /// resta niente da fare. Le azioni che non sono un elenco di percorsi
    /// (comandi, simulatori) si tolgono per intero se toccano un'esclusione.
    func applying(_ exclusions: ExclusionSet) -> CleanupItem? {
        guard !exclusions.rules.isEmpty else { return self }
        // File temporanei: la cartella contiene migliaia di file, si tolgono
        // solo quelli esclusi.
        if case .removeAgedFiles(let root, let days, let files) = action {
            guard !exclusions.excludes(root, scope: .cleanup) else { return nil }
            let kept = files.filter { !exclusions.blocksDeletion(of: $0.key) }
            guard kept.count != files.count else { return self }
            guard !kept.isEmpty else { return nil }
            let total = kept.values.reduce(0) { $0 + $1.size }
            let item = CleanupItem(title: title, detail: detail, consequence: consequence,
                                   action: .removeAgedFiles(root: root, olderThanDays: days, files: kept),
                                   risk: risk, size: total, perPathSize: [root: total],
                                   lastUsed: lastUsed, warning: warning, exclusiveGroup: exclusiveGroup,
                                   requiredStoppedApps: requiredStoppedApps, preselect: isSelected)
            item.origin = origin
            return item
        }
        let blocked = action.displayPaths.filter(exclusions.blocksDeletion)
        guard !blocked.isEmpty else { return self }

        let newAction: CleanupAction
        switch action {
        case .removePaths(let paths):
            let kept = paths.filter { !blocked.contains($0) }
            guard !kept.isEmpty else { return nil }
            newAction = .removePaths(kept)
        case .removeProjectArtifacts(let paths):
            let kept = paths.filter { !blocked.contains($0) }
            guard !kept.isEmpty else { return nil }
            newAction = .removeProjectArtifacts(kept)
        case .revealOnly(let paths):
            let kept = paths.filter { !blocked.contains($0) }
            guard !kept.isEmpty else { return nil }
            newAction = .revealOnly(kept)
        case .removeApp(let app, let related):
            guard !blocked.contains(app) else { return nil }
            newAction = .removeApp(appPath: app, related: related.filter { !blocked.contains($0) })
        default:
            return nil
        }
        let kept = Set(newAction.displayPaths)
        let sizes = perPathSize.filter { kept.contains($0.key) }
        let item = CleanupItem(title: title, detail: detail, consequence: consequence,
                               action: newAction, risk: risk,
                               size: sizes.values.reduce(0, +), perPathSize: sizes,
                               lastUsed: lastUsed, warning: warning, exclusiveGroup: exclusiveGroup,
                               requiredStoppedApps: requiredStoppedApps, preselect: isSelected)
        item.origin = origin
        return item
    }
}
