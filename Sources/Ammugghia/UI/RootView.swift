import SwiftUI

@main
struct AmmugghiaApp: App {
    @StateObject private var model = AppModel()

    init() {
        // `Ammugghia --selftest` verifica le protezioni e termina senza
        // aprire l'interfaccia.
        if CommandLine.arguments.contains("--selftest") {
            exit(SelfTest.run())
        }
        // `Ammugghia --report` stampa l'analisi completa senza aprire nulla.
        if CommandLine.arguments.contains("--report") {
            exit(Report.run())
        }
        if CommandLine.arguments.contains("--index") {
            exit(Report.runIndex())
        }
        if CommandLine.arguments.contains("--startup") {
            exit(Report.runStartup())
        }
        if CommandLine.arguments.contains("--duplicates") {
            exit(Report.runDuplicates())
        }
        if CommandLine.arguments.contains("--verify-index") {
            exit(Report.runVerifyIndex())
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 1080, minHeight: 720)
        }
        .windowToolbarStyle(.unified)

        Settings {
            SettingsView()
                .environmentObject(model)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Rianalizza il disco") { model.scanAll() }
                    .keyboardShortcut("r")
                Button("Rifai la mappa del disco da zero") {
                    model.selection = .diskMap
                    model.refreshIndex(forceFull: true)
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        // La barra dei comandi sta in un VStack, non come overlay: con
        // `safeAreaInset` sul NavigationSplitView l'inset non raggiungeva le
        // ScrollView interne e le ultime voci finivano sotto i pulsanti.
        VStack(spacing: 0) {
            NavigationSplitView {
                Sidebar()
            } detail: {
                Detail()
            }
            .navigationTitle("Ammugghia")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Toggle("Mostra tutte le categorie", isOn: $model.showAllCategories)
                        Text(model.hiddenCategoryCount == 0
                             ? "Tutte le categorie sono già visibili."
                             : "\(Plural.of(model.hiddenCategoryCount, "categoria nascosta", "categorie nascoste")): il programma di riferimento non è installato e non ha lasciato residui.")
                        Divider()
                        Button("Rianalizza tutto") { model.scanAll() }
                            .disabled(model.isScanning || model.isExecuting)
                        Button("Deseleziona tutto") { model.deselectAll() }
                    } label: {
                        Label("Opzioni", systemImage: "slider.horizontal.3")
                    }
                    .help("Visualizzazione delle categorie e azioni globali.")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.scanAll()
                    } label: {
                        Label(model.didScan ? "Rianalizza" : "Analizza", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isScanning || model.isExecuting)
                }
            }

            ActionBar()
        }
        .sheet(isPresented: Binding(
            get: { model.confirmPlan != nil },
            set: { if !$0 { model.confirmPlan = nil } }
        )) {
            if let plan = model.confirmPlan {
                ConfirmSheet(items: plan, isDryRun: model.confirmIsDryRun)
            }
        }
        .task {
            if !model.didScan && !model.isScanning { model.scanAll() }
        }
    }
}

// MARK: - Barra laterale

struct Sidebar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List(selection: $model.selection) {
            NavigationLink(value: SidebarSection.overview) {
                Label("Panoramica", systemImage: "chart.pie.fill")
            }

