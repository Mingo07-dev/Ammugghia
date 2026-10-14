import SwiftUI
import AppKit

/// File con contenuto identico nelle cartelle personali.
///
/// Solo «Mostra nel Finder»: i duplicati stanno quasi sempre in Documenti,
/// Scrivania e Download, dove questo software non elimina nulla. Quale copia
/// tenere lo decide chi conosce i file.
struct DuplicatesView: View {
    @EnvironmentObject var model: AppModel

    private let sizes: [(String, Int64)] = [
        ("1 MB", 1_000_000), ("10 MB", 10_000_000), ("100 MB", 100_000_000), ("1 GB", 1_000_000_000),
    ]

    private var totalRecoverable: Int64 { model.duplicateGroups.reduce(0) { $0 + $1.recoverable } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("File duplicati").font(.title2.bold())
                    Spacer()
                    if model.duplicatesDidRun && !model.duplicateGroups.isEmpty {
                        Text("\(ByteFormat.string(totalRecoverable)) recuperabili")
                            .font(.title3.bold().monospacedDigit())
                            .foregroundStyle(.tint)
                    }
                }
                Text("File con contenuto identico byte per byte, confermato dall'impronta SHA-256 dell'intero file. Ammugghia non elimina file dalle tue cartelle personali: mostra i gruppi, e la copia da tenere la scegli tu nel Finder.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                controls
                roots
            }
            .padding(16)
            Divider()
            content
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("Dimensione minima", selection: $model.duplicateMinimumSize) {
                ForEach(sizes, id: \.1) { label, value in Text(label).tag(value) }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .disabled(model.isFindingDuplicates)
            Spacer()
            if model.isFindingDuplicates {
                ProgressView().controlSize(.small)
                Text(model.duplicateProgress).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button("Annulla") { model.cancelDuplicates() }
            } else {
                Button(model.duplicatesDidRun ? "Cerca di nuovo" : "Cerca i duplicati") {
                    model.findDuplicates()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var roots: some View {
        HStack(spacing: 6) {
            Text("Cartelle:").font(.caption).foregroundStyle(.secondary)
            ForEach(model.duplicateRoots, id: \.self) { root in
                HStack(spacing: 3) {
                    Text((root as NSString).lastPathComponent).font(.caption)
                    if model.duplicateExtraRoots.contains(root) {
                        Button {
                            model.duplicateExtraRoots.removeAll { $0 == root }
                        } label: {
                            Image(systemName: "xmark.circle.fill").font(.caption2)
                        }
                        .buttonStyle(.plain)
                        .help("Togli questa cartella dalla ricerca")
                    }
                }
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Color(nsColor: .quaternaryLabelColor), in: Capsule())
                .help(root)
            }
            Button("Aggiungi…", action: addRoot)
                .controlSize(.small)
                .disabled(model.isFindingDuplicates)
            Spacer()
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.isFindingDuplicates && model.duplicateGroups.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                ProgressView()
                Text(model.duplicateProgress).font(.callout.monospacedDigit())
                Text("I file vengono letti solo se hanno la stessa dimensione di un altro: la seconda ricerca è quasi immediata perché le impronte restano in memoria.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else if !model.duplicatesDidRun {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "doc.on.doc").font(.largeTitle).foregroundStyle(.secondary)
                Text("Avvia la ricerca per trovare i file duplicati.").foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else if model.duplicateGroups.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "checkmark.circle").font(.largeTitle).foregroundStyle(.green)
                Text("Nessun duplicato sopra la dimensione minima.").foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            List {
                Text("\(Plural.of(model.duplicateGroups.count, "gruppo", "gruppi")) di file identici")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(model.duplicateGroups) { group in
                    DuplicateGroupRow(group: group)
                }
            }
            .listStyle(.inset)
        }
    }

    private func addRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Aggiungi"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !model.duplicateRoots.contains(url.path) {
            model.duplicateExtraRoots.append(url.path)
        }
    }
}

struct DuplicateGroupRow: View {
    let group: DuplicateGroup
    @EnvironmentObject var model: AppModel
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                if group.hasClones {
                    Label("Alcune copie sono cloni APFS (copie fatte dal Finder) e condividono lo spazio: eliminarle libera meno di quanto sembri. Il totale recuperabile ne tiene già conto.",
                          systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(group.files) { file in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text((file.path as NSString).lastPathComponent).font(.callout)
                            Text((file.path as NSString).deletingLastPathComponent)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        Text(file.modified.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button {
                            model.reveal(file.path)
                        } label: {
                            Image(systemName: "arrow.up.forward.app")
                        }
                        .buttonStyle(.plain)
                        .help("Mostra nel Finder")
                    }
                }
                Button("Mostra tutte nel Finder") { model.revealAll(group.files.map(\.path)) }
                    .controlSize(.small)
            }
            .padding(.vertical, 4)
        } label: {
            HStack {
                Image(systemName: "doc.on.doc").foregroundStyle(.secondary)
                Text((group.files.first?.path as NSString?)?.lastPathComponent ?? "—")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text("\(group.files.count) copie da \(ByteFormat.string(group.size))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(ByteFormat.string(group.recoverable))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(group.recoverable > 0 ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
        }
    }
}
