import Foundation
import AppKit

/// Inventario delle applicazioni e ricerca dei file collegati per la
/// disinstallazione completa.
enum AppInventory {

    /// Identificatori di bundle che non vengono mai proposti per la rimozione.
    static let protectedBundlePrefixes = [
        "com.apple.",
    ]

    /// App di sistema o critiche: elencate ma bloccate, con la ragione visibile.
    static let protectedNames: Set<String> = [
        "Safari.app", "Xcode.app", "Terminal.app", "Finder.app",
        "System Settings.app", "Impostazioni di Sistema.app",
    ]

    // MARK: Elenco applicazioni

    static func applications() -> [AppEntry] {
        var paths: [String] = []
        for dir in ["/Applications", "/Applications/Utilities", ScanSupport.home + "/Applications"] {
            guard ScanSupport.isDirectory(dir) else { continue }
            for child in ScanSupport.children(of: dir) {
                if child.hasSuffix(".app") {
                    paths.append(child)
                } else if ScanSupport.isDirectory(child) {
                    // Una sottocartella tipo /Applications/Adobe.
                    paths += ScanSupport.children(of: child).filter { $0.hasSuffix(".app") }
                }
            }
        }

        // Alcuni installer creano in /Applications un collegamento simbolico
        // all'app vera, che vive in una sottocartella (è il caso di OpenVPN
        // Connect). Il collegamento va scartato: `du` lo misura 0 byte, quindi
        // comparirebbe come app da 0 KB, e rimuoverlo cancellerebbe il link
        // lasciando l'applicazione al suo posto.
        paths = deduplicateResolvingLinks(paths)

        let sizes = Shell.diskSizes(paths)

        return paths.compactMap { path -> AppEntry? in
            let infoPlist = path + "/Contents/Info.plist"
            let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            let bundleID = ScanSupport.plistValue(infoPlist, key: "CFBundleIdentifier") ?? ""
            let version = ScanSupport.plistValue(infoPlist, key: "CFBundleShortVersionString") ?? "—"

            var isProtected = false
            var reason: String?
            if protectedBundlePrefixes.contains(where: { bundleID.hasPrefix($0) }) {
                isProtected = true
                reason = "Applicazione Apple: rimuoverla può compromettere il sistema o gli aggiornamenti."
            } else if protectedNames.contains((path as NSString).lastPathComponent) {
                isProtected = true
                reason = "Applicazione essenziale per lo sviluppo o per il sistema."
            } else if bundleID.isEmpty {
                isProtected = true
                reason = "Bundle senza identificatore: impossibile individuare con certezza i file collegati."
            }

            return AppEntry(
                name: name,
                path: path,
                bundleID: bundleID,
                version: version,
                size: sizes[path] ?? 0,
                lastUsed: nil,   // calcolata su richiesta: mdls è lento
                isProtected: isProtected,
                protectionReason: reason)
        }.sorted { $0.size > $1.size }
    }

    /// Scarta i collegamenti simbolici e, quando due percorsi puntano allo
    /// stesso bundle, conserva quello reale.
    static func deduplicateResolvingLinks(_ paths: [String]) -> [String] {
        var realPathToPath: [String: String] = [:]
        for path in paths {
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            let isLink = (attrs?[.type] as? FileAttributeType) == .typeSymbolicLink
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            if let existing = realPathToPath[resolved] {
                // Fra due percorsi che puntano allo stesso bundle vince quello
                // che non è un collegamento.
                let existingIsLink = (try? FileManager.default
                    .attributesOfItem(atPath: existing))?[.type] as? FileAttributeType == .typeSymbolicLink
                if existingIsLink && !isLink { realPathToPath[resolved] = path }
            } else {
                realPathToPath[resolved] = isLink ? resolved : path
            }
        }
        // Conserva solo percorsi che esistono davvero come cartelle.
        return Array(realPathToPath.values).filter { ScanSupport.isDirectory($0) }
    }

    // MARK: File collegati

