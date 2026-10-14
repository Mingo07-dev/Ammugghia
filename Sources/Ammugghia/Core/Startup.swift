import Foundation
import AppKit

// MARK: - Modello

/// Un servizio che launchd avvia da solo: all'accesso, all'avvio del Mac o a
/// intervalli.
struct StartupItem: Identifiable, Hashable {
    enum Domain: Hashable {
        /// `~/Library/LaunchAgents`: solo per questo utente.
        case userAgent
        /// `/Library/LaunchAgents`: per tutti gli utenti, gira nella sessione.
        case globalAgent
        /// `/Library/LaunchDaemons`: gira come root, senza sessione.
        case daemon

        var label: String {
            switch self {
            case .userAgent: return "Agente dell'utente"
            case .globalAgent: return "Agente per tutti gli utenti"
            case .daemon: return "Servizio di sistema"
            }
        }

        /// Il dominio di launchd in cui il servizio vive.
        var target: String {
            switch self {
            case .userAgent, .globalAgent: return "gui/\(getuid())"
            case .daemon: return "system"
            }
        }

        var needsAdmin: Bool { self == .daemon }
    }

    let plistPath: String
    let label: String
    let domain: Domain
    let program: String?
    let programExists: Bool
    let ownerName: String?
    let signer: String?
    let runAtLoad: Bool
    let keepAlive: Bool
    let interval: Int?
    let isDisabled: Bool
    let isLoaded: Bool

    var id: String { plistPath }
    var isApple: Bool { label.hasPrefix("com.apple.") }
    /// Il programma da avviare non esiste più: resto di un'app rimossa.
    var isOrphan: Bool { program != nil && !programExists }
    var displayName: String { ownerName ?? label }
}

// MARK: - Lettura

enum StartupScanner {

    struct Roots {
        let userAgents: String
        let globalAgents: String
        let daemons: String

        static let standard = Roots(
            userAgents: ScanSupport.home + "/Library/LaunchAgents",
            globalAgents: "/Library/LaunchAgents",
            daemons: "/Library/LaunchDaemons")

        func directory(for domain: StartupItem.Domain) -> String {
            switch domain {
            case .userAgent: return userAgents
            case .globalAgent: return globalAgents
            case .daemon: return daemons
            }
        }
    }

    static func scan(roots: Roots = .standard) -> [StartupItem] {
        let userOverrides = disabledOverrides(domain: "gui/\(getuid())")
        let systemOverrides = disabledOverrides(domain: "system")
        var items: [StartupItem] = []
        var signatures: [String: String?] = [:]

        for domain in [StartupItem.Domain.userAgent, .globalAgent, .daemon] {
            for path in ScanSupport.children(of: roots.directory(for: domain)) where path.hasSuffix(".plist") {
                guard let plist = ScanSupport.plistAsJSON(path) as? [String: Any],
                      let label = plist["Label"] as? String else { continue }
                let program = (plist["Program"] as? String)
                    ?? (plist["ProgramArguments"] as? [String])?.first
                let exists = program.map { FileManager.default.fileExists(atPath: $0) } ?? false
                let overrides = domain == .daemon ? systemOverrides : userOverrides
                // Senza un'impostazione esplicita vale la chiave `Disabled` del plist.
                let disabled = overrides[label] ?? (plist["Disabled"] as? Bool ?? false)
                let keepAlive: Bool = {
                    if let flag = plist["KeepAlive"] as? Bool { return flag }
                    return plist["KeepAlive"] is [String: Any]
                }()
                var signer: String?
                if let program, exists {
                    if let cached = signatures[program] { signer = cached } else {
                        signer = codeSigner(program)
                        signatures[program] = signer
                    }
                }
                items.append(StartupItem(
                    plistPath: path, label: label, domain: domain, program: program,
                    programExists: exists,
                    ownerName: owner(of: plist, program: program),
                    signer: signer,
                    runAtLoad: plist["RunAtLoad"] as? Bool ?? false,
                    keepAlive: keepAlive,
                    interval: plist["StartInterval"] as? Int,
                    isDisabled: disabled,
                    isLoaded: isLoaded(label: label, domain: domain)))
            }
        }
        return items.sorted {
            ($0.domain.sortKey, $0.displayName.lowercased()) < ($1.domain.sortKey, $1.displayName.lowercased())
        }
    }

