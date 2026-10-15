import Foundation

/// Modelli di intelligenza artificiale scaricati in locale: Ollama, Hugging
/// Face, LM Studio, PyTorch, Whisper, Keras. Su un Mac da sviluppo sono spesso
/// la voce più pesante, e finiscono in cartelle nascoste dove nessuno guarda.
///
/// Un elemento per modello, con la data d'ultima attività: decidere quale
/// tenere richiede di vederli uno per uno.
enum AIModelScanner {

    static let lmStudioBundleID = "ai.elementlabs.lmstudio"

    static func scan() -> [CleanupItem] {
        var items: [CleanupItem] = []
        items += ollamaModels()
        items += huggingFaceItems()
        items += lmStudioItems()
        items += perChildItems(root: torchHome() + "/hub", source: String(localized: "PyTorch Hub"),
                               detail: String(localized: "Modello o repository scaricato da PyTorch Hub."),
                               consequence: String(localized: "Lo script che lo usa lo riscarica al prossimo avvio."))
        items += perChildItems(root: ScanSupport.home + "/.cache/whisper", source: "Whisper",
                               detail: String(localized: "Modello di trascrizione vocale di OpenAI Whisper."),
                               consequence: String(localized: "Whisper lo riscarica alla prossima trascrizione con questo modello."))
        items += perChildItems(root: ScanSupport.home + "/.keras/models", source: "Keras",
                               detail: String(localized: "Pesi di un modello scaricati da Keras."),
                               consequence: String(localized: "Keras li riscarica al prossimo caricamento del modello."))
        return items.sorted { $0.size > $1.size }
    }

    // MARK: Ollama

    static func ollamaModelsDirectory() -> String {
        if let env = ProcessInfo.processInfo.environment["OLLAMA_MODELS"], !env.isEmpty { return env }
        // L'app Ollama legge le variabili da launchd, non dalla shell.
        let r = Shell.run("/bin/launchctl", ["getenv", "OLLAMA_MODELS"], timeout: 5)
        let fromLaunchd = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if r.ok, !fromLaunchd.isEmpty { return fromLaunchd }
        return ScanSupport.home + "/.ollama/models"
    }

    struct OllamaModel {
        let name: String
        let manifest: String
        let blobs: [String: Int64]   // digest → dimensione dichiarata
    }

    /// Legge i manifest in `manifests/<registro>/<spazio>/<modello>/<tag>`.
    static func ollamaManifests(in root: String) -> [OllamaModel] {
        let base = root + "/manifests"
        var models: [OllamaModel] = []
        for registry in ScanSupport.children(of: base) {
            for namespace in ScanSupport.children(of: registry) {
                for model in ScanSupport.children(of: namespace) {
                    for tag in ScanSupport.children(of: model) {
                        guard let json = ScanSupport.jsonObject(fromFile: tag) as? [String: Any] else { continue }
                        var blobs: [String: Int64] = [:]
                        let layers = (json["layers"] as? [[String: Any]] ?? [])
                            + [json["config"] as? [String: Any]].compactMap { $0 }
                        for layer in layers {
                            guard let digest = layer["digest"] as? String else { continue }
                            blobs[digest] = (layer["size"] as? NSNumber)?.int64Value ?? 0
                        }
                        models.append(OllamaModel(
                            name: ollamaName(registry: registry, namespace: namespace, model: model, tag: tag),
                            manifest: tag, blobs: blobs))
                    }
                }
            }
        }
        return models
    }

    /// Il nome che `ollama rm` si aspetta: `llama3:8b` per la libreria
    /// ufficiale, `spazio/modello:tag` o `registro/spazio/modello:tag` altrimenti.
    static func ollamaName(registry: String, namespace: String, model: String, tag: String) -> String {
        let r = (registry as NSString).lastPathComponent
        let n = (namespace as NSString).lastPathComponent
        let m = (model as NSString).lastPathComponent
        let t = (tag as NSString).lastPathComponent
        if r == "registry.ollama.ai" {
            return n == "library" ? "\(m):\(t)" : "\(n)/\(m):\(t)"
        }
        return "\(r)/\(n)/\(m):\(t)"
    }

