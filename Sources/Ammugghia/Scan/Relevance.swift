import Foundation

/// Stato di un programma rispetto a una categoria di pulizia.
enum ToolPresence: Equatable {
    /// Il programma è installato: la categoria è utile come sempre.
    case installed
    /// Il programma **non** è installato ma ha lasciato file sul disco. È il
    /// caso più interessante: sono residui di una disinstallazione incompleta,
    /// quindi eliminabili senza conseguenze.
    case residual(detail: String)
    /// Nessuna traccia: la categoria non serve e viene nascosta.
    case absent(detail: String)

    var isRelevant: Bool {
        switch self {
        case .installed, .residual: return true
        case .absent: return false
        }
    }

    var badge: String? {
        switch self {
        case .installed: return nil
        case .residual: return "residui"
        case .absent: return "non installato"
        }
    }
}

/// Stabilisce, per ogni categoria, se il programma di riferimento è presente.
///
/// La distinzione fra «assente» e «residui rimasti» è ciò che permette di
/// nascondere le schede inutili senza però perdere lo spazio occupato da
/// programmi rimossi solo a metà: disinstallando un'app dal Finder restano
/// cache e container, che possono valere diversi GB.
enum Relevance {

    static func detect(_ id: CategoryID) -> ToolPresence {
        switch id {
        case .xcode:            return xcode()
        case .simulators:       return simulators()
        case .android:          return android()
        case .docker:           return docker()
        case .wallpapers:       return wallpapers()
        case .packageManagers:  return packageManagers()
        case .projectArtifacts: return projectArtifacts()
        case .browsers, .appCaches, .system, .largeFiles:
            // Sempre pertinenti: sono aree del sistema, non programmi.
            return .installed
        }
    }

    // MARK: Singole categorie

    static func xcode() -> ToolPresence {
        let installed = ScanSupport.exists("/Applications/Xcode.app")
            || !xcodeApps().isEmpty
            || ScanSupport.exists("/Library/Developer/CommandLineTools")
        if installed { return .installed }

        let leftovers = [
            ScanSupport.home + "/Library/Developer/Xcode",
            ScanSupport.home + "/Library/Caches/com.apple.dt.Xcode",
            ScanSupport.home + "/Library/Developer/CoreSimulator",
        ].filter(ScanSupport.exists)
        if !leftovers.isEmpty {
            return .residual(detail: "Xcode non risulta installato, ma sono rimaste \(Plural.of(leftovers.count, "cartella", "cartelle")) di supporto: sono residui eliminabili.")
        }
        return .absent(detail: "Xcode non è installato e non ha lasciato file.")
    }

    static func simulators() -> ToolPresence {
        let hasXcode = ScanSupport.exists("/Applications/Xcode.app") || !xcodeApps().isEmpty
        let deviceDir = ScanSupport.home + "/Library/Developer/CoreSimulator/Devices"
        let hasDevices = ScanSupport.isDirectory(deviceDir)
            && !ScanSupport.children(of: deviceDir).filter(ScanSupport.isDirectory).isEmpty

        if hasXcode && hasDevices { return .installed }
        if hasXcode { return .installed }   // Xcode c'è: la scheda serve comunque
        if hasDevices || ScanSupport.exists("/Library/Developer/CoreSimulator") {
            return .residual(detail: "Xcode non risulta installato, ma i simulatori e le loro cache sono ancora sul disco. Senza Xcode non sono avviabili: si possono rimuovere.")
        }
        return .absent(detail: "Nessun simulatore iOS installato.")
    }

    static func android() -> ToolPresence {
        let sdk = AndroidScanner.sdkPath
        let studio = ScanSupport.exists("/Applications/Android Studio.app")
            || ScanSupport.exists(ScanSupport.home + "/Applications/Android Studio.app")
        if studio || ScanSupport.isDirectory(sdk) { return .installed }

        let leftovers = [
            ScanSupport.home + "/.android",
            ScanSupport.home + "/.gradle",
            ScanSupport.home + "/Library/Android",
            ScanSupport.home + "/Library/Application Support/Google/AndroidStudio",
        ].filter(ScanSupport.exists)
        if !leftovers.isEmpty {
            return .residual(detail: "Android Studio e l'SDK non risultano installati, ma restano \(Plural.of(leftovers.count, "cartella", "cartelle")) fra emulatori, cache Gradle e configurazione: residui eliminabili.")
        }
        return .absent(detail: "Nessun ambiente di sviluppo Android installato.")
    }

    static func docker() -> ToolPresence {
        let installed = Shell.which("docker") != nil
            || ScanSupport.exists("/Applications/Docker.app")
        if installed { return .installed }

        let leftovers = dockerLeftoverPaths()
        if !leftovers.isEmpty {
            let size = Shell.diskSizes(leftovers).values.reduce(0, +)
            return .residual(detail: "Docker non risulta installato, ma restano \(ByteFormat.string(size)) fra disco virtuale e dati: residui di una disinstallazione incompleta.")
        }
        return .absent(detail: "Docker non è installato.")
    }

    static func wallpapers() -> ToolPresence {
        let videos = ScanSupport.home
            + "/Library/Application Support/com.apple.wallpaper/aerials/videos"
        if ScanSupport.isDirectory(videos),
           !ScanSupport.children(of: videos).filter({ $0.hasSuffix(".mov") }).isEmpty {
            return .installed
        }
        return .absent(detail: "Nessuno sfondo dinamico scaricato.")
    }

    static func packageManagers() -> ToolPresence {
        let markers = [
            ScanSupport.home + "/.npm", ScanSupport.home + "/.pub-cache",
            ScanSupport.home + "/Library/Caches/pip", ScanSupport.home + "/.m2",
            ScanSupport.home + "/.cargo", ScanSupport.home + "/.gem",
            ScanSupport.home + "/Library/Caches/Homebrew",
        ]
        if markers.contains(where: ScanSupport.exists) { return .installed }
        return .absent(detail: "Nessun gestore di pacchetti con cache locale rilevato.")
    }

    static func projectArtifacts() -> ToolPresence {
        if !ProjectArtifactScanner.searchRoots.isEmpty { return .installed }
        return .absent(detail: "Nessuna cartella di progetti nelle posizioni consuete.")
    }

    // MARK: Utilità

    static func xcodeApps() -> [String] {
        var found: [String] = []
        for dir in ["/Applications", ScanSupport.home + "/Applications"] {
            found += ScanSupport.children(of: dir).filter {
                let n = ($0 as NSString).lastPathComponent
                return n.hasPrefix("Xcode") && n.hasSuffix(".app")
            }
        }
        return found
    }

    /// File che Docker lascia dietro di sé. Il disco virtuale è il pezzo
    /// grosso: può valere diversi GB anche dopo aver trascinato l'app nel
    /// Cestino.
    static func dockerLeftoverPaths() -> [String] {
        let home = ScanSupport.home
        return [
            home + "/Library/Containers/com.docker.docker",
            home + "/Library/Group Containers/group.com.docker",
            home + "/Library/Application Support/Docker Desktop",
            home + "/.docker/desktop",
            home + "/Library/Caches/com.docker.docker",
            home + "/Library/Logs/Docker Desktop",
        ].filter(ScanSupport.exists)
    }
}
