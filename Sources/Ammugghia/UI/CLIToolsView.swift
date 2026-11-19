import SwiftUI

/// Strumenti installati da Homebrew e npm: versione, aggiornamenti e da chi
/// sono necessari, con aggiornamento e rimozione. Ogni comando si mostra per
/// intero prima di essere eseguito. uv e rustup si elencano soltanto.
struct CLIToolsView: View {
    @EnvironmentObject var model: AppModel
    @State private var pending: PendingCommand?

    private struct PendingCommand {
        let title: String
        let command: CLICommand
        let effect: String
        let destructive: Bool
    }

    private let sections: [CLITool.Source] = [.brewFormula, .brewCask, .npm, .uv, .rustup]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            List {
                ForEach(sections, id: \.self) { source in
                    let tools = model.cliSnapshot.tools.filter { $0.source == source }
                    if !tools.isEmpty {
                        Section {
                            ForEach(tools) { tool in row(tool) }
                        } header: {
                            Text(source.label) + Text(" · \(tools.count)").foregroundColor(.secondary)
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
        .task { if !model.cliDidLoad { model.loadCLITools() } }
        .confirmationDialog(pending?.title ?? "", isPresented: Binding(
            get: { pending != nil }, set: { if !$0 { pending = nil } }
        ), titleVisibility: .visible) {
            if let pending {
                Button(String(localized: "Esegui"), role: pending.destructive ? .destructive : nil) {
                    model.runCLI(pending.command, title: pending.title)
                }
                Button("Annulla", role: .cancel) {}
            }
        } message: {
            if let pending {
                Text(pending.effect + String(localized: "\n\nComando eseguito:\n") + pending.command.display)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Strumenti da riga di comando").font(.title2.bold())
                Spacer()
                if model.isLoadingCLI { ProgressView().controlSize(.small) }
                Button {
                    model.loadCLITools()
                } label: {
                    Label("Aggiorna", systemImage: "arrow.clockwise")
                }
                .disabled(model.isLoadingCLI || model.cliRunning != nil)
            }
            Text("Programmi installati con Homebrew e npm, con la versione, gli aggiornamenti disponibili e quali altri strumenti ne hanno bisogno. Un programma necessario ad altri non si può rimuovere da qui. uv e rustup sono solo elencati.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.cliSnapshot.brewPath != nil {
                HStack(spacing: 8) {
                    ForEach(CLIInventory.GlobalAction.allCases, id: \.self) { action in
                        Button(action.title) {
                            guard let command = CLIInventory.command(action, in: model.cliSnapshot) else { return }
                            pending = PendingCommand(title: action.title, command: command,
                                                     effect: action.effect, destructive: action != .update)
                        }
                        .controlSize(.small)
                        .disabled(model.cliRunning != nil)
                    }
                }
            } else if model.cliDidLoad {
                Text("Homebrew non è installato.").font(.caption).foregroundStyle(.tertiary)
            }
            if let running = model.cliRunning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("In esecuzione: \(running)").font(.caption.monospaced())
                }
            } else if let message = model.cliMessage {
                Text(message).font(.caption.bold()).foregroundStyle(.tint)
            }
        }
        .padding(16)
    }

    private func row(_ tool: CLITool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(tool.name).font(.callout.weight(.medium))
                    Text(tool.version).font(.caption.monospaced()).foregroundStyle(.secondary)
                    if let note = tool.note { Text(note).font(.caption).foregroundStyle(.secondary) }
                    if tool.isOutdated, let latest = tool.latestVersion {
                        badge(String(localized: "aggiornabile a \(latest)"), tint: .orange)
                    }
                    if tool.source == .brewFormula, !tool.installedOnRequest {
                        badge(String(localized: "dipendenza"), tint: nil)
                    }
                }
                if let summary = tool.summary {
                    Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if !tool.neededBy.isEmpty {
                    Text("Necessario a: \(tool.neededBy.prefix(6).joined(separator: ", "))\(tool.neededBy.count > 6 ? "…" : "")")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if tool.source.isManaged {
                if tool.isOutdated {
                    Button("Aggiorna") { ask(tool, upgrade: true) }
                        .controlSize(.small)
                        .disabled(model.cliRunning != nil)
                }
                Button("Rimuovi") { ask(tool, upgrade: false) }
                    .controlSize(.small)
                    .disabled(model.cliRunning != nil
                              || CLIInventory.uninstall(tool, in: model.cliSnapshot) == nil)
                    .help(tool.neededBy.isEmpty
                          ? String(localized: "Rimuove lo strumento.")
                          : String(localized: "Non si può rimuovere: altri strumenti installati ne hanno bisogno."))
            }
        }
        .padding(.vertical, 3)
    }

    private func badge(_ text: String, tint: Color?) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(tint.map { AnyShapeStyle($0.opacity(0.25)) } ?? AnyShapeStyle(Color(nsColor: .quaternaryLabelColor)), in: Capsule())
    }

    private func ask(_ tool: CLITool, upgrade: Bool) {
        let snapshot = model.cliSnapshot
        guard let command = upgrade ? CLIInventory.upgrade(tool, in: snapshot) : CLIInventory.uninstall(tool, in: snapshot) else { return }
        let passwordNote = tool.source == .brewCask
            ? String(localized: "\n\nUn cask può richiedere la password di amministratore, che qui non si può inserire: se il comando non riesce, eseguilo nel Terminale.")
            : ""
        pending = upgrade
            ? PendingCommand(title: String(localized: "Aggiornare «\(tool.name)»?"), command: command,
                             effect: String(localized: "Installa l'ultima versione. Il programma in uso può cambiare comportamento.") + passwordNote,
                             destructive: false)
            : PendingCommand(title: String(localized: "Rimuovere «\(tool.name)»?"), command: command,
                             effect: String(localized: "Lo strumento viene disinstallato. I programmi che lo usano e non sono elencati come dipendenti smettono di funzionare.") + passwordNote,
                             destructive: true)
    }
}