    static func ollamaModels() -> [CleanupItem] {
        let root = ollamaModelsDirectory()
        guard ScanSupport.isDirectory(root) else { return [] }
        let models = ollamaManifests(in: root)
        guard !models.isEmpty else { return [] }

        let ollama = Shell.which("ollama")
        // Senza il programma i modelli sono solo residui: una voce unica.
        guard let ollama else {
            return [ScanSupport.item(
                title: String(localized: "Modelli di Ollama (Ollama non installato)"),
                detail: String(localized: "\(Plural.of(models.count, "modello scaricato", "modelli scaricati")) da Ollama, che non risulta più installato: \(models.map(\.name).joined(separator: ", "))."),
                consequence: String(localized: "Se reinstalli Ollama, i modelli vanno riscaricati."),
                path: root, risk: .redownload)].compactMap { $0 }
        }

        // Un blob può essere condiviso fra più modelli (stesso modello base con
        // tag diversi): lo spazio si libera solo quando nessun modello lo usa.
        var references: [String: Int] = [:]
        for model in models { for digest in model.blobs.keys { references[digest, default: 0] += 1 } }

        // `ollama rm` passa dal server di Ollama: se non è attivo il comando
        // fallisce, quindi lo si dice prima.
        let ps = Shell.run(ollama, ["ps"], timeout: 10)
        let loaded = ps.ok ? ps.stdout : ""

        return models.map { model in
            let exclusive = model.blobs.filter { references[$0.key] == 1 }.values.reduce(0, +)
            let shared = model.blobs.filter { (references[$0.key] ?? 0) > 1 }.values.reduce(0, +)
            var warning: String?
            if !ps.ok {
                warning = String(localized: "Ollama non è in esecuzione: avvialo prima di procedere, il comando ufficiale passa dal suo server.")
            } else if loaded.contains(model.name) {
                warning = String(localized: "Il modello è caricato in memoria in questo momento.")
            }
            return CleanupItem(
                title: "Ollama: \(model.name)",
                detail: String(localized: "Modello scaricato da Ollama.")
                    + (shared > 0 ? String(localized: "\n\nAltri \(ByteFormat.string(shared)) sono condivisi con altri modelli e si liberano solo eliminando anche quelli.") : ""),
                consequence: String(localized: "Va riscaricato con `ollama pull \(model.name)` se ti serve di nuovo. Usa il comando ufficiale `ollama rm`, che tiene coerente l'archivio di Ollama."),
                action: .shell(tool: "ollama", args: ["rm", model.name]),
                risk: .redownload, size: exclusive,
                lastUsed: ScanSupport.modificationDate(model.manifest),
                warning: warning)
        }
    }

    // MARK: Hugging Face

    static func huggingFaceHome() -> String {
        let env = ProcessInfo.processInfo.environment
        if let home = env["HF_HOME"], !home.isEmpty { return home }
        return ScanSupport.home + "/.cache/huggingface"
    }