    /// Cerca tutto ciò che appartiene a un'app. Ogni risultato porta il proprio
    /// livello di affidabilità: le corrispondenze basate sul nome non vengono
    /// mai preselezionate, perché «Notion» può comparire in cartelle che non
    /// appartengono a Notion.
    static func relatedFiles(for app: AppEntry) -> [RelatedFile] {
        let home = ScanSupport.home
        let bundleID = app.bundleID
        let appName = app.name
        var found: [(path: String, kind: String, confidence: MatchConfidence, admin: Bool, userData: Bool)] = []

        guard !bundleID.isEmpty else { return [] }

        /// Cerca in una cartella i figli che combaciano con l'identificatore o
        /// con il nome dell'app.
        func search(in directory: String, kind: String, admin: Bool = false, userData: Bool = false) {
            guard ScanSupport.isDirectory(directory) else { return }
            for child in ScanSupport.children(of: directory, includeHidden: true) {
                let name = (child as NSString).lastPathComponent
                let base = (name as NSString).deletingPathExtension

                if base == bundleID || name == bundleID {
                    found.append((child, kind, .exact, admin, userData))
                } else if base.hasPrefix(bundleID + ".") || name.hasPrefix(bundleID + ".") {
                    // Helper, estensioni, XPC: com.tizio.app.Helper
                    found.append((child, kind, .prefix, admin, userData))
                } else if name.contains(bundleID) {
                    found.append((child, kind, .prefix, admin, userData))
                } else if base.compare(appName, options: .caseInsensitive) == .orderedSame {
                    found.append((child, kind, .name, admin, userData))
                }
            }
        }

        // Aree utente.
        search(in: home + "/Library/Application Support", kind: "Dati di supporto", userData: true)
        search(in: home + "/Library/Caches", kind: "Cache")
        search(in: home + "/Library/Preferences", kind: "Preferenze")
        search(in: home + "/Library/Preferences/ByHost", kind: "Preferenze per host")
        search(in: home + "/Library/Containers", kind: "Container sandbox", userData: true)
        search(in: home + "/Library/Group Containers", kind: "Container condiviso", userData: true)
        search(in: home + "/Library/Saved Application State", kind: "Stato finestre")
        search(in: home + "/Library/Logs", kind: "Log")
        search(in: home + "/Library/WebKit", kind: "Dati WebKit")
        search(in: home + "/Library/HTTPStorages", kind: "Cookie e storage HTTP")
        search(in: home + "/Library/Cookies", kind: "Cookie")
        search(in: home + "/Library/LaunchAgents", kind: "Avvio automatico")
        search(in: home + "/Library/Application Scripts", kind: "Script dell'app")

        // Aree di sistema: richiedono privilegi.
        search(in: "/Library/Application Support", kind: "Dati di supporto (sistema)", admin: true, userData: true)
        search(in: "/Library/LaunchAgents", kind: "Avvio automatico (sistema)", admin: true)
        search(in: "/Library/LaunchDaemons", kind: "Servizio in background", admin: true)
        search(in: "/Library/PrivilegedHelperTools", kind: "Helper privilegiato", admin: true)
        search(in: "/Library/Caches", kind: "Cache (sistema)", admin: true)
        // `/Library/Preferences` NON viene cercata di proposito: contiene le
        // preferenze di sistema, e per tenerla fuori dall'allowlist di
        // PathGuard accetto di non ripulire i rari plist che un'app di terze
        // parti può lasciarci (pochi KB). Un residuo simile va rimosso a mano.

        // Deduplica mantenendo l'affidabilità più alta per ogni percorso.
        var best: [String: (kind: String, confidence: MatchConfidence, admin: Bool, userData: Bool)] = [:]
        for entry in found {
            if let existing = best[entry.path], existing.confidence >= entry.confidence { continue }
            best[entry.path] = (entry.kind, entry.confidence, entry.admin, entry.userData)
        }

        let paths = Array(best.keys)
        let sizes = Shell.diskSizes(paths)

        return paths.map { path in
            let meta = best[path]!
            // Un container che contiene Documents con dei file dentro è dato
            // dell'utente, non cache: va segnalato in modo evidente.
            let holdsData = meta.userData && containsUserDocuments(path)
            return RelatedFile(
                path: path,
                kind: meta.kind,
                size: sizes[path] ?? 0,
                confidence: meta.confidence,
                needsAdmin: meta.admin,
                holdsUserData: holdsData)
        }.sorted {
            if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
            return $0.size > $1.size
        }
    }