    /// Servizi di macOS, solo da contare: non si modificano.
    static func appleServiceCount() -> Int {
        ["/System/Library/LaunchAgents", "/System/Library/LaunchDaemons"]
            .map { ScanSupport.children(of: $0).filter { $0.hasSuffix(".plist") }.count }
            .reduce(0, +)
    }

    /// Le impostazioni esplicite di attivazione, da `launchctl print-disabled`.
    static func disabledOverrides(domain: String) -> [String: Bool] {
        let r = Shell.run("/bin/launchctl", ["print-disabled", domain], timeout: 10)
        return parseOverrides(r.stdout)
    }

    /// Righe come `"com.tizio.agent" => disabled`. Separato per l'autotest.
    static func parseOverrides(_ output: String) -> [String: Bool] {
        var result: [String: Bool] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.components(separatedBy: "=>")
            guard parts.count == 2 else { continue }
            let label = parts[0].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let state = parts[1].trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty else { continue }
            if state.hasPrefix("disabled") || state == "true" { result[label] = true }
            if state.hasPrefix("enabled") || state == "false" { result[label] = false }
        }
        return result
    }

    static func isLoaded(label: String, domain: StartupItem.Domain) -> Bool {
        Shell.run("/bin/launchctl", ["print", "\(domain.target)/\(label)"], timeout: 10).ok
    }

    /// L'app a cui appartiene: dichiarata nel plist, oppure quella che
    /// contiene il programma.
    static func owner(of plist: [String: Any], program: String?) -> String? {
        let declared = (plist["AssociatedBundleIdentifiers"] as? [String])
            ?? (plist["AssociatedBundleIdentifiers"] as? String).map { [$0] }
        if let ids = declared {
            for id in ids {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                    return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
                }
            }
        }
        if let program, let range = program.range(of: ".app/") {
            let app = String(program[..<range.lowerBound]) + ".app"
            return ((app as NSString).lastPathComponent as NSString).deletingPathExtension
        }
        return nil
    }

    /// Chi ha firmato il programma, da `codesign`.
    static func codeSigner(_ program: String) -> String? {
        let r = Shell.run("/usr/bin/codesign", ["-dv", "--verbose=2", program], timeout: 15)
        let text = r.stderr + r.stdout
        for line in text.split(separator: "\n") where line.hasPrefix("Authority=") {
            return String(line.dropFirst("Authority=".count))
        }
        return text.contains("not signed") ? "non firmato" : nil
    }
}

private extension StartupItem.Domain {
    var sortKey: Int {
        switch self {
        case .userAgent: return 0
        case .globalAgent: return 1
        case .daemon: return 2
        }
    }
}

// MARK: - Guardiano

/// Il cancello per le modifiche agli elementi d'avvio. Non elimina niente,
/// quindi non è `PathGuard`, ma segue lo stesso principio: nel dubbio rifiuta.
enum StartupGuard {

    enum Violation: LocalizedError {
        case apple(String)
        case invalidLabel(String)
        case wrongLocation(String)
        case unreadable(String)
        case labelMismatch(String, String)
        case symlink(String)

        var errorDescription: String? {
            switch self {
            case .apple(let l): return "Servizio di macOS, non modificabile: \(l)"
            case .invalidLabel(let l): return "Etichetta del servizio non valida, rifiutata: \(l)"
            case .wrongLocation(let p): return "Il file del servizio non è in una cartella di avvio consentita: \(p)"
            case .unreadable(let p): return "Il file del servizio non è leggibile: \(p)"
            case .labelMismatch(let a, let b): return "Il file dichiara un servizio diverso (\(b)) da quello richiesto (\(a))"
            case .symlink(let p): return "Il file del servizio è un collegamento, rifiutato: \(p)"
            }
        }
    }