    static func huggingFaceItems() -> [CleanupItem] {
        let home = huggingFaceHome()
        let env = ProcessInfo.processInfo.environment
        let hub = env["HF_HUB_CACHE"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/hub"
        var items: [CleanupItem] = []

        let repos = ScanSupport.children(of: hub).filter {
            let n = ($0 as NSString).lastPathComponent
            return n.hasPrefix("models--") || n.hasPrefix("datasets--") || n.hasPrefix("spaces--")
        }
        let sizes = Shell.diskSizes(repos)
        for repo in repos {
            let size = sizes[repo] ?? 0
            guard size >= 1_000_000 else { continue }
            let folder = (repo as NSString).lastPathComponent
            let kind = folder.hasPrefix("datasets--") ? String(localized: "Dataset")
                : (folder.hasPrefix("spaces--") ? String(localized: "Space") : String(localized: "Modello"))
            let name = folder.components(separatedBy: "--").dropFirst().joined(separator: "/")
            items.append(CleanupItem(
                title: String(localized: "Hugging Face: \(name)"),
                detail: String(localized: "\(kind) scaricato nella cache di Hugging Face (librerie transformers, diffusers, huggingface_hub)."),
                consequence: String(localized: "Il codice che lo usa lo riscarica al prossimo caricamento."),
                action: .removePaths([repo]), risk: .redownload, size: size,
                perPathSize: [repo: size], lastUsed: ScanSupport.modificationDate(repo)))
        }

        // Il resto della cartella (cache di Xet, token esclusi) in una voce sola.
        let others = ScanSupport.children(of: home, includeHidden: true).filter {
            let n = ($0 as NSString).lastPathComponent
            return $0 != hub && n != "token" && n != "stored_tokens"
        }
        if let item = ScanSupport.item(
            title: String(localized: "Altre cache di Hugging Face"),
            detail: String(localized: "Cache di scaricamento (Xet) e file accessori di Hugging Face. Il token di accesso non viene toccato."),
            consequence: String(localized: "Vengono ricreate al prossimo scaricamento."),
            paths: others, risk: .safe) {
            items.append(item)
        }
        return items
    }

    // MARK: LM Studio

    static func lmStudioItems() -> [CleanupItem] {
        let root = ScanSupport.home + "/.lmstudio"
        guard ScanSupport.isDirectory(root) else { return [] }
        var items: [CleanupItem] = []

        // Modelli: `models/<editore>/<modello>`.
        for publisher in ScanSupport.children(of: root + "/models") {
            let models = ScanSupport.children(of: publisher)
            let sizes = Shell.diskSizes(models)
            for model in models {
                let size = sizes[model] ?? 0
                guard size >= 1_000_000 else { continue }
                let name = (publisher as NSString).lastPathComponent + "/" + (model as NSString).lastPathComponent
                items.append(CleanupItem(
                    title: String(localized: "LM Studio: \(name)"),
                    detail: String(localized: "Modello scaricato da LM Studio."),
                    consequence: String(localized: "Va riscaricato da LM Studio se ti serve di nuovo."),
                    action: .removePaths([model]), risk: .redownload, size: size,
                    perPathSize: [model: size], lastUsed: ScanSupport.modificationDate(model),
                    requiredStoppedApps: [lmStudioBundleID]))
            }
        }

        // Motori di inferenza e componenti: se LM Studio non c'è più sono
        // solo residui. Conversazioni, impostazioni e credenziali restano.
        let installed = OrphanScanner.installedBundleIDs().contains(lmStudioBundleID)
            || ScanSupport.exists("/Applications/LM Studio.app")
        if !installed, let item = ScanSupport.item(
            title: String(localized: "Componenti di LM Studio (app non installata)"),
            detail: String(localized: "Motori di inferenza, estensioni e log lasciati da LM Studio, che non risulta più installato.\n\nConversazioni, impostazioni, progetti e credenziali in ~/.lmstudio non vengono toccati."),
            consequence: String(localized: "Se reinstalli LM Studio, li riscarica al primo avvio."),
            paths: ["extensions", "bin", "server-logs"].map { root + "/" + $0 },
            risk: .redownload) {
            items.append(item)
        }
        return items
    }

    // MARK: Altri

    static func torchHome() -> String {
        if let env = ProcessInfo.processInfo.environment["TORCH_HOME"], !env.isEmpty { return env }
        return ScanSupport.home + "/.cache/torch"
    }

    static func perChildItems(root: String, source: String, detail: String, consequence: String) -> [CleanupItem] {
        let children = ScanSupport.children(of: root)
        let sizes = Shell.diskSizes(children)
        return children.compactMap { child in
            let size = sizes[child] ?? 0
            guard size >= 1_000_000 else { return nil }
            return CleanupItem(
                title: "\(source): \((child as NSString).lastPathComponent)",
                detail: detail, consequence: consequence,
                action: .removePaths([child]), risk: .redownload, size: size,
                perPathSize: [child: size], lastUsed: ScanSupport.modificationDate(child))
        }
    }

    /// Visibile se c'è almeno una delle cartelle dei modelli.
    static func presence() -> ToolPresence {
        let roots = [ollamaModelsDirectory(), huggingFaceHome(), ScanSupport.home + "/.lmstudio",
                     torchHome(), ScanSupport.home + "/.cache/whisper", ScanSupport.home + "/.keras/models"]
        return roots.contains(where: ScanSupport.isDirectory)
            ? .installed
            : .absent(detail: String(localized: "Nessun modello AI locale trovato."))
    }
}
