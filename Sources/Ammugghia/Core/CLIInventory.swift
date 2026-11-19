import Foundation

/// Uno strumento da riga di comando installato da un gestore di pacchetti.
struct CLITool: Identifiable, Hashable {
    enum Source: String {
        case brewFormula, brewCask, npm, uv, rustup

        var label: String {
            switch self {
            case .brewFormula: return "Homebrew"
            case .brewCask: return "Homebrew (cask)"
            case .npm: return "npm -g"
            case .uv: return "uv tool"
            case .rustup: return "rustup"
            }
        }

        /// uv e rustup si mostrano soltanto: si gestiscono con i loro comandi.
        var isManaged: Bool { self == .brewFormula || self == .brewCask || self == .npm }
    }

    let source: Source
    let name: String
    let version: String
    let latestVersion: String?
    let isOutdated: Bool
    /// Homebrew: installato dall'utente (e non solo come dipendenza).
    let installedOnRequest: Bool
    /// Altri strumenti installati che ne hanno bisogno.
    var neededBy: [String] = []
    let summary: String?
    /// Annotazione dello strumento stesso (es. «attivo, predefinito» di rustup).
    var note: String? = nil

    var id: String { source.rawValue + ":" + name }
}

/// Un comando esterno già pronto, mostrato per intero nella conferma.
struct CLICommand: Hashable {
    let executable: String
    let arguments: [String]
    var display: String { ([(executable as NSString).lastPathComponent] + arguments).joined(separator: " ") }
}

enum CLIInventory {

    struct Snapshot {
        var tools: [CLITool] = []
        var brewPath: String?
        var npmPath: String?
    }

    // MARK: - Percorsi e ambiente

