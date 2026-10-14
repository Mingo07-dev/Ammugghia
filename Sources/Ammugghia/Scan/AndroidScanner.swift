import Foundation

/// SDK Android, emulatori e cache Gradle.
enum AndroidScanner {

    static var sdkPath: String {
        let candidates = [
            ScanSupport.home + "/Library/Android/sdk",
            ScanSupport.home + "/Android/sdk",
        ]
        if let env = ProcessInfo.processInfo.environment["ANDROID_HOME"], ScanSupport.exists(env) {
            return env
        }
        return candidates.first(where: ScanSupport.exists) ?? candidates[0]
    }

    static func scan() -> [CleanupItem] {
        var items: [CleanupItem] = []
        let home = ScanSupport.home
        let sdk = sdkPath

        // NDK: serve solo a chi compila codice nativo C/C++. Ogni versione
        // pesa qualche GB.
        let ndkBase = sdk + "/ndk"
        if ScanSupport.isDirectory(ndkBase) {
            let versions = ScanSupport.children(of: ndkBase)
            let sizes = Shell.diskSizes(versions)
            for v in versions {
                let size = sizes[v] ?? 0
                guard size >= 10_000_000 else { continue }
                items.append(CleanupItem(
                    title: "NDK Android \((v as NSString).lastPathComponent)",
                    detail: "Toolchain per compilare codice nativo C/C++ in un progetto Android. Flutter e React Native, senza plugin nativi, non la usano.",
                    consequence: "Se un progetto richiede il NDK, Gradle interrompe la compilazione chiedendo di reinstallarlo dal SDK Manager (qualche GB di download).",
                    action: .removePaths([v]), risk: .redownload, size: size,
                    perPathSize: [v: size], lastUsed: ScanSupport.modificationDate(v)))
            }
        }

        // Immagini di sistema: una per livello di API e variante.
        let sysImages = sdk + "/system-images"
        if ScanSupport.isDirectory(sysImages) {
            for api in ScanSupport.children(of: sysImages) {
                let variants = ScanSupport.children(of: api)
                let sizes = Shell.diskSizes(variants)
                for variant in variants {
                    let size = sizes[variant] ?? 0
                    guard size >= 10_000_000 else { continue }
                    let apiName = (api as NSString).lastPathComponent
                    let variantName = (variant as NSString).lastPathComponent
                    items.append(CleanupItem(
                        title: "Immagine di sistema \(apiName) / \(variantName)",
                        detail: "Immagine del sistema Android usata dagli emulatori con \(apiName) (\(variantName)).",
                        consequence: "Gli emulatori basati su questa immagine non si avviano più finché non la riscarichi dal SDK Manager.",
                        action: .removePaths([variant]), risk: .redownload, size: size,
                        perPathSize: [variant: size],
                        lastUsed: ScanSupport.modificationDate(variant)))
                }
            }
        }

        // Emulatori: contengono lo stato del dispositivo virtuale.
        let avdBase = home + "/.android/avd"
        if ScanSupport.isDirectory(avdBase) {
            let avds = ScanSupport.children(of: avdBase).filter { $0.hasSuffix(".avd") }
            let sizes = Shell.diskSizes(avds)
            for avd in avds {
                let size = sizes[avd] ?? 0
                guard size >= 10_000_000 else { continue }
                let name = (avd as NSString).lastPathComponent
                    .replacingOccurrences(of: ".avd", with: "")
                items.append(CleanupItem(
                    title: "Emulatore «\(name)»",
                    detail: "Disco virtuale dell'emulatore Android: app installate, dati delle app e stato del dispositivo.",
                    consequence: "L'emulatore va ricreato da Android Studio e le app di test reinstallate. Se ci sono dati di test che ti servono, perderli è irreversibile.",
                    action: .removePaths([avd]), risk: .userData, size: size,
                    perPathSize: [avd: size], lastUsed: ScanSupport.modificationDate(avd)))
            }
        }

        // SDK: componenti secondari e cache.
        let sdkExtras: [(String, String, String, String, RiskLevel)] = [
            ("Sorgenti Android", sdk + "/sources",
             "Codice sorgente del framework Android, usato solo per la navigazione nel debugger.",
             "Il debugger mostra il bytecode invece del sorgente. Riscaricabile dal SDK Manager.", .redownload),
            ("Cache dell'emulatore", home + "/.android/cache",
             "File temporanei dell'emulatore Android.",
             "Si rigenera al prossimo avvio dell'emulatore.", .safe),
            ("Crash dell'emulatore", home + "/.android/breakpad",
             "Report di crash dell'emulatore Android.",
             "Nessuna: sono solo diagnostiche già inviate.", .safe),
            ("Cache CMake", sdk + "/.temp",
             "File temporanei del SDK Manager.",
             "Nessuna.", .safe),
        ]
        for (title, path, detail, consequence, risk) in sdkExtras {
            if let item = ScanSupport.item(title: title, detail: detail,
                                           consequence: consequence, path: path, risk: risk) {
                items.append(item)
            }
        }

        // Gradle.
        let gradle = home + "/.gradle"
        if let item = ScanSupport.item(
            title: "Cache Gradle",
            detail: "Dipendenze scaricate, cache di build e artefatti trasformati di tutti i progetti Android.",
            consequence: "La prima compilazione di ogni progetto riscarica le dipendenze da Maven Central: qualche minuto e parecchia banda.",
            path: gradle + "/caches", risk: .redownload) {
            items.append(item)
        }
        if let item = ScanSupport.item(
            title: "Daemon Gradle",
            detail: "Log e registri dei processi Gradle in background.",
            consequence: "Nessuna: vengono ricreati al prossimo build.",
            path: gradle + "/daemon", risk: .safe) {
            items.append(item)
        }

        if let item = ScanSupport.item(
            title: "File temporanei di Gradle",
            detail: "Processi di lavoro, notifiche e file temporanei lasciati da Gradle e dal compilatore Kotlin.",
            consequence: "Nessuna: vengono ricreati al prossimo build.",
            paths: ["workers", "notifications", ".tmp", "kotlin-profile"].map { gradle + "/" + $0 },
            risk: .safe) {
            items.append(item)
        }

        // Le distribuzioni Gradle sono trattate anche come versioni multiple:
        // qui l'elemento cumulativo, nella scheda Versioni il confronto.
        let dists = gradle + "/wrapper/dists"
        if ScanSupport.isDirectory(dists) {
            let versions = ScanSupport.children(of: dists)
            if versions.count > 1, let item = ScanSupport.item(
                title: "Distribuzioni Gradle (\(versions.count) versioni)",
                detail: "Copie complete di Gradle scaricate dai wrapper dei progetti, una per versione richiesta.",
                consequence: "Il wrapper riscarica la distribuzione al primo build del progetto che la richiede (~150 MB per versione).",
                path: dists, risk: .redownload) {
                items.append(item)
            }
        }

        return items.sorted { $0.size > $1.size }
    }
}