    /// Solo lettere, cifre, punto, trattino e trattino basso: l'etichetta
    /// finisce dentro un comando (anche con privilegi) e non deve poter
    /// contenere nient'altro.
    static func isValidLabel(_ label: String) -> Bool {
        !label.isEmpty && label.count <= 200 && label.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_")
        }
    }

    static func validate(_ item: StartupItem, roots: StartupScanner.Roots = .standard) throws {
        guard isValidLabel(item.label) else { throw Violation.invalidLabel(item.label) }
        guard !item.isApple else { throw Violation.apple(item.label) }
        // Il file deve stare direttamente nella cartella che corrisponde al
        // suo dominio: un agente utente non può diventare un servizio di
        // sistema cambiando cartella.
        let parent = (item.plistPath as NSString).deletingLastPathComponent
        guard parent == roots.directory(for: item.domain) else {
            throw Violation.wrongLocation(item.plistPath)
        }
        guard let identity = FileIdentity.of(item.plistPath) else { throw Violation.unreadable(item.plistPath) }
        guard !identity.isSymlink else { throw Violation.symlink(item.plistPath) }
        guard let plist = ScanSupport.plistAsJSON(item.plistPath) as? [String: Any],
              let declared = plist["Label"] as? String else { throw Violation.unreadable(item.plistPath) }
        guard declared == item.label else { throw Violation.labelMismatch(item.label, declared) }
    }
}

// MARK: - Modifiche

enum StartupController {

    struct Outcome {
        let succeeded: Bool
        let message: String
        let commands: [String]
    }

    /// Comandi per passare allo stato richiesto. Disattivare ferma anche il
    /// processo se è in esecuzione; riattivare lo ricarica.
    static func commands(for item: StartupItem, enable: Bool) -> [[String]] {
        let service = "\(item.domain.target)/\(item.label)"
        return enable
            ? [["enable", service], ["bootstrap", item.domain.target, item.plistPath]]
            : [["disable", service], ["bootout", service]]
    }

    static func setEnabled(_ item: StartupItem, _ enable: Bool) -> Outcome {
        do { try StartupGuard.validate(item) } catch {
            return Outcome(succeeded: false, message: error.localizedDescription, commands: [])
        }
        let steps = commands(for: item, enable: enable)
        let printable = steps.map { (["launchctl"] + $0).joined(separator: " ") }

        if item.domain.needsAdmin {
            // Un solo comando con la password. `bootout`/`bootstrap` possono
            // fallire se il servizio è già nello stato giusto: conta la verifica.
            let script = steps.map { (["/bin/launchctl"] + $0.map(Shell.shellQuote)).joined(separator: " ") }
            let command = script[0] + "; " + script[1] + " || true"
            let r = Shell.runAsAdmin(command)
            if !r.ok && r.stderr.contains("-128") {
                return Outcome(succeeded: false, message: "Annullato: password non inserita.", commands: printable)
            }
        } else {
            _ = Shell.run("/bin/launchctl", steps[0], timeout: 20)
            _ = Shell.run("/bin/launchctl", steps[1], timeout: 20)
        }

        // Si rilegge lo stato da launchd: è l'unica prova che la modifica è avvenuta.
        let overrides = StartupScanner.disabledOverrides(domain: item.domain.target)
        let disabledNow = overrides[item.label] ?? false
        let ok = disabledNow == !enable
        return Outcome(
            succeeded: ok,
            message: ok
                ? (enable ? "Riattivato: \(item.label)" : "Disattivato: \(item.label)")
                : "launchd non risulta aggiornato per \(item.label): stato invariato.",
            commands: printable)
    }
}
