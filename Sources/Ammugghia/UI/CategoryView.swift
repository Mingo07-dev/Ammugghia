import SwiftUI

struct CategoryView: View {
    @ObservedObject var category: CleanupCategory
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 9) {
                        Image(systemName: category.symbol).font(.title2).foregroundStyle(.tint)
                        Text(category.name).font(.title2.bold())
                        if let badge = category.presence.badge {
                            Text(badge)
                                .font(.caption2.bold())
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.orange.opacity(0.17), in: Capsule())
                                .foregroundStyle(.orange)
                        }
                        Spacer()

                        // Rianalisi della singola categoria: le selezioni
                        // fatte nelle altre restano dove sono.
                        Button {
                            model.rescan(category.id)
                        } label: {
                            if category.isScanning {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("Rianalizza", systemImage: "arrow.clockwise")
                            }
                        }
                        .disabled(category.isScanning || model.isScanning || model.isExecuting)
                        .help("Rianalizza solo «\(category.name)», senza toccare le selezioni delle altre categorie.")

                        if category.totalSize > 0 {
                            Text(ByteFormat.string(category.totalSize))
                                .font(.title3.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(category.explanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    // Stato del programma di riferimento.
                    if case .residual(let detail) = category.presence {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "shippingbox.and.arrow.backward.fill")
                                .foregroundStyle(.orange)
                            Text(detail).font(.callout).fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(11)
                        .background(Color.orange.opacity(0.11),
                                    in: RoundedRectangle(cornerRadius: 8))
                    } else if case .absent(let detail) = category.presence {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "info.circle").foregroundStyle(.secondary)
                            Text(detail + " La scheda è visibile perché hai attivato «Mostra tutte le categorie».")
                                .font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(11)
                        .background(Color(nsColor: .controlBackgroundColor),
                                    in: RoundedRectangle(cornerRadius: 8))
                    }

                    if let note = category.scanNote {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "info.circle.fill").foregroundStyle(.blue)
                            Text(note).font(.callout).fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(11)
                        .background(Color.blue.opacity(0.09),
                                    in: RoundedRectangle(cornerRadius: 8))
                    }
                }

                if !category.didScan {
                    ContentUnavailableView("Categoria non ancora analizzata",
                                           systemImage: "magnifyingglass",
                                           description: Text("Premi «Analizza» nella barra degli strumenti."))
                        .frame(height: 200)
                } else if category.items.isEmpty {
                    ContentUnavailableView("Niente da pulire",
                                           systemImage: "checkmark.circle",
                                           description: Text("In questa categoria non c'è nulla che valga la pena eliminare."))
                        .frame(height: 200)
                } else {
                    HStack {
                        Button("Seleziona solo le voci sicure") {
                            for item in category.items {
                                item.isSelected = item.risk == .safe && item.warning == nil
                                    && !item.action.isInformationalOnly
                            }
                            category.enforceExclusivity()
                            category.objectWillChange.send()
                            model.objectWillChange.send()
                        }
                        Button("Deseleziona tutto") {
                            for item in category.items { item.isSelected = false }
                            category.objectWillChange.send()
                            model.objectWillChange.send()
                        }
                        Spacer()
                        Text(Plural.of(category.items.count, "voce", "voci"))
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    LazyVStack(spacing: 7) {
                        ForEach(category.items) { item in
                            ItemRow(item: item, category: category)
                        }
                    }
                }
            }
            .padding(24)
        }
    }
}

struct ItemRow: View {
    @ObservedObject var item: CleanupItem
    @ObservedObject var category: CleanupCategory
    @EnvironmentObject var model: AppModel

