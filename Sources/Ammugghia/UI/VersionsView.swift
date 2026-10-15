import SwiftUI

/// Consolidamento delle versioni multiple. Il punto di questa scheda è
/// mostrare *quante* copie della stessa cosa hai e lasciarti scegliere quali
/// tenere, non decidere al tuo posto.
struct VersionsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {

                VStack(alignment: .leading, spacing: 6) {
                    Text("Versioni multiple").font(.title2.bold())
                    Text("Software di cui hai più versioni installate contemporaneamente. Spesso è normale — un progetto può richiedere una versione specifica — ma altrettanto spesso sono copie dimenticate dopo un aggiornamento.\n\nPer ogni gruppo scegli quali versioni tenere. Nessuna è preselezionata: la decisione è tua.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !model.didScan {
                    ContentUnavailableView("Analisi non ancora eseguita",
                                           systemImage: "magnifyingglass",
                                           description: Text("Premi «Analizza» nella barra degli strumenti."))
                        .frame(height: 220)
                } else if model.versionGroups.isEmpty {
                    ContentUnavailableView("Nessuna versione duplicata",
                                           systemImage: "checkmark.circle",
                                           description: Text("Non risultano più versioni installate della stessa cosa."))
                        .frame(height: 220)
                } else {
                    ForEach(model.versionGroups) { group in
                        VersionGroupCard(group: group)
                    }
                }
            }
            .padding(24)
        }
    }
}

struct VersionGroupCard: View {
    @ObservedObject var group: VersionGroup
    @EnvironmentObject var model: AppModel
    @State private var showRationale = false

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {

            HStack(spacing: 9) {
                Image(systemName: group.symbol).foregroundStyle(.tint)
                Text(group.title).font(.headline)
                Text(Plural.of(group.entries.count, "versione", "versioni"))
                    .font(.caption)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color(nsColor: .quaternaryLabelColor), in: Capsule())
                Spacer()
                Text(ByteFormat.string(group.totalSize))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            // Il consiglio, in evidenza.
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lightbulb.fill").foregroundStyle(.yellow).font(.caption)
                Text(group.suggestion).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .background(Color.yellow.opacity(0.11), in: RoundedRectangle(cornerRadius: 7))

            Button {
                showRationale.toggle()
            } label: {
                Label(showRationale ? String(localized: "Nascondi spiegazione") : String(localized: "Perché ho più versioni?"),
                      systemImage: showRationale ? "chevron.up" : "chevron.down")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)

            if showRationale {
                Text(group.rationale)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .background(Color(nsColor: .textBackgroundColor),
                                in: RoundedRectangle(cornerRadius: 7))
            }

            Divider()

            ForEach(group.entries) { entry in
                VersionRow(group: group, entry: entry)
            }

            // Avviso quando si sta rimuovendo tutto.
            if group.remainingCount == 0 && !group.markedForRemoval.isEmpty {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text("Stai rimuovendo **tutte** le versioni: non ne resterà nessuna installata. Se non è quello che vuoi, lasciane almeno una.")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
            }

            if group.reclaimableSize > 0 {
                HStack {
                    Spacer()
                    Text("Selezionati: \(ByteFormat.string(group.reclaimableSize)) — restano \(Plural.of(group.remainingCount, "versione", "versioni"))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tint)
                }
            }
        }
        .padding(15)
        .background(Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 10))
    }
}

struct VersionRow: View {
    @ObservedObject var group: VersionGroup
    let entry: VersionEntry
    @EnvironmentObject var model: AppModel

    private var isMarked: Bool { group.markedForRemoval.contains(entry.id) }

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Toggle("", isOn: Binding(
                get: { isMarked },
                set: { newValue in
                    if newValue { group.markedForRemoval.insert(entry.id) }
                    else { group.markedForRemoval.remove(entry.id) }
                    model.objectWillChange.send()
                }
            ))
            .labelsHidden()

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(entry.label).font(.callout.weight(.medium))
                    if entry.recommendedToKeep {
                        Text("consigliato tenere")
                            .font(.caption2.bold())
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.green.opacity(0.17), in: Capsule())
                            .foregroundStyle(.green)
                    }
                    RiskBadge(risk: entry.risk)
                    Spacer()
                    Text(ByteFormat.string(entry.size))
                        .font(.callout.monospacedDigit())
                }
                if let note = entry.note {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 12) {
                    Text(DateFormat.relative(entry.lastUsed))
                        .font(.caption2).foregroundStyle(.secondary)
                    Text(entry.action.commandDescription)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
                ForEach(entry.paths, id: \.self) { path in
                    HStack(spacing: 6) {
                        Text(path)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                            .textSelection(.enabled)
                        Button {
                            model.reveal(path)
                        } label: {
                            Image(systemName: "arrow.up.forward.app").font(.caption2)
                        }
                        .buttonStyle(.plain)
                        .help("Mostra nel Finder")
                    }
                }
            }
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isMarked ? Color.red.opacity(0.07) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(isMarked ? Color.red.opacity(0.3)
                                 : (entry.recommendedToKeep ? Color.green.opacity(0.25) : .clear),
                        lineWidth: 1)
        )
    }
}
