import Foundation

/// Voci che puntano a qualcosa che non c'è più: collegamenti simbolici rotti
/// nelle cartelle dei comandi e file di `/etc/paths.d` che aggiungono al PATH
/// solo cartelle inesistenti. Non occupano spazio: sporcano il PATH e gli
/// elenchi dei comandi. Nessuna voce è preselezionata.
enum BrokenLinkScanner {

    /// Collegamenti rotti direttamente dentro `directory` (non ricorsivo).
    static func brokenLinks(in directory: String) -> [String] {
        ScanSupport.children(of: directory, includeHidden: true).filter {
            (try? PathGuard.validateStaleEntry($0)) != nil
        }
    }

    /// File di `/etc/paths.d` obsoleti.
    static func stalePathFiles(in directory: String = "/etc/paths.d") -> [String] {
        ScanSupport.children(of: directory, includeHidden: true).filter {
            (try? PathGuard.validateStaleEntry($0)) != nil
        }
    }

    static func scan() -> [CleanupItem] {
        var items: [CleanupItem] = []

        for directory in PathGuard.staleLinkDirectories {
            let links = brokenLinks(in: directory)
            guard !links.isEmpty else { continue }
            let targets = links.prefix(6).map { link -> String in
                let name = (link as NSString).lastPathComponent
                let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: link)) ?? "?"
                return "\(name) → \(target)"
            }.joined(separator: "\n")
            let more = links.count > 6 ? "\n…" : ""
            items.append(CleanupItem(
                title: String(localized: "\(Plural.of(links.count, "collegamento rotto", "collegamenti rotti")) in \(directory)"),
                detail: String(localized: "Collegamenti simbolici i cui programmi di destinazione non esistono più, di solito lasciati da un pacchetto disinstallato a metà.\n\n") + targets + more,
                consequence: String(localized: "Spariscono dall'elenco dei comandi della cartella. Nessun programma funzionante è coinvolto: la destinazione non esiste."),
                action: .removeStaleEntries(links), risk: .safe, size: 0, preselect: false))
        }

        for file in stalePathFiles() {
            let name = (file as NSString).lastPathComponent
            let dirs = (PathGuard.listedDirectories(inPathsFile: file) ?? []).joined(separator: "\n")
            items.append(CleanupItem(
                title: String(localized: "File del PATH obsoleto: \(name)"),
                detail: String(localized: "Il file \(file) aggiunge al PATH di tutti gli utenti queste cartelle, che non esistono più:\n\n") + dirs,
                consequence: String(localized: "Il PATH non include più cartelle inesistenti. Serve la password di amministratore e la modifica vale dalle nuove finestre del Terminale."),
                action: .removeStaleEntries([file]), risk: .safe, size: 0, preselect: false))
        }
        return items
    }

    static func presence() -> ToolPresence {
        scan().isEmpty
            ? .absent(detail: String(localized: "Nessun collegamento o percorso rotto."))
            : .installed
    }
}
