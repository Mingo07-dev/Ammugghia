import Foundation

/// Esecuzione di processi esterni. Sempre con argomenti separati (mai una
/// stringa passata a una shell) così che nomi di file con spazi, apici o
/// caratteri speciali non possano essere reinterpretati come comandi.
enum Shell {

    struct Result {
        let status: Int32
        let stdout: String
        let stderr: String
        var ok: Bool { status == 0 }
    }

    @discardableResult
    static func run(_ launchPath: String,
                    _ arguments: [String],
                    timeout: TimeInterval = 120) -> Result {
        guard FileManager.default.isExecutableFile(atPath: launchPath) else {
            return Result(status: 127, stdout: "", stderr: "eseguibile non trovato: \(launchPath)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        // Le pipe vanno svuotate mentre il processo gira: se il buffer del
        // kernel si riempie il figlio resta bloccato in scrittura e non
        // termina mai (deadlock classico con output voluminoso come `du`).
        var outData = Data()
        var errData = Data()
        let lock = NSLock()

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            lock.lock(); outData.append(chunk); lock.unlock()
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            lock.lock(); errData.append(chunk); lock.unlock()
        }

        do {
            try process.run()
        } catch {
            return Result(status: 126, stdout: "", stderr: "avvio non riuscito: \(error.localizedDescription)")
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            usleep(20_000)
        }
        if process.isRunning {
            process.terminate()
            usleep(200_000)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            return Result(status: 124, stdout: "", stderr: "timeout dopo \(Int(timeout))s")
        }

        // Recupera quel che resta nelle pipe dopo l'uscita del processo.
        let tailOut = outPipe.fileHandleForReading.availableData
        let tailErr = errPipe.fileHandleForReading.availableData
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil

        lock.lock()
        outData.append(tailOut)
        errData.append(tailErr)
        let out = String(data: outData, encoding: .utf8) ?? ""
        let err = String(data: errData, encoding: .utf8) ?? ""
        lock.unlock()

        return Result(status: process.terminationStatus, stdout: out, stderr: err)
    }

    /// Percorso di un eseguibile, cercato nelle posizioni usuali più il PATH.
    static func which(_ tool: String) -> String? {
        let candidates = [
            "/usr/bin/\(tool)", "/bin/\(tool)", "/usr/sbin/\(tool)",
            "/opt/homebrew/bin/\(tool)", "/usr/local/bin/\(tool)"
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        let r = run("/usr/bin/which", [tool], timeout: 10)
        let line = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if r.ok, !line.isEmpty, FileManager.default.isExecutableFile(atPath: line) {
            return line
        }
        return nil
    }

    /// Dimensione su disco in byte. Usa `du -sk`: enumerare a mano con
    /// FileManager su alberi da decine di migliaia di file è ordini di
    /// grandezza più lento.
    static func diskSize(_ path: String) -> Int64 {
        guard FileManager.default.fileExists(atPath: path) else { return 0 }
        let r = run("/usr/bin/du", ["-sk", path], timeout: 180)
        // `du` può stampare warning su stderr ed emettere comunque il totale.
        guard let first = r.stdout.split(separator: "\n").first,
              let kb = Int64(first.split(whereSeparator: { $0 == "\t" || $0 == " " }).first ?? "") else {
            return 0
        }
        return kb * 1024
    }

    /// Dimensioni di più percorsi in un colpo solo, molto più rapido che
    /// invocare `du` una volta per elemento.
    static func diskSizes(_ paths: [String]) -> [String: Int64] {
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return [:] }
        var result: [String: Int64] = [:]
        // A blocchi, per non superare i limiti di lunghezza degli argomenti.
        for chunk in existing.chunked(into: 60) {
            let r = run("/usr/bin/du", ["-sk"] + chunk, timeout: 240)
            for line in r.stdout.split(separator: "\n") {
                let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2, let kb = Int64(parts[0].trimmingCharacters(in: .whitespaces)) else { continue }
                result[String(parts[1])] = kb * 1024
            }
        }
        // Percorsi non riportati da `du` (permessi negati) valgono 0, non crash.
        for p in existing where result[p] == nil { result[p] = 0 }
        return result
    }

    /// Data d'ultimo utilizzo secondo Spotlight. È l'informazione che distingue
    /// "installato e usato ieri" da "installato e mai più aperto".
    static func lastUsedDate(_ path: String) -> Date? {
        let r = run("/usr/bin/mdls", ["-name", "kMDItemLastUsedDate", "-raw", path], timeout: 15)
        let raw = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard r.ok, raw != "(null)", !raw.isEmpty else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: raw)
    }

    /// Quoting per shell POSIX: usato solo per costruire i comandi
    /// amministrativi, che vengono comunque mostrati all'utente prima
    /// dell'esecuzione.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Esegue un comando con privilegi di amministratore tramite il prompt
    /// nativo di macOS. Il comando è già stato mostrato integralmente
    /// all'utente nel foglio di conferma.
    static func runAsAdmin(_ shellCommand: String) -> Result {
        let escaped = shellCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        return run("/usr/bin/osascript", ["-e", script], timeout: 300)
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