            Section("Pulizia per categoria") {
                ForEach(model.visibleCategories) { category in
                    NavigationLink(value: SidebarSection.category(category.id)) {
                        CategoryRow(category: category)
                    }
                }
                if !model.showAllCategories && model.hiddenCategoryCount > 0 {
                    Button {
                        model.showAllCategories = true
                    } label: {
                        Label("\(model.hiddenCategoryCount) nascoste (non installate)",
                              systemImage: "eye.slash")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Mostra anche le categorie dei programmi che non risultano installati.")
                }
            }

            Section("Analisi") {
                NavigationLink(value: SidebarSection.diskMap) {
                    Label("Mappa del disco", systemImage: "square.grid.3x3.square")
                }
                NavigationLink(value: SidebarSection.duplicates) {
                    Label("File duplicati", systemImage: "doc.on.doc")
                }
                NavigationLink(value: SidebarSection.versions) {
                    Label {
                        HStack {
                            Text("Versioni multiple")
                            Spacer()
                            if !model.versionGroups.isEmpty {
                                Text("\(model.versionGroups.count)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } icon: {
                        Image(systemName: "square.stack.3d.down.right.fill")
                    }
                }
                NavigationLink(value: SidebarSection.startup) {
                    Label("Elementi d'avvio", systemImage: "power.circle")
                }
                NavigationLink(value: SidebarSection.uninstall) {
                    Label("Disinstalla app", systemImage: "trash.square.fill")
                }
                NavigationLink(value: SidebarSection.history) {
                    Label("Cronologia", systemImage: "clock.arrow.circlepath")
                }
                NavigationLink(value: SidebarSection.log) {
                    Label("Registro", systemImage: "list.bullet.rectangle")
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 260)
    }
}

struct CategoryRow: View {
    @ObservedObject var category: CleanupCategory

    var body: some View {
        Label {
            HStack(spacing: 6) {
                Text(category.name)
                if category.isScanning {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                }
                if case .residual = category.presence {
                    Image(systemName: "shippingbox.and.arrow.backward.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .help("Il programma non è installato ma ha lasciato residui.")
                } else if case .absent = category.presence {
                    Image(systemName: "eye.slash")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .help("Programma non installato: nessun residuo trovato.")
                }
                Spacer()
                if category.selectedSize > 0 {
                    Text(ByteFormat.string(category.selectedSize))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tint)
                } else if category.totalSize > 0 {
                    Text(ByteFormat.string(category.totalSize))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: category.symbol)
        }
    }
}

// MARK: - Contenuto

struct Detail: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            switch model.selection {
            case .overview, .none:
                OverviewView()
            case .category(let id):
                CategoryView(category: model.category(id))
            case .versions:
                VersionsView()
            case .diskMap:
                DiskMapView()
            case .duplicates:
                DuplicatesView()
            case .startup:
                StartupView()
            case .history:
                HistoryView()
            case .uninstall:
                UninstallView()
            case .log:
                LogView()
            }
        }
        .frame(minWidth: 700)
    }
}

// MARK: - Barra inferiore

struct ActionBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 14) {
                if model.isScanning {
                    ProgressView(value: model.scanFraction)
                        .frame(width: 130)
                    Text(model.scanProgress)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if model.isExecuting {
                    ProgressView().controlSize(.small)
                    Text(model.executionProgress)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    let count = model.selectedItems.count
                    Text(count == 0
                         ? "Nessun elemento selezionato"
                         : "\(Plural.of(count, "operazione", "operazioni")) \(Plural.word(count, "selezionata", "selezionate"))")
                        .font(.callout)
                        .lineLimit(1)
                    if model.selectedSize > 0 {
                        Text(ByteFormat.string(model.selectedSize))
                            .font(.callout.bold().monospacedDigit())
                            .foregroundStyle(.tint)
                    }
                    if model.selectedHasUserData {
                        Label("include dati utente", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if model.selectedNeedsAdmin {
                        Label("richiede password", systemImage: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 12)

                HStack(spacing: 5) {
                    Text("Modalità:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("", selection: $model.removalMode) {
                        ForEach(RemovalMode.allCases) { mode in
                            Text(mode.shortLabel).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .disabled(model.isExecuting)
                    .help(model.removalMode.caveat)
                }
                .layoutPriority(1)

                Button("Simula") { model.requestExecution(dryRun: true) }
                    .fixedSize()
                    .disabled(model.selectedItems.isEmpty || model.isExecuting)
                    .help("Verifica tutti i controlli di sicurezza e mostra cosa succederebbe, senza toccare il disco.")

                Button("Rivedi ed elimina…") { model.requestExecution(dryRun: false) }
                    .fixedSize()
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.selectedItems.isEmpty || model.isExecuting)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .background(.bar)
        }
    }
}
