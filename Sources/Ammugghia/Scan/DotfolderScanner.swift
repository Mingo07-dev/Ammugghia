import Foundation

/// Cartelle nascoste nella home lasciate da strumenti di sviluppo rimossi.
/// Elenco chiuso: ognuna è associata a una prova di presenza (app o comando).
/// Si propone solo se la prova manca, la cartella non si usa da almeno 14
/// giorni e dentro non c'è nulla di protetto. Nessuna voce è preselezionata.
enum DotfolderScanner {

    struct Entry {
        let folder: String
        let bundleIDs: [String]
        let binaries: [String]
        let toolName: String
    }

    static let entries: [Entry] = [
        Entry(folder: ".vscode", bundleIDs: ["com.microsoft.VSCode"], binaries: ["code"], toolName: "Visual Studio Code"),
        Entry(folder: ".vscode-insiders", bundleIDs: ["com.microsoft.VSCodeInsiders"], binaries: ["code-insiders"], toolName: "VS Code Insiders"),
        Entry(folder: ".cursor", bundleIDs: ["com.todesktop.230313mzl4w4u92"], binaries: ["cursor"], toolName: "Cursor"),
        Entry(folder: ".windsurf", bundleIDs: ["com.exafunction.windsurf"], binaries: [], toolName: "Windsurf"),
        Entry(folder: ".gitkraken", bundleIDs: ["com.axosoft.gitkraken"], binaries: [], toolName: "GitKraken"),
        Entry(folder: ".arduinoIDE", bundleIDs: ["cc.arduino.IDE2"], binaries: [], toolName: "Arduino IDE"),
        Entry(folder: ".arduino15", bundleIDs: ["cc.arduino.IDE2"], binaries: ["arduino-cli"], toolName: "Arduino"),
        Entry(folder: ".atom", bundleIDs: ["com.github.atom"], binaries: ["atom"], toolName: "Atom"),
        Entry(folder: ".deno", bundleIDs: [], binaries: ["deno"], toolName: "Deno"),
        Entry(folder: ".rustup", bundleIDs: [], binaries: ["rustup", "cargo", "rustc"], toolName: "rustup"),
    ]

    static let minimumUnusedDays = 14

    /// Decisione pura, verificata dall'autotest.
    static func isAbandoned(toolPresent: Bool, lastUsed: Date?, now: Date = Date()) -> Bool {
        guard !toolPresent, let lastUsed else { return false }
        return now.timeIntervalSince(lastUsed) >= Double(minimumUnusedDays) * 86_400
    }

    static func scan() -> [CleanupItem] {
        memo.value {
            let installed = OrphanScanner.installedBundleIDs()
            let handled = Set(OrphanScanner.find().orphans.flatMap(\.paths))
            let directories = binarySearchDirectories()
            return entries.compactMap { item(for: $0, installed: installed, handled: handled, directories: directories) }
        }
    }

    private static let memo = ScanMemo<[CleanupItem]>()

    static func invalidate() { memo.invalidate() }

    private static func item(for entry: Entry, installed: Set<String>, handled: Set<String>, directories: [String]) -> CleanupItem? {
        let path = ScanSupport.home + "/" + entry.folder
        guard ScanSupport.isDirectory(path), !handled.contains(path), PathGuard.isAllowedHomeDotDirectory(path) else { return nil }
        let present = entry.bundleIDs.contains(where: installed.contains)
            || entry.binaries.contains { binaryExists($0, directories: directories) }
        let lastUsed = lastActivity(path)
        guard isAbandoned(toolPresent: present, lastUsed: lastUsed) else { return nil }
        // Doppia barriera: lo stesso controllo dell'eliminazione, adesso.
        guard (try? PathGuard.validate(path)) != nil else { return nil }

        let size = Shell.diskSize(path)
        guard size > 0 else { return nil }
        return CleanupItem(
            title: String(localized: "Cartella di \(entry.toolName): ~/\(entry.folder)"),
            detail: String(localized: "\(entry.toolName) non risulta installato (né l'app né il comando) e la cartella non viene modificata da più di \(minimumUnusedDays) giorni. Può contenere estensioni, impostazioni e componenti scaricati dallo strumento."),
            consequence: String(localized: "Se reinstalli \(entry.toolName) le estensioni e le impostazioni vanno ricreate. Va nel Cestino: lo recuperi da lì."),
            action: .removePaths([path]), risk: .userData, size: size, perPathSize: [path: size],
            lastUsed: lastUsed, preselect: false)
    }

    /// Dove cercare un comando: `which` non vede le cartelle che solo la shell
    /// dell'utente aggiunge al PATH (`~/.cargo/bin`, i shim di mise e asdf) né
    /// i formuli Homebrew «keg-only», che vivono in `opt/<formula>/bin`.
    static func binarySearchDirectories(home: String = ScanSupport.home,
                                        brewRoots: [String] = ["/opt/homebrew/opt", "/usr/local/opt"]) -> [String] {
        var directories = [".cargo/bin", ".deno/bin", ".local/bin", "bin", ".local/share/mise/shims", ".asdf/shims"]
            .map { home + "/" + $0 }
        directories += ["/opt/homebrew/bin", "/usr/local/bin"]
        for root in brewRoots {
            directories += ScanSupport.children(of: root).map { $0 + "/bin" }
        }
        return directories
    }

    static func binaryExists(_ name: String, directories: [String] = binarySearchDirectories()) -> Bool {
        if Shell.which(name) != nil { return true }
        return directories.contains { FileManager.default.isExecutableFile(atPath: $0 + "/" + name) }
    }

    /// Ultima modifica più recente fra la cartella e i suoi figli diretti.
    private static func lastActivity(_ path: String) -> Date? {
        ([path] + ScanSupport.children(of: path, includeHidden: true))
            .compactMap(ScanSupport.modificationDate).max()
    }
}
