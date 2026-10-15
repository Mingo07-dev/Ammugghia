import SwiftUI
import AppKit

/// Impostazioni (⌘,). Per ora solo le esclusioni: tutto ciò che qui si
/// aggiunge può solo togliere percorsi da analisi ed eliminazione.
struct SettingsView: View {
    var body: some View {
        TabView {
            ExclusionsSettings()
                .tabItem { Label("Esclusioni", systemImage: "nosign") }
        }
        .frame(width: 640, height: 440)
    }
}

struct ExclusionsSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var newPattern = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Cartelle, file e nomi che Ammugghia deve ignorare. Un'esclusione può solo togliere: nulla di escluso viene analizzato o eliminato, e il motore lo rifiuta anche se ci arrivasse. Una cartella esclusa protegge anche tutto ciò che contiene, e impedisce di eliminare le cartelle che la contengono.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List {
                if model.exclusionRules.isEmpty {
                    Text("Nessuna esclusione.").foregroundStyle(.secondary)
                }
                ForEach($model.exclusionRules) { $rule in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: rule.isPath ? "folder" : "textformat")
                                .foregroundStyle(.secondary)
                            Text(rule.pattern)
                                .font(.system(.callout, design: .monospaced))
                                .lineLimit(1).truncationMode(.middle)
                            if rule.isPath && !FileManager.default.fileExists(atPath: rule.expandedPath) {
                                Text("non presente")
                                    .font(.caption2).foregroundStyle(.orange)
                                    .help("Resta in elenco: un disco ricollegato non deve rientrare nell'analisi per sbaglio.")
                            }
                            Spacer()
                            Button {
                                model.exclusionRules.removeAll { $0.id == rule.id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                            .help("Togli questa esclusione")
                        }
                        HStack(spacing: 12) {
                            ForEach(ExclusionRule.Scope.allCases, id: \.self) { scope in
                                Toggle(scope.label, isOn: Binding(
                                    get: { rule.scopes.contains(scope) },
                                    set: { on in
                                        if on { rule.scopes.insert(scope) } else { rule.scopes.remove(scope) }
                                    }))
                                .toggleStyle(.checkbox)
                                .font(.caption)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .listStyle(.bordered)

            HStack {
                Button("Aggiungi cartella o file…", action: addPaths)
                TextField("oppure uno schema sul nome, es. *.sparsebundle", text: $newPattern)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addPattern)
                Button("Aggiungi", action: addPattern)
                    .disabled(newPattern.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("Le modifiche valgono dalla prossima analisi. La mappa del disco si rifà da zero quando cambiano le sue esclusioni.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(16)
    }

    private func addPaths() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Escludi")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !model.exclusionRules.contains(where: { $0.expandedPath == url.path }) {
            model.exclusionRules.append(ExclusionRule(pattern: url.path))
        }
    }

    private func addPattern() {
        let pattern = newPattern.trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty, !model.exclusionRules.contains(where: { $0.pattern == pattern }) else { return }
        model.exclusionRules.append(ExclusionRule(pattern: pattern))
        newPattern = ""
    }
}
