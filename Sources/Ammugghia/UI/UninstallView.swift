import SwiftUI

/// Disinstallazione completa. Un'app alla volta, con l'elenco integrale di
/// ciò che verrà rimosso e la possibilità di escludere ogni singola voce.
struct UninstallView: View {
    @EnvironmentObject var model: AppModel
    @State private var query = ""
    @State private var hideProtected = true

    private var filtered: [AppEntry] {
        model.apps.filter { app in
            if hideProtected && app.isProtected { return false }
            guard !query.isEmpty else { return true }
            return app.name.localizedCaseInsensitiveContains(query)
                || app.bundleID.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        HSplitView {
            // Elenco applicazioni
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    TextField("Cerca un'applicazione", text: $query)
                        .textFieldStyle(.roundedBorder)
                    Toggle("Nascondi le app di sistema e protette", isOn: $hideProtected)
                        .font(.caption)
                        .toggleStyle(.checkbox)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(11)

                Divider()

                if model.apps.isEmpty {
                    ContentUnavailableView("Nessuna applicazione rilevata",
                                           systemImage: "app.dashed",
                                           description: Text("Esegui l'analisi dalla barra degli strumenti."))
                } else {
                    List(filtered, selection: Binding(
                        get: { model.selectedApp?.id },
                        set: { newID in
                            model.selectedApp = model.apps.first { $0.id == newID }
                            if let app = model.selectedApp { model.loadRelated(for: app) }
                        }
                    )) { app in
                        AppListRow(app: app).tag(app.id)
                    }
                    .listStyle(.inset)

                    // Riepilogo delle app accodate: rende visibile che la
                    // scelta sopravvive al cambio di applicazione.
                    if !model.markedApps.isEmpty {
                        Divider()
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(Plural.of(model.markedApps.count, "app", "app")) nel piano di pulizia")
                                .font(.caption.bold())
                            ForEach(model.markedApps) { app in
                                HStack(spacing: 6) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.caption2).foregroundStyle(.tint)
                                    Text(app.name).font(.caption)
                                    Spacer()
                                    Text(ByteFormat.string(app.totalRemovalSize))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.accentColor.opacity(0.07))
                    }
                }
            }
            .frame(minWidth: 300, idealWidth: 340)

            // Dettaglio
            if let app = model.selectedApp {
                AppDetailView(app: app)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "trash.square")
                        .font(.system(size: 44))
                        .foregroundStyle(.tertiary)
                    Text("Seleziona un'applicazione")
                        .font(.headline)
                    Text("Il software cercherà tutti i file collegati — dati di supporto, cache, preferenze, container, servizi in background — e ti mostrerà l'elenco completo prima di rimuovere qualsiasi cosa.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct AppListRow: View {
    @ObservedObject var app: AppEntry

    var body: some View {
        HStack(spacing: 9) {
            AppIcon(path: app.path)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(app.name).font(.callout.weight(.medium)).lineLimit(1)
                    if app.isProtected {
                        Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Text(app.bundleID.isEmpty ? String(localized: "senza identificatore") : app.bundleID)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(ByteFormat.string(app.size))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct AppIcon: View {
    let path: String

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
            .resizable()
            .frame(width: 26, height: 26)
    }
}

struct AppDetailView: View {
    @ObservedObject var app: AppEntry
    @EnvironmentObject var model: AppModel

    private var userDataFiles: [RelatedFile] { app.related.filter(\.holdsUserData) }
    private var lowConfidence: [RelatedFile] { app.related.filter { $0.confidence == .name } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                // Intestazione
                HStack(alignment: .top, spacing: 13) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                        .resizable().frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.name).font(.title2.bold())
                        Text("Versione \(app.version) · \(app.bundleID)")
                            .font(.caption).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Text("\(app.path) — \(ByteFormat.string(app.size))")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1).truncationMode(.middle)
                        if app.lastUsed != nil {
                            Label(DateFormat.relative(app.lastUsed), systemImage: "clock")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }

                if app.isProtected {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "lock.shield.fill").foregroundStyle(.red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Non rimovibile con questo software").font(.callout.bold())
                            Text(app.protectionReason ?? "").font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                } else {
                    if app.isRunning {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Text("L'applicazione è in esecuzione. Chiudila prima di disinstallarla: altrimenti i file restano aperti e le preferenze vengono riscritte alla chiusura, vanificando la pulizia.")
                                .font(.callout).fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(12)
                        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    }

                    // Le due caselle richieste, con la prima attiva di default.
                    VStack(alignment: .leading, spacing: 9) {
                        Toggle(isOn: Binding(
                            get: { app.removeRelatedData },
                            set: { app.removeRelatedData = $0; model.objectWillChange.send() }
                        )) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Elimina anche tutti i dati e le cartelle collegate")
                                    .font(.callout.weight(.medium))
                                Text("Attiva per impostazione predefinita. Disattivandola viene rimossa solo l'applicazione, lasciando intatti dati e preferenze: utile se pensi di reinstallarla.")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        if app.removeRelatedData && !userDataFiles.isEmpty {
                            Toggle(isOn: Binding(
                                get: { app.backupUserData },
                                set: { app.backupUserData = $0; model.objectWillChange.send() }
                            )) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("Crea un archivio dei dati prima di eliminarli")
                                        .font(.callout.weight(.medium))
                                    Text("Salva \(userDataFiles.count == 1 ? String(localized: "la cartella") : String(localized: "le \(userDataFiles.count) cartelle")) con dati dell'applicazione in un file .zip in ~/Documents/Ammugghia Backup, così puoi \(Plural.word(userDataFiles.count, "recuperarla", "recuperarle")) se ti accorgi di averne bisogno.")
                                        .font(.caption).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }

                        // Il flag vive sull'AppEntry, non nel modello globale:
                        // cambiando applicazione e tornando indietro la spunta
                        // è ancora quella scelta.
                        Toggle(isOn: Binding(
                            get: { app.isMarkedForRemoval },
                            set: { app.isMarkedForRemoval = $0; model.objectWillChange.send() }
                        )) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Includi «\(app.name)» nel piano di pulizia")
                                    .font(.callout.weight(.semibold))
                                Text("Da eliminare insieme a tutto il resto premendo «Rivedi ed elimina» in basso. Puoi accodare più applicazioni.")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .disabled(app.isRunning)
                    }
                    .padding(13)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor),
                                in: RoundedRectangle(cornerRadius: 9))

                    // Totale e disinstallazione immediata
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Verranno rimossi")
                                .font(.callout)
                            Text(ByteFormat.string(app.totalRemovalSize))
                                .font(.title3.bold().monospacedDigit())
                                .foregroundStyle(.tint)
                        }
                        Spacer()
                        Button("Simula disinstallazione") {
                            model.requestExecution(items: AppInventory.removalItems(for: app),
                                                   dryRun: true)
                        }
                        .disabled(app.isRunning || model.isExecuting)
                        .help("Verifica i controlli di sicurezza e mostra cosa succederebbe, senza toccare il disco.")

                        // Disinstallazione della singola app, indipendente dal
                        // piano di pulizia complessivo.
                        Button {
                            model.requestExecution(items: AppInventory.removalItems(for: app),
                                                   dryRun: false)
                        } label: {
                            Label("Disinstalla ora…", systemImage: "trash")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(app.isRunning || model.isExecuting)
                        .help("Disinstalla solo «\(app.name)», senza avviare la pulizia delle altre categorie. Il riepilogo di conferma appare comunque.")
                    }
                }

                Divider()

                // File collegati
                if !app.didScanRelated {
                    HStack(spacing: 9) {
                        ProgressView().controlSize(.small)
                        Text("Ricerca dei file collegati…").foregroundStyle(.secondary)
                    }
                } else if app.related.isEmpty {
                    Text("Nessun file collegato trovato oltre al bundle dell'applicazione.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            SectionTitle("File collegati (\(app.related.count))",
                                         subtitle: String(localized: "Deseleziona qualsiasi voce che non vuoi rimuovere"))
                            Spacer()
                            Button("Tutti") {
                                for f in app.related { f.isSelected = true }
                                app.objectWillChange.send(); model.objectWillChange.send()
                            }.font(.caption)
                            Button("Nessuno") {
                                for f in app.related { f.isSelected = false }
                                app.objectWillChange.send(); model.objectWillChange.send()
                            }.font(.caption)
                        }

                        if !lowConfidence.isEmpty {
                            HStack(alignment: .top, spacing: 7) {
                                Image(systemName: "questionmark.circle.fill").foregroundStyle(.orange)
                                Text(markdown: lowConfidence.count == 1
                                     ? String(localized: "Una voce è stata trovata confrontando il **nome** dell'app invece dell'identificatore di bundle. Potrebbe appartenere a un altro programma: non è preselezionata, controllala.")
                                     : String(localized: "\(lowConfidence.count) voci sono state trovate confrontando il **nome** dell'app invece dell'identificatore di bundle. Potrebbero appartenere a un altro programma: non sono preselezionate, controllale una per una."))
                                    .font(.caption).fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(10)
                            .background(Color.orange.opacity(0.11), in: RoundedRectangle(cornerRadius: 7))
                        }

                        ForEach(app.related) { file in
                            RelatedFileRow(file: file, app: app, enabled: app.removeRelatedData && !app.isProtected)
                        }
                    }
                }
            }
            .padding(22)
        }
        .onAppear { model.loadRelated(for: app) }
    }
}

