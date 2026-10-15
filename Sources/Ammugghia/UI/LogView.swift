import SwiftUI

struct LogView: View {
    @EnvironmentObject var model: AppModel

    private var succeeded: [DeletionOutcome] { model.outcomes.filter(\.succeeded) }
    private var skipped: [DeletionOutcome] { model.outcomes.filter(\.skipped) }
    private var failed: [DeletionOutcome] { model.outcomes.filter { !$0.succeeded && !$0.skipped } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                Text("Registro").font(.title2.bold())

                if model.outcomes.isEmpty && model.logLines.isEmpty {
                    ContentUnavailableView("Nessuna operazione eseguita",
                                           systemImage: "list.bullet.rectangle",
                                           description: Text("Qui compariranno gli esiti di ogni operazione, incluse quelle rifiutate dai controlli di sicurezza."))
                        .frame(height: 240)
                } else {
                    // Riepilogo
                    HStack(spacing: 12) {
                        OutcomeCard(count: succeeded.count, label: "riuscite", color: .green,
                                    detail: ByteFormat.string(model.lastFreed))
                        OutcomeCard(count: skipped.count, label: "saltate", color: .secondary, detail: nil)
                        OutcomeCard(count: failed.count, label: String(localized: "non riuscite"), color: .red, detail: nil)
                    }

                    if !failed.isEmpty {
                        VStack(alignment: .leading, spacing: 7) {
                            SectionTitle("Non riuscite", subtitle: String(localized: "Nulla è stato modificato per queste voci"))
                            ForEach(failed) { outcome in
                                OutcomeRow(outcome: outcome, color: .red)
                            }
                        }
                    }

                    if !skipped.isEmpty {
                        VStack(alignment: .leading, spacing: 7) {
                            SectionTitle("Saltate")
                            ForEach(skipped) { outcome in
                                OutcomeRow(outcome: outcome, color: .secondary)
                            }
                        }
                    }

                    if !succeeded.isEmpty {
                        VStack(alignment: .leading, spacing: 7) {
                            SectionTitle("Riuscite")
                            ForEach(succeeded) { outcome in
                                OutcomeRow(outcome: outcome, color: .green)
                            }
                        }
                    }

                    if !model.didScan && !model.outcomes.isEmpty {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "arrow.clockwise").foregroundStyle(.blue)
                            Text("Le dimensioni misurate prima della pulizia non sono più valide. Premi «Analizza» per rimisurare il disco.")
                                .font(.callout)
                            Spacer()
                            Button("Analizza") { model.scanAll() }
                        }
                        .padding(11)
                        .background(Color.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
                    }

                    // Registro tecnico
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            SectionTitle("Dettaglio tecnico",
                                         subtitle: model.logFilePath.map { String(localized: "Salvato anche in \($0)") })
                            Spacer()
                            Button("Esporta…") { model.exportLog() }
                        }
                        ScrollView {
                            Text(model.logLines.joined(separator: "\n"))
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(9)
                        }
                        .frame(height: 220)
                        .background(Color(nsColor: .textBackgroundColor),
                                    in: RoundedRectangle(cornerRadius: 7))
                    }
                }
            }
            .padding(24)
        }
    }
}

struct OutcomeCard: View {
    let count: Int
    let label: String
    let color: Color
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(count)").font(.title.bold().monospacedDigit()).foregroundStyle(color)
            Text(label).font(.caption).foregroundStyle(.secondary)
            if let detail, count > 0 {
                Text(detail).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 9))
    }
}

struct OutcomeRow: View {
    let outcome: DeletionOutcome
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: outcome.succeeded ? "checkmark.circle.fill"
                                                : (outcome.skipped ? "minus.circle" : "xmark.circle.fill"))
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(outcome.title).font(.callout.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                Text(outcome.message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if outcome.freed > 0 {
                Text(ByteFormat.string(outcome.freed))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 7))
    }
}
