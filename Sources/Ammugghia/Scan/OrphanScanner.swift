import Foundation
import AppKit
import Darwin

/// Residui di applicazioni già disinstallate.
///
/// Trascinare un'app nel Cestino lascia sul disco il suo container sandbox,
/// le preferenze, le cache e lo stato delle finestre: a volte diversi GB.
/// Il punto di partenza sono solo le prove forti che un'app è esistita — il
/// container in `~/Library/Containers` o lo stato salvato delle finestre —
/// e da lì si raccolgono i file con lo stesso bundle id esatto.
///
/// Un bundle id è considerato orfano solo se nessuna app installata (né un
/// bundle annidato in un'app), nessuna app registrata in LaunchServices e
/// nessun processo in esecuzione gli corrisponde, né direttamente né come
/// estensione, e se il container non è stato usato nelle ultime due
/// settimane. Nel dubbio non è orfano.
enum OrphanScanner {

    struct Context {
        let installed: Set<String>
        let isRegistered: (String) -> Bool
        let isRunning: (String) -> Bool

        static func current() -> Context {
            let installed = installedBundleIDs()
            let running = runningBundleIDs()
            return Context(
                installed: installed,
                isRegistered: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil },
                isRunning: { running.contains($0) })
        }
    }

    /// Bundle id delle app nelle cartelle Applicazioni, letti dall'Info.plist
    /// senza misurare nulla: `AppInventory.applications()` calcola anche le
    /// dimensioni, troppo lento per un controllo.
    static func installedBundleIDs() -> Set<String> {
        var ids = Set<String>()
        let roots = ["/Applications", "/Applications/Utilities", "/System/Applications",
                     "/System/Applications/Utilities", ScanSupport.home + "/Applications"]
        for root in roots {
            for child in ScanSupport.children(of: root) {
                let bundles = child.hasSuffix(".app")
                    ? [child]
                    : ScanSupport.children(of: child).filter { $0.hasSuffix(".app") }
                for bundle in bundles {
                    if let id = Bundle(path: bundle)?.bundleIdentifier { ids.insert(id) }
                    // Servizi XPC, estensioni, elementi di login e helper hanno
                    // un bundle id proprio, spesso senza il prefisso dell'app
                    // (es. DisplayLink): anche i loro container sono vivi.
                    for nested in nestedBundles(in: bundle) {
                        if let id = Bundle(path: nested)?.bundleIdentifier { ids.insert(id) }
                    }
                }
            }
        }
        return ids
    }

    static func nestedBundles(in app: String) -> [String] {
        let contents = app + "/Contents"
        let places = ["XPCServices", "PlugIns", "Library/LoginItems", "Library/LaunchServices",
                      "Library/SystemExtensions", "Helpers", "MacOS", "Frameworks"]
        let extensions: Set<String> = ["app", "xpc", "appex", "systemextension"]
        var found: [String] = []
        for place in places {
            for child in ScanSupport.children(of: contents + "/" + place)
            where extensions.contains((child as NSString).pathExtension) {
                found.append(child)
                // Un livello in più: helper con servizi XPC propri.
                found += ScanSupport.children(of: child + "/Contents/XPCServices")
            }
        }
        return found
    }

    /// Bundle id di tutti i processi in esecuzione, non solo delle app con
    /// finestre: servizi XPC e agenti in background non compaiono in
    /// `NSWorkspace.runningApplications`, ma usano comunque il loro container.
    static func runningBundleIDs() -> Set<String> {
        var ids = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return ids }
        var pids = [pid_t](repeating: 0, count: Int(capacity) * 2)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return ids }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        var seen = Set<String>()
        for pid in pids.prefix(Int(count)) where pid > 0 {
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { continue }
            var path = String(cString: buffer) as NSString
            // Risale al bundle più interno che contiene l'eseguibile.
            while path.length > 1 {
                if ["app", "xpc", "appex", "systemextension"].contains(path.pathExtension) {
                    let bundle = path as String
                    if seen.insert(bundle).inserted, let id = Bundle(path: bundle)?.bundleIdentifier {
                        ids.insert(id)
                    }
                    break
                }
                path = path.deletingLastPathComponent as NSString
            }
        }
        return ids
    }

    /// Ultima modifica del container e delle sue cartelle principali. Basta
    /// leggere le date delle cartelle, che macOS concede anche senza accesso
    /// al contenuto.
    static func lastActivity(ofContainer container: String) -> Date? {
        ["", "/.com.apple.containermanagerd.metadata.plist", "/Data", "/Data/Library",
         "/Data/Library/Preferences", "/Data/Library/Caches", "/Data/tmp"]
            .compactMap { ScanSupport.modificationDate(container + $0) }
            .max()
    }

    /// Un nome in forma reverse-DNS (`com.tizio.app`), non un UUID.
    static func looksLikeBundleID(_ name: String) -> Bool {
        if UUID(uuidString: name) != nil { return false }
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        }
    }

    /// Decisione pura, verificata dall'autotest.
    static func isOrphan(_ id: String, in context: Context) -> Bool {
        guard looksLikeBundleID(id) else { return false }
        // I container Apple appartengono al sistema, anche se nessuna app
        // visibile porta quel nome.
        let lowered = id.lowercased()
        if lowered.hasPrefix("com.apple.") || lowered.hasPrefix("group.com.apple.") { return false }
        // Estensioni e helper: `com.tizio.app.Share` appartiene a
        // `com.tizio.app`. Vale anche al contrario, per prudenza.
        for app in context.installed {
            if id == app || id.hasPrefix(app + ".") || app.hasPrefix(id + ".") { return false }
        }
        // LaunchServices conosce anche le app fuori da /Applications. Si
        // controllano il bundle id e tutti i suoi «antenati» con almeno due
        // componenti, così un'estensione di un'app installata altrove non
        // viene scambiata per orfana.
        let parts = id.split(separator: ".").map(String.init)
        for length in stride(from: parts.count, through: 2, by: -1) {
            let candidate = parts.prefix(length).joined(separator: ".")
            if context.isRegistered(candidate) || context.isRunning(candidate) { return false }
        }
        return true
    }

    /// Bundle id del container: dai metadati che macOS scrive in ogni
    /// container se leggibili (servono «Accesso completo al disco»),
    /// altrimenti dal nome della cartella quando è già un bundle id.
    static func bundleID(ofContainer path: String) -> String? {
        let metadata = path + "/.com.apple.containermanagerd.metadata.plist"
        if let data = FileManager.default.contents(atPath: metadata),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let id = plist["MCMMetadataIdentifier"] as? String {
            return id
        }
        let name = (path as NSString).lastPathComponent
        return looksLikeBundleID(name) ? name : nil
    }

    /// Un container leggibile: senza «Accesso completo al disco» macOS ne
    /// nega il contenuto, e una misura a zero byte sarebbe falsa.
    static func isReadable(_ container: String) -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: container + "/Data")) != nil
    }

    struct Orphan {
        let bundleID: String
        let paths: [String]
        let holdsData: Bool
    }

    struct Result {
        var orphans: [Orphan] = []
        /// Bundle id dei container che sembrano orfani ma non si possono leggere.
        var unreadable: [String] = []
    }

    /// Lo stesso risultato serve allo scanner, alla nota, alla visibilità
    /// della categoria e allo scanner di sistema: si ricalcola al massimo una
    /// volta al minuto invece che quattro volte per analisi.
    private static let memoLock = NSLock()
    nonisolated(unsafe) private static var memo: (date: Date, result: Result)?

    static func find() -> Result {
        memoLock.lock()
        defer { memoLock.unlock() }
        if let memo, Date().timeIntervalSince(memo.date) < 60 { return memo.result }
        let result = find(context: .current())
        memo = (Date(), result)
        return result
    }

    /// Invalida la memoria: dopo un'eliminazione i residui sono cambiati.
    static func invalidate() {
        memoLock.lock()
        memo = nil
        memoLock.unlock()
    }

    static func find(context: Context) -> Result {
        let home = ScanSupport.home
        let library = home + "/Library"
        var result = Result()
        var candidates: [String: String?] = [:]   // bundle id → container

        let recentLimit = Date().addingTimeInterval(-14 * 86_400)
        for container in ScanSupport.children(of: library + "/Containers") {
            guard let id = bundleID(ofContainer: container), isOrphan(id, in: context) else { continue }
            // Usato nelle ultime due settimane: qualcosa che non sappiamo
            // riconoscere lo sta ancora usando. Nel dubbio non è un residuo.
            if let activity = lastActivity(ofContainer: container), activity > recentLimit { continue }
            guard isReadable(container) else {
                result.unreadable.append(id)
                continue
            }
            candidates[id] = container
        }
        for state in ScanSupport.children(of: library + "/Saved Application State") {
            let name = (state as NSString).lastPathComponent
            guard name.hasSuffix(".savedState") else { continue }
            let id = String(name.dropLast(".savedState".count))
            if let activity = ScanSupport.modificationDate(state), activity > recentLimit { continue }
            if candidates[id] == nil, isOrphan(id, in: context) { candidates[id] = .some(nil) }
        }

        let groupContainers = ScanSupport.children(of: library + "/Group Containers")
        for (id, container) in candidates.sorted(by: { $0.key < $1.key }) {
            var paths: [String] = []
            if let container { paths.append(container) }
            // Gruppi condivisi: solo nelle due forme che contengono il bundle
            // id esatto, `TEAMID.<id>` e `group.<id>`. Il nome di un gruppo non
            // dice altro su chi lo usa: tutto il resto non viene proposto.
            for group in groupContainers {
                let name = (group as NSString).lastPathComponent
                if name == "group." + id || isTeamPrefixed(name, id),
                   (try? FileManager.default.contentsOfDirectory(atPath: group)) != nil {
                    paths.append(group)
                }
            }
            // Le cache con una voce dedicata altrove (es. WhatsApp nella
            // categoria «App») non si raccolgono qui: sarebbero contate due volte.
            let cacheHandledElsewhere = AppCacheScanner.libraryCacheNames.contains(id)
            let related = [
                library + "/Application Support/" + id,
                cacheHandledElsewhere ? nil : library + "/Caches/" + id,
                library + "/Preferences/" + id + ".plist",
                library + "/Saved Application State/" + id + ".savedState",
                library + "/HTTPStorages/" + id,
                library + "/HTTPStorages/" + id + ".binarycookies",
                library + "/WebKit/" + id,
                library + "/Cookies/" + id + ".binarycookies",
                library + "/Logs/" + id,
            ].compactMap { $0 }
            paths += related.filter(ScanSupport.exists)
            paths += ScanSupport.children(of: library + "/Preferences/ByHost").filter {
                let n = ($0 as NSString).lastPathComponent
                return n.hasPrefix(id + ".") && n.hasSuffix(".plist")
            }
            guard !paths.isEmpty else { continue }
            let holdsData = container != nil
                || paths.contains { $0.hasPrefix(library + "/Group Containers/") }
                || paths.contains(library + "/Application Support/" + id)
            result.orphans.append(Orphan(bundleID: id, paths: paths, holdsData: holdsData))
        }
        return result
    }

    static func isTeamPrefixed(_ name: String, _ id: String) -> Bool {
        guard name.hasSuffix("." + id) else { return false }
        let team = name.dropLast(id.count + 1)
        return team.count == 10 && team.allSatisfy { $0.isUppercase || $0.isNumber }
    }

    /// Bundle id orfani, usati dallo scanner di sistema per non riproporre le
    /// loro cache fra quelle generiche.
    static func orphanBundleIDs() -> Set<String> {
        Set(find().orphans.map(\.bundleID))
    }

    static func scan() -> [CleanupItem] {
        let result = find()
        let allPaths = result.orphans.flatMap(\.paths)
        let sizes = Shell.diskSizes(allPaths)

        return result.orphans.compactMap { orphan -> CleanupItem? in
            let perPath = Dictionary(uniqueKeysWithValues: orphan.paths.map { ($0, sizes[$0] ?? 0) })
            let total = perPath.values.reduce(0, +)
            guard total >= 1_000_000 else { return nil }
            let modified = orphan.paths.compactMap(ScanSupport.modificationDate).max()
            return CleanupItem(
                title: "Residui di «\(orphan.bundleID)»",
                detail: "File lasciati da un'applicazione che non risulta più installata: nessuna app con questo identificatore è presente sul Mac, registrata nel sistema o in esecuzione.\n\nSi raccolgono solo i file il cui nome è esattamente l'identificatore dell'app."
                    + (orphan.holdsData ? " Il container o i dati di supporto possono contenere documenti e impostazioni dell'app." : ""),
                consequence: "Se reinstalli l'app riparte da zero, senza impostazioni né dati locali. "
                    + (orphan.holdsData ? "Documenti salvati solo dentro l'app vanno persi: con il Cestino restano recuperabili." : "Nessun'altra conseguenza."),
                action: .removePaths(orphan.paths),
                risk: orphan.holdsData ? .userData : .redownload,
                size: total, perPathSize: perPath, lastUsed: modified,
                preselect: false)
        }
        .sorted { $0.size > $1.size }
    }

    static func summary() -> String? {
        let unreadable = find().unreadable
        guard !unreadable.isEmpty else { return nil }
        let names = unreadable.prefix(8).joined(separator: ", ") + (unreadable.count > 8 ? "…" : "")
        return "\(Plural.of(unreadable.count, "possibile residuo non accessibile", "possibili residui non accessibili")) (\(names)): macOS protegge i dati delle altre app. Concedi «Accesso completo al disco» ad Ammugghia in Impostazioni di Sistema → Privacy e sicurezza per misurarli e proporli."
    }
}