    static func brewPath() -> String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first(where: FileManager.default.isExecutableFile)
    }

    static func npmPath() -> String? {
        ["/opt/homebrew/bin/npm", "/usr/local/bin/npm"].first(where: FileManager.default.isExecutableFile)
            ?? Shell.which("npm")
    }

    /// Da Finder il PATH è minimo: npm ha bisogno di `node`, che sta con Homebrew.
    static func environment(readOnly: Bool = false) -> [String: String] {
        let current = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        var env = ["PATH": "/opt/homebrew/bin:/usr/local/bin:" + current]
        if readOnly {
            env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
            env["HOMEBREW_NO_ANALYTICS"] = "1"
        }
        return env
    }

    // MARK: - Lettura

    static func load() -> Snapshot {
        var snapshot = Snapshot(brewPath: brewPath(), npmPath: npmPath())
        let env = environment(readOnly: true)

        if let brew = snapshot.brewPath {
            let r = Shell.run(brew, ["info", "--json=v2", "--installed"], timeout: 120, environment: env)
            snapshot.tools += parseBrew(ScanSupport.jsonObject(fromString: r.stdout))
        }
        if let npm = snapshot.npmPath {
            let list = Shell.run(npm, ["ls", "-g", "--depth=0", "--json"], timeout: 60, environment: env)
            // `npm outdated` esce con 1 quando c'è qualcosa da aggiornare: conta l'output.
            let outdated = Shell.run(npm, ["outdated", "-g", "--json"], timeout: 120, environment: env)
            snapshot.tools += parseNpm(list: ScanSupport.jsonObject(fromString: list.stdout),
                                       outdated: ScanSupport.jsonObject(fromString: outdated.stdout))
        }
        if let uv = Shell.which("uv") {
            snapshot.tools += parseUV(Shell.run(uv, ["tool", "list"], timeout: 30, environment: env).stdout)
        }
        if let rustup = Shell.which("rustup") ?? existing(ScanSupport.home + "/.cargo/bin/rustup") {
            snapshot.tools += parseRustup(Shell.run(rustup, ["toolchain", "list"], timeout: 30, environment: env).stdout)
        }
        snapshot.tools = linkNodeDependents(snapshot.tools)
        return snapshot
    }

    private static func existing(_ path: String) -> String? {
        FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    // MARK: - Analisi (pure, verificate dall'autotest)

    /// `brew info --json=v2 --installed`. Il «necessario a» si calcola in
    /// memoria dalle dipendenze di esecuzione degli altri formuli installati.
    static func parseBrew(_ json: Any?) -> [CLITool] {
        guard let root = json as? [String: Any] else { return [] }
        let formulae = root["formulae"] as? [[String: Any]] ?? []
        let casks = root["casks"] as? [[String: Any]] ?? []

        var dependents: [String: [String]] = [:]
        for formula in formulae {
            guard let name = formula["name"] as? String,
                  let installed = (formula["installed"] as? [[String: Any]])?.last else { continue }
            for dep in installed["runtime_dependencies"] as? [[String: Any]] ?? [] {
                if let full = dep["full_name"] as? String { dependents[full, default: []].append(name) }
            }
        }

        // Anche i cask dichiarano formuli da cui dipendono.
        for cask in casks {
            guard let token = cask["token"] as? String else { continue }
            let needed = (cask["depends_on"] as? [String: Any])?["formula"] as? [String] ?? []
            for formula in needed { dependents[formula, default: []].append("cask: " + token) }
        }

        var tools: [CLITool] = []
        for formula in formulae {
            guard let name = formula["name"] as? String else { continue }
            let installed = (formula["installed"] as? [[String: Any]])?.last
            let full = formula["full_name"] as? String ?? name
            tools.append(CLITool(
                source: .brewFormula, name: name,
                version: installed?["version"] as? String ?? "?",
                latestVersion: (formula["versions"] as? [String: Any])?["stable"] as? String,
                isOutdated: formula["outdated"] as? Bool ?? false,
                installedOnRequest: installed?["installed_on_request"] as? Bool ?? false,
                neededBy: (dependents[full] ?? []).sorted(),
                summary: formula["desc"] as? String))
        }
        for cask in casks {
            guard let token = cask["token"] as? String else { continue }
            tools.append(CLITool(
                source: .brewCask, name: token,
                version: cask["installed"] as? String ?? "?",
                latestVersion: cask["version"] as? String,
                isOutdated: cask["outdated"] as? Bool ?? false,
                installedOnRequest: true,
                summary: cask["desc"] as? String))
        }
        return tools
    }

    /// `npm ls -g --depth=0 --json` più `npm outdated -g --json`.
    static func parseNpm(list: Any?, outdated: Any?) -> [CLITool] {
        guard let root = list as? [String: Any],
              let dependencies = root["dependencies"] as? [String: Any] else { return [] }
        let newer = outdated as? [String: Any] ?? [:]
        return dependencies.keys.sorted().map { name in
            let version = (dependencies[name] as? [String: Any])?["version"] as? String ?? "?"
            let latest = (newer[name] as? [String: Any])?["latest"] as? String
            return CLITool(source: .npm, name: name, version: version,
                           latestVersion: latest ?? version,
                           isOutdated: latest != nil && latest != version,
                           installedOnRequest: true, summary: nil)
        }
    }

    /// `uv tool list`: «nome vX.Y» seguito da righe «- comando».
    static func parseUV(_ text: String) -> [CLITool] {
        text.split(separator: "\n").compactMap { line in
            guard !line.hasPrefix("-"), !line.hasPrefix(" ") else { return nil }
            let parts = line.split(separator: " ")
            guard parts.count >= 2 else { return nil }
            return CLITool(source: .uv, name: String(parts[0]), version: String(parts[1]).trimmingCharacters(in: CharacterSet(charactersIn: "v")),
                           latestVersion: nil, isOutdated: false, installedOnRequest: true, summary: nil)
        }
    }

    /// `rustup toolchain list`: «stable-aarch64-apple-darwin (active, default)».
    static func parseRustup(_ text: String) -> [CLITool] {
        text.split(separator: "\n").compactMap { line in
            let name = line.split(separator: " ").first.map(String.init) ?? ""
            guard !name.isEmpty else { return nil }
            let note = line.firstIndex(of: "(").map { String(line[$0...]) }
            return CLITool(source: .rustup, name: name, version: "", latestVersion: nil,
                           isOutdated: false, installedOnRequest: true, summary: nil, note: note)
        }
    }

    /// Node è necessario agli strumenti npm globali: toglierlo li romperebbe.
    static func linkNodeDependents(_ tools: [CLITool]) -> [CLITool] {
        let globals = tools.filter { $0.source == .npm }.map { "npm: " + $0.name }
        guard !globals.isEmpty else { return tools }
        return tools.map { tool in
            guard tool.source == .brewFormula, tool.name == "node" || tool.name.hasPrefix("node@") else { return tool }
            var linked = tool
            linked.neededBy = (tool.neededBy + globals).sorted()
            return linked
        }
    }

    // MARK: - Comandi

    /// Nomi di pacchetti ammessi: finiscono in un comando, e un nome che
    /// inizia con «-» diventerebbe un'opzione.
    static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix("-")
            && name.range(of: "^[A-Za-z0-9@._+/-]+$", options: .regularExpression) != nil
    }

    static func upgrade(_ tool: CLITool, in snapshot: Snapshot) -> CLICommand? {
        guard isValidName(tool.name) else { return nil }
        switch tool.source {
        case .brewFormula: return snapshot.brewPath.map { CLICommand(executable: $0, arguments: ["upgrade", tool.name]) }
        case .brewCask: return snapshot.brewPath.map { CLICommand(executable: $0, arguments: ["upgrade", "--cask", tool.name]) }
        case .npm: return snapshot.npmPath.map { CLICommand(executable: $0, arguments: ["install", "-g", tool.name + "@latest"]) }
        case .uv, .rustup: return nil
        }
    }

    /// Mai se altri strumenti installati ne hanno bisogno.
    static func uninstall(_ tool: CLITool, in snapshot: Snapshot) -> CLICommand? {
        guard isValidName(tool.name), tool.neededBy.isEmpty else { return nil }
        switch tool.source {
        case .brewFormula: return snapshot.brewPath.map { CLICommand(executable: $0, arguments: ["uninstall", tool.name]) }
        case .brewCask: return snapshot.brewPath.map { CLICommand(executable: $0, arguments: ["uninstall", "--cask", tool.name]) }
        case .npm: return snapshot.npmPath.map { CLICommand(executable: $0, arguments: ["uninstall", "-g", tool.name]) }
        case .uv, .rustup: return nil
        }
    }

    enum GlobalAction: CaseIterable {
        case update, upgradeAll, autoremove, cleanup

        var arguments: [String] {
            switch self {
            case .update: return ["update"]
            case .upgradeAll: return ["upgrade"]
            case .autoremove: return ["autoremove"]
            case .cleanup: return ["cleanup"]
            }
        }

        var title: String {
            switch self {
            case .update: return String(localized: "Aggiorna l'elenco (brew update)")
            case .upgradeAll: return String(localized: "Aggiorna tutto (brew upgrade)")
            case .autoremove: return String(localized: "Rimuovi dipendenze inutili (brew autoremove)")
            case .cleanup: return String(localized: "Pulisci le vecchie versioni (brew cleanup)")
            }
        }

        var effect: String {
            switch self {
            case .update: return String(localized: "Scarica l'elenco aggiornato delle formule. Non installa né rimuove nulla.")
            case .upgradeAll: return String(localized: "Aggiorna tutti i formuli e i cask installati all'ultima versione. Può richiedere molti minuti e sostituire programmi che stai usando.")
            case .autoremove: return String(localized: "Rimuove i formuli installati solo come dipendenza di qualcosa che non c'è più.")
            case .cleanup: return String(localized: "Elimina le vecchie versioni dei formuli e la cache dei download di Homebrew.")
            }
        }
    }

    static func command(_ action: GlobalAction, in snapshot: Snapshot) -> CLICommand? {
        snapshot.brewPath.map { CLICommand(executable: $0, arguments: action.arguments) }
    }
}