    /// Indizi che una cartella contenga documenti dell'utente e non solo cache.
    static func containsUserDocuments(_ path: String) -> Bool {
        let markers = ["Documents", "Data/Documents", "Library/Application Support"]
        for marker in markers {
            let candidate = path + "/" + marker
            if ScanSupport.isDirectory(candidate),
               !ScanSupport.children(of: candidate).isEmpty {
                return true
            }
        }
        // Database applicativi.
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: path) {
            let dataExtensions = ["sqlite", "sqlite3", "db", "realm", "json", "plist"]
            if entries.contains(where: { name in
                dataExtensions.contains(((name as NSString).pathExtension).lowercased())
            }) {
                return true
            }
        }
        return false
    }

    /// Costruisce gli elementi eliminabili per un'app selezionata: uno per il
    /// bundle più i dati non privilegiati, uno separato per i file che
    /// richiedono la password.
    static func removalItems(for app: AppEntry) -> [CleanupItem] {
        var items: [CleanupItem] = []
        // L'origine viene impostata qui e non dal chiamante, così il riepilogo
        // raggruppa correttamente anche il piano costruito dal pulsante
        // «Disinstalla ora», che non passa dalle selezioni globali.
        defer { for item in items { item.origin = "Disinstalla app · \(app.name)" } }
        let selected = app.selectedRelated
        let userPaths = selected.filter { !$0.needsAdmin }.map(\.path)
        let adminFiles = selected.filter(\.needsAdmin)

        var sizes: [String: Int64] = [app.path: app.size]
        for file in selected { sizes[file.path] = file.size }

        let userDataCount = selected.filter(\.holdsUserData).count
        let hasUserData = userDataCount > 0

        items.append(CleanupItem(
            title: "Disinstalla \(app.name) \(app.version)",
            detail: "Bundle dell'applicazione\(userPaths.isEmpty ? "" : " più \(userPaths.count) element\(userPaths.count == 1 ? "o" : "i") collegat\(userPaths.count == 1 ? "o" : "i")")."
                + (hasUserData ? "\n\nATTENZIONE: \(userDataCount) delle cartelle selezionate contiene dati dell'applicazione (documenti, database o impostazioni), non solo cache." : ""),
            consequence: hasUserData
                ? "L'app viene rimossa insieme ai suoi dati. Reinstallandola ripartirà da zero: accessi, preferenze e contenuti locali andranno rifatti."
                : "L'app viene rimossa. Reinstallandola ripartirà con le impostazioni predefinite.",
            action: .removeApp(appPath: app.path, related: userPaths),
            risk: hasUserData ? .userData : .redownload,
            size: app.size + selected.filter { !$0.needsAdmin }.reduce(0) { $0 + $1.size },
            perPathSize: sizes,
            lastUsed: app.lastUsed))

        if !adminFiles.isEmpty {
            let paths = adminFiles.map(\.path)
            let cmd = "rm -rf " + paths.map(Shell.shellQuote).joined(separator: " ")
            items.append(CleanupItem(
                title: "\(app.name): componenti di sistema (\(adminFiles.count))",
                detail: "Servizi in background, helper privilegiati e dati installati fuori dalla cartella utente:\n"
                    + adminFiles.map { "• \($0.kind): \($0.path)" }.joined(separator: "\n"),
                consequence: "Rimuove anche i servizi che l'app aveva installato a livello di sistema. Se non li elimini, restano attivi a vuoto dopo la disinstallazione.",
                action: .privileged(shellCommand: cmd, displayPaths: paths),
                risk: .redownload,
                size: adminFiles.reduce(0) { $0 + $1.size },
                perPathSize: Dictionary(uniqueKeysWithValues: adminFiles.map { ($0.path, $0.size) }),
                warning: "Richiede la password di amministratore."))
        }

        return items
    }
}