    private var problems: [String] { PathGuard.preflight(item) }
    private var isBlocked: Bool {
        // Un percorso già assente non è un problema: è solo lavoro già fatto.
        !problems.filter { !$0.contains("non esiste") }.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 11) {

                if item.action.isInformationalOnly {
                    Image(systemName: "eye")
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                        .help("Solo informativo: questo software non elimina questo elemento.")
                } else if isBlocked {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.red)
                        .frame(width: 16)
                        .help("Bloccato dai controlli di sicurezza.")
                } else {
                    Toggle("", isOn: Binding(
                        get: { item.isSelected },
                        set: { newValue in
                            item.isSelected = newValue
                            // Selezionare un'alternativa deseleziona l'altra,
                            // così i totali non contano due volte lo stesso
                            // spazio.
                            if newValue, let group = item.exclusiveGroup {
                                for other in category.items
                                where other.id != item.id && other.exclusiveGroup == group {
                                    other.isSelected = false
                                }
                            }
                            category.objectWillChange.send()
                            model.objectWillChange.send()
                        }
                    ))
                    .labelsHidden()
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(item.title)
                            .font(.callout.weight(.medium))
                            .fixedSize(horizontal: false, vertical: true)
                        RiskBadge(risk: item.risk)
                        if item.action.needsAdmin {
                            Image(systemName: "lock.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .help("Richiede la password di amministratore.")
                        }
                        Spacer()
                        Text(ByteFormat.string(item.size))
                            .font(.callout.monospacedDigit())
                    }

                    Text(item.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 12) {
                        if item.lastUsed != nil {
                            Label(DateFormat.relative(item.lastUsed), systemImage: "clock")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Button {
                            item.isExpanded.toggle()
                        } label: {
                            Label(item.isExpanded ? "Nascondi dettagli" : "Cosa verrà eliminato",
                                  systemImage: item.isExpanded ? "chevron.up" : "chevron.down")
                                .font(.caption2)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                    }

                    if let warning = item.warning {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange).font(.caption)
                            Text(warning).font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(8)
                        .background(Color.orange.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 6))
                    }

                    if isBlocked {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(problems, id: \.self) { problem in
                                Text("⛔︎ " + problem).font(.caption2).foregroundStyle(.red)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(8)
                        .background(Color.red.opacity(0.09),
                                    in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            .padding(12)

            if item.isExpanded {
                Divider()
                ItemDetails(item: item)
                    .padding(12)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(item.isSelected ? Color.accentColor.opacity(0.07)
                                      : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(item.isSelected ? Color.accentColor.opacity(0.35) : .clear, lineWidth: 1)
        )
    }
}

/// Il pannello che risponde a «cosa cancellerà esattamente».
struct ItemDetails: View {
    @ObservedObject var item: CleanupItem
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {

            DetailBlock(label: "Conseguenza dell'eliminazione", text: item.consequence)
            DetailBlock(label: "Operazione eseguita", text: item.action.commandDescription, monospaced: true)

            if !item.action.displayPaths.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Percorsi interessati (\(item.action.displayPaths.count))")
                        .font(.caption.bold())
                    ForEach(item.action.displayPaths, id: \.self) { path in
                        HStack(spacing: 7) {
                            Image(systemName: "folder")
                                .font(.caption2).foregroundStyle(.secondary)
                            Text(path)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(2)
                                .truncationMode(.middle)
                            Spacer()
                            if let size = item.perPathSize[path], size > 0 {
                                Text(ByteFormat.string(size))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Button {
                                model.reveal(path)
                            } label: {
                                Image(systemName: "arrow.up.forward.app")
                            }
                            .buttonStyle(.plain)
                            .help("Mostra nel Finder")
                        }
                        .padding(.vertical, 2)
                    }
                }
            } else {
                Text("Nessun file viene eliminato direttamente: l'operazione passa dallo strumento ufficiale indicato sopra, che gestisce anche i propri indici interni.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if item.lastUsed != nil {
                DetailBlock(label: "Ultimo utilizzo",
                            text: "\(DateFormat.string(item.lastUsed)) — \(DateFormat.relative(item.lastUsed))")
            }
        }
    }
}

struct DetailBlock: View {
    let label: String
    let text: String
    var monospaced: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption.bold())
            Text(text)
                .font(monospaced ? .system(.caption, design: .monospaced) : .caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct RiskBadge: View {
    let risk: RiskLevel

    var body: some View {
        Text(risk.label)
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(risk.color.opacity(0.17), in: Capsule())
            .foregroundStyle(risk.color)
            .help(risk.explanation)
    }
}
