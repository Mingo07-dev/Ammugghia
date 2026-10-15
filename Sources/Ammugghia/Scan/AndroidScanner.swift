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
                    title: String(localized: "NDK Android \((v as NSString).lastPathComponent)"),
                    detail: String(localized: "Toolchain per compilare codice nativo C/C++ in un progetto Android. Flutter e React Native, senza plugin nativi, non la usano."),
                    consequence: String(localized: "Se un progetto richiede il NDK, Gradle interrompe la compilazione chiedendo di reinstallarlo dal SDK Manager (qualche GB di download)."),
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
                        title: String(localized: "Immagine di sistema \(apiName) / \(variantName)"),
                        detail: String(localized: "Immagine del sistema Android usata dagli emulatori con \(apiName) (\(variantName))."),
                        consequence: String(localized: "Gli emulatori basati su questa immagine non si avviano più finché non la riscarichi dal SDK Manager."),
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
                    detail: String(localized: "Disco virtuale dell'emulatore Android: app installate, dati delle app e stato del dispositivo."),
                    consequence: String(localized: "L'emulatore va ricreato da Android Studio e le app di test reinstallate. Se ci sono dati di test che ti servono, perderli è irreversibile."),
                    action: .removePaths([avd]), risk: .userData, size: size,
                    perPathSize: [avd: size], lastUsed: ScanSupport.modificationDate(avd)))
            }
        }

        // SDK: componenti secondari e cache.
        let sdkExtras: [(String, String, String, String, RiskLevel)] = [
            (String(localized: "Sorgenti Android"), sdk + "/sources",
             String(localized: "Codice sorgente del framework Android, usato solo per la navigazione nel debugger."),
             String(localized: "Il debugger mostra il bytecode invece del sorgente. Riscaricabile dal SDK Manager."), .redownload),
            (String(localized: "Cache dell'emulatore"), home + "/.android/cache",
             String(localized: "File temporanei dell'emulatore Android."),
             String(localized: "Si rigenera al prossimo avvio dell'emulatore."), .safe),
            (String(localized: "Crash dell'emulatore"), home + "/.android/breakpad",
             String(localized: "Report di crash dell'emulatore Android."),
             String(localized: "Nessuna: sono solo diagnostiche già inviate."), .safe),
            (String(localized: "Cache CMake"), sdk + "/.temp",
             String(localized: "File temporanei del SDK Manager."),
             String(localized: "Nessuna."), .safe),
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
            title: String(localized: "Cache Gradle"),
            detail: String(localized: "Dipendenze scaricate, cache di build e artefatti trasformati di tutti i progetti Android."),
            consequence: String(localized: "La prima compilazione di ogni progetto riscarica le dipendenze da Maven Central: qualche minuto e parecchia banda."),
            path: gradle + "/caches", risk: .redownload) {
            items.append(item)
        }
        if let item = ScanSupport.item(
            title: String(localized: "Daemon Gradle"),
            detail: String(localized: "Log e registri dei processi Gradle in background."),
            consequence: String(localized: "Nessuna: vengono ricreati al prossimo build."),
            path: gradle + "/daemon", risk: .safe) {
            items.append(item)
        }

        if let item = ScanSupport.item(
            title: String(localized: "File temporanei di Gradle"),
            detail: String(localized: "Processi di lavoro, notifiche e file temporanei lasciati da Gradle e dal compilatore Kotlin."),
            consequence: String(localized: "Nessuna: vengono ricreati al prossimo build."),
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
                title: String(localized: "Distribuzioni Gradle (\(versions.count) versioni)"),
                detail: String(localized: "Copie complete di Gradle scaricate dai wrapper dei progetti, una per versione richiesta."),
                consequence: String(localized: "Il wrapper riscarica la distribuzione al primo build del progetto che la richiede (~150 MB per versione)."),
                path: dists, risk: .redownload) {
                items.append(item)
            }
        }

        return items.sorted { $0.size > $1.size }
    }
}
