import Foundation
import CoreServices

/// Che cosa è cambiato sul disco dall'ultima analisi, secondo FSEvents.
///
/// macOS registra in un database ogni cartella il cui contenuto cambia, con un
/// numero di evento crescente. Rileggendo la storia a partire dall'ultimo
/// numero visto si sa quali cartelle rianalizzare, senza ripercorrere tutto.
///
/// Ogni segnale di storia incompleta — eventi persi dal kernel o dal demone,
/// numeri ricominciati, radice spostata, volumi montati o smontati, risposta
/// che non arriva — produce `.mustRescan`: l'unica risposta sicura è
/// un'analisi completa.
enum ChangeTracker {

    enum Outcome {
        case changes(directories: Set<String>, recursive: Set<String>)
        case mustRescan(reason: String)
    }

    static func currentEventID() -> UInt64 {
        FSEventsGetCurrentEventId()
    }

    /// Identificatore del database degli eventi del volume. Cambia se il
    /// database viene azzerato: la storia precedente non è più affidabile.
    static func databaseUUID(device: UInt64) -> String? {
        guard let uuid = FSEventsCopyUUIDForDevice(dev_t(truncatingIfNeeded: device)) else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    private final class Collector {
        var directories = Set<String>()
        var recursive = Set<String>()
        var failure: String?
        var finished = false
        let done = DispatchSemaphore(value: 0)
        let lock = NSLock()
    }

    private static let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
        guard let info else { return }
        let collector = Unmanaged<Collector>.fromOpaque(info).takeUnretainedValue()
        let list = unsafeBitCast(paths, to: NSArray.self)
        collector.lock.lock()
        defer { collector.lock.unlock() }
        for i in 0..<count {
            let flag = Int(flags[i])
            let path = (list[i] as? String) ?? ""
            if flag & kFSEventStreamEventFlagHistoryDone != 0 {
                if !collector.finished {
                    collector.finished = true
                    collector.done.signal()
                }
                continue
            }
            let fatal: [(Int, String)] = [
                (kFSEventStreamEventFlagKernelDropped, String(localized: "eventi persi dal kernel")),
                (kFSEventStreamEventFlagUserDropped, String(localized: "eventi persi dal demone")),
                (kFSEventStreamEventFlagEventIdsWrapped, String(localized: "numerazione degli eventi ricominciata")),
                (kFSEventStreamEventFlagRootChanged, String(localized: "una cartella analizzata è stata spostata")),
                (kFSEventStreamEventFlagMount, String(localized: "un volume è stato montato")),
                (kFSEventStreamEventFlagUnmount, String(localized: "un volume è stato smontato")),
            ]
            if let hit = fatal.first(where: { flag & $0.0 != 0 }) {
                collector.failure = collector.failure ?? hit.1
                continue
            }
            let normalized = normalize(path)
            if flag & kFSEventStreamEventFlagMustScanSubDirs != 0 {
                collector.recursive.insert(normalized)
            } else {
                collector.directories.insert(normalized)
            }
        }
    }

    /// I percorsi del volume dati possono arrivare con il prefisso del
    /// firmlink: `/System/Volumes/Data/Users/…` è `/Users/…`.
    static func normalize(_ path: String) -> String {
        var p = path
        let firmlink = "/System/Volumes/Data"
        if p.hasPrefix(firmlink + "/") { p = String(p.dropFirst(firmlink.count)) }
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    static func changes(since eventID: UInt64, in roots: [String], timeout: TimeInterval = 30) -> Outcome {
        let collector = Collector()
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(collector).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes
                                             | kFSEventStreamCreateFlagNoDefer
                                             | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(nil, callback, &context, roots as CFArray,
                                               FSEventStreamEventId(eventID), 0, flags) else {
            return .mustRescan(reason: String(localized: "impossibile leggere la storia delle modifiche"))
        }
        let queue = DispatchQueue(label: "it.ammugghia.fsevents")
        FSEventStreamSetDispatchQueue(stream, queue)
        defer {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        guard FSEventStreamStart(stream) else {
            return .mustRescan(reason: String(localized: "impossibile leggere la storia delle modifiche"))
        }
        let answered = collector.done.wait(timeout: .now() + timeout) == .success
        FSEventStreamFlushSync(stream)
        // Le ultime callback girano sulla coda: attenderla prima di leggere.
        queue.sync {}

        collector.lock.lock()
        defer { collector.lock.unlock() }
        if !answered { return .mustRescan(reason: String(localized: "la storia delle modifiche non ha risposto in tempo")) }
        if let failure = collector.failure { return .mustRescan(reason: failure) }
        return .changes(directories: collector.directories, recursive: collector.recursive)
    }
}
