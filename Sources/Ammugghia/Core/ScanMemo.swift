import Foundation

/// Il risultato di un'analisi costosa, riusato per un minuto. Serve quando lo
/// stesso risultato lo chiedono lo scanner, la visibilità della categoria e la
/// nota: il blocco resta preso durante il calcolo, così due richieste
/// simultanee non lo fanno due volte.
final class ScanMemo<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (date: Date, value: Value)?

    func value(_ compute: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        if let stored, Date().timeIntervalSince(stored.date) < 60 { return stored.value }
        let value = compute()
        stored = (Date(), value)
        return value
    }

    func invalidate() {
        lock.lock()
        stored = nil
        lock.unlock()
    }
}
