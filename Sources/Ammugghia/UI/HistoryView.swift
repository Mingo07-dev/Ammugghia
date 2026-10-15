import SwiftUI
import Charts

/// Che cosa è stato fatto, quando e quanto spazio ha liberato. Quello che è
/// finito nel Cestino si può rimettere al suo posto da qui.
struct HistoryView: View {
    @EnvironmentObject var model: AppModel
    /// Stringa vuota = tutte le provenienze: il filtro non deve dipendere da
    /// una parola che cambia con la lingua.
    @State private var origin: String = ""

    private var origins: [String] { [""] + Array(Set(model.history.map(\.origin))).sorted() }

    private var filtered: [HistoryEntry] {
        origin.isEmpty ? model.history : model.history.filter { $0.origin == origin }
    }

    /// Spazio liberato per mese, per il grafico.
    private var monthly: [(month: Date, freed: Int64)] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: filtered.filter(\.succeeded)) {
            calendar.date(from: calendar.dateComponents([.year, .month], from: $0.date)) ?? $0.date
        }
        return grouped.map { ($0.key, $0.value.reduce(0) { $0 + $1.freed }) }.sorted { $0.month < $1.month }
    }

    private var byDay: [(day: Date, entries: [HistoryEntry])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: filtered) { calendar.startOfDay(for: $0.date) }
        return grouped.map { ($0.key, $0.value.sorted { $0.date > $1.date }) }.sorted { $0.day > $1.day }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Cronologia").font(.title2.bold())
                    Spacer()
                    Picker("Provenienza", selection: $origin) {
                        ForEach(origins, id: \.self) { value in
                            Text(value.isEmpty ? String(localized: "Tutte") : value).tag(value)
                        }
                    }
                    .fixedSize()
                    Button("Mostra il registro") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: ScanSupport.home + "/Library/Logs/Ammugghia"))
                    }
                }
                Text("Ogni operazione eseguita, con lo spazio liberato. Gli elementi spostati nel Cestino da Ammugghia si possono rimettere al loro posto finché il Cestino non viene svuotato.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let message = model.historyMessage {
                    Text(message).font(.caption.bold()).foregroundStyle(.tint)
                }
                if monthly.count > 0 {
                    Chart(monthly, id: \.month) { point in
                        BarMark(x: .value("Mese", point.month, unit: .month),
                                y: .value("Liberato", Double(point.freed) / 1_000_000_000))
                            .foregroundStyle(.tint)
                    }
                    .chartYAxisLabel("GB liberati")
                    .frame(height: 110)
                }
            }
            .padding(16)
            Divider()
            if filtered.isEmpty {
                ContentUnavailableView("Nessuna operazione registrata", systemImage: "clock",
                                       description: Text("Le pulizie eseguite (non le simulazioni) compariranno qui."))
            } else {
                List {
                    ForEach(byDay, id: \.day) { day, entries in
                        Section(day.formatted(date: .complete, time: .omitted)) {
                            ForEach(entries) { entry in HistoryRow(entry: entry) }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .task { model.loadHistory() }
    }
}

struct HistoryRow: View {
    let entry: HistoryEntry
    @EnvironmentObject var model: AppModel
    @State private var expanded = false
    @State private var confirmRestore = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(entry.mode).font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)
                ForEach(entry.paths.prefix(30), id: \.self) { path in
                    HStack(spacing: 6) {
                        Text(path)
                            .font(.system(.caption2, design: .monospaced))
                            .lineLimit(1).truncationMode(.middle)
                            .textSelection(.enabled)
                        if entry.restored.contains(path) {
                            Text("ripristinato").font(.caption2).foregroundStyle(.green)
                        } else if entry.trashed[path] != nil {
                            Text("nel Cestino").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                if entry.paths.count > 30 {
                    Text("… e altri \(entry.paths.count - 30)").font(.caption2).foregroundStyle(.tertiary)
                }
                if !entry.restorable.isEmpty {
                    Button("Ripristina dal Cestino…") { confirmRestore = true }
                        .controlSize(.small)
                        .padding(.top, 3)
                }
            }
            .padding(.vertical, 3)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(color)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title).font(.callout).lineLimit(1)
                    Text("\(entry.origin) · \(entry.date.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if entry.freed > 0 {
                    Text(ByteFormat.string(entry.freed)).font(.callout.monospacedDigit())
                }
            }
        }
        .confirmationDialog("Ripristinare \(Plural.of(entry.restorable.count, "elemento", "elementi"))?",
                            isPresented: $confirmRestore, titleVisibility: .visible) {
            Button("Ripristina") { model.restore(entry, paths: entry.restorable) }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text("Vengono spostati dal Cestino al loro posto originale. Se lì c'è già qualcosa, o la cartella non esiste più, quell'elemento resta nel Cestino.")
        }
    }

    private var icon: String {
        if entry.kind == .startup { return "power.circle" }
        if entry.skipped { return "minus.circle" }
        return entry.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill"
    }

    private var color: Color {
        if entry.skipped { return .secondary }
        return entry.succeeded ? .green : .red
    }
}
