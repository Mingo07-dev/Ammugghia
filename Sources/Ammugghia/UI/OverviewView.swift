import SwiftUI

struct OverviewView: View {
    @EnvironmentObject var model: AppModel

    private var byRisk: [RiskLevel: Int64] {
        var totals: [RiskLevel: Int64] = [:]
        for item in model.categories.flatMap(\.deduplicatedItems)
        where !item.action.isInformationalOnly {
            totals[item.risk, default: 0] += item.size
        }
        return totals
    }

    private var versionSavings: Int64 {
        model.versionGroups.reduce(0) { total, group in
            total + group.entries.filter { !$0.recommendedToKeep }.reduce(0) { $0 + $1.size }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {

                DiskGauge(disk: model.disk)

                if model.isScanning {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(model.scanProgress).foregroundStyle(.secondary)
                    }
                }

                if model.didScan {
                    // Recuperabile, diviso per costo dell'errore.
                    VStack(alignment: .leading, spacing: 10) {
                        SectionTitle("Spazio recuperabile", subtitle: String(localized: "Diviso per quanto costa sbagliare"))
                        HStack(spacing: 12) {
                            ForEach(RiskLevel.allCases) { risk in
                                RiskCard(risk: risk, size: byRisk[risk] ?? 0)
                            }
                        }
                        if versionSavings > 0 {
                            HStack(spacing: 8) {
                                Image(systemName: "square.stack.3d.down.right.fill")
                                    .foregroundStyle(.tint)
                                Text("Altri **\(ByteFormat.string(versionSavings))** in versioni duplicate di software già installato.")
                                Button("Vedi") { model.selection = .versions }
                                    .buttonStyle(.link)
                            }
                            .font(.callout)
                            .padding(.top, 4)
                        }
                    }

                    if !model.notes.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionTitle("Cosa vale la pena sapere",
                                         subtitle: String(localized: "Osservazioni ricavate dalla configurazione del tuo Mac"))
                            ForEach(Array(model.notes.enumerated()), id: \.offset) { _, note in
                                HStack(alignment: .top, spacing: 9) {
                                    Image(systemName: "lightbulb.fill")
                                        .foregroundStyle(.yellow)
                                        .font(.caption)
                                        .padding(.top, 3)
                                    Text(note).font(.callout).fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(11)
                                .background(Color(nsColor: .controlBackgroundColor),
                                            in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        SectionTitle("Per categoria", subtitle: String(localized: "Seleziona una categoria nella barra laterale per i dettagli"))
                        ForEach(model.categories) { category in
                            CategorySummaryRow(category: category)
                        }
                    }

                    HStack {
                        Button("Seleziona tutte le cache sicure") { model.selectAllSafe() }
                        Button("Deseleziona tutto") { model.deselectAll() }
                        Spacer()
                    }
                    .padding(.top, 4)
                }

                SafetyNotice()
            }
            .padding(24)
        }
    }
}

struct DiskGauge: View {
    let disk: DiskInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .lastTextBaseline) {
                Text("Disco di avvio").font(.title2.bold())
                Spacer()
                Text("\(ByteFormat.string(disk.free)) liberi su \(ByteFormat.string(disk.total))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .quaternaryLabelColor))
                    RoundedRectangle(cornerRadius: 6)
                        .fill(gaugeColor)
                        .frame(width: max(4, geo.size.width * disk.usedFraction))
                }
            }
            .frame(height: 14)
            HStack {
                Text("\(Int(disk.usedFraction * 100))% occupato")
                if disk.purgeable > 0 {
                    Text("· \(ByteFormat.string(disk.purgeable)) liberabili da macOS (snapshot e cache di sistema)")
                        .help("macOS libera automaticamente questo spazio quando serve. Non è incluso nello spazio libero indicato sopra.")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 10))
    }

    private var gaugeColor: Color {
        switch disk.usedFraction {
        case ..<0.75: return .green
        case ..<0.9: return .orange
        default: return .red
        }
    }
}

struct RiskCard: View {
    let risk: RiskLevel
    let size: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Circle().fill(risk.color).frame(width: 8, height: 8)
                Text(risk.label).font(.caption.bold())
            }
            Text(ByteFormat.string(size))
                .font(.title3.bold().monospacedDigit())
            Text(risk.explanation)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 9))
    }
}

struct CategorySummaryRow: View {
    @ObservedObject var category: CleanupCategory
    @EnvironmentObject var model: AppModel

    var body: some View {
        Button {
            model.selection = .category(category.id)
        } label: {
            HStack(spacing: 11) {
                Image(systemName: category.symbol)
                    .frame(width: 20)
                    .foregroundStyle(.tint)
                Text(category.name)
                if category.items.isEmpty && category.didScan {
                    Text("niente da pulire")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if category.selectedSize > 0 {
                    Text("\(ByteFormat.string(category.selectedSize)) selezionati")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tint)
                }
                Text(ByteFormat.string(category.totalSize))
                    .font(.callout.monospacedDigit())
                    .frame(width: 90, alignment: .trailing)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 11)
            .background(Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }
}

struct SafetyNotice: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Come funziona la sicurezza", systemImage: "lock.shield.fill")
                .font(.callout.bold())
            Group {
                Text("• Ogni percorso passa da un controllo che rifiuta tutto ciò che non è in un elenco di aree consentite. In caso di dubbio l'operazione viene rifiutata, non eseguita.")
                Text("• Mai toccati: libreria Foto, iCloud Drive, portachiavi, Mail, Messaggi, chiavi SSH e GPG, backup dei dispositivi iOS, cartelle di sistema.")
                Text("• Nelle cartelle Documenti, Scrivania, Download e Filmati vengono rimossi solo gli artefatti di build, e solo se la cartella padre contiene un file di progetto riconoscibile. I tuoi file non vengono mai eliminati: per quelli il software offre solo «Mostra nel Finder».")
                Text("• «Sposta nel Cestino» è la modalità predefinita, così ogni operazione è reversibile.")
                Text("• «Simula» esegue tutti i controlli e mostra il risultato senza toccare il disco.")
                Text("• Ogni operazione viene registrata in ~/Library/Logs/Ammugghia.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 9))
    }
}

struct SectionTitle: View {
    let title: String
    let subtitle: String?

    init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
            if let subtitle {
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

extension RiskLevel {
    var color: Color {
        switch self {
        case .safe: return .green
        case .redownload: return .orange
        case .userData: return .red
        }
    }
}