struct RelatedFileRow: View {
    @ObservedObject var file: RelatedFile
    @ObservedObject var app: AppEntry
    let enabled: Bool
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(
                get: { file.isSelected && enabled },
                set: { file.isSelected = $0; app.objectWillChange.send(); model.objectWillChange.send() }
            ))
            .labelsHidden()
            .disabled(!enabled)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(file.kind).font(.caption.bold())
                    if file.holdsUserData {
                        Text("contiene dati")
                            .font(.caption2.bold())
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.red.opacity(0.16), in: Capsule())
                            .foregroundStyle(.red)
                            .help("Questa cartella contiene documenti, database o impostazioni dell'applicazione, non solo cache.")
                    }
                    if file.needsAdmin {
                        Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                            .help("Richiede la password di amministratore.")
                    }
                    Text(file.confidence.label)
                        .font(.caption2)
                        .foregroundStyle(file.confidence == .name ? .orange : .secondary)
                    Spacer()
                    Text(ByteFormat.string(file.size))
                        .font(.caption.monospacedDigit())
                }
                HStack(spacing: 6) {
                    Text(file.path)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                    Button {
                        model.reveal(file.path)
                    } label: {
                        Image(systemName: "arrow.up.forward.app").font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .help("Mostra nel Finder")
                }
                if let caveat = file.confidence.caveat {
                    Text(caveat).font(.caption2).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(9)
        .background(Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 7))
        .opacity(enabled ? 1 : 0.5)
    }
}
