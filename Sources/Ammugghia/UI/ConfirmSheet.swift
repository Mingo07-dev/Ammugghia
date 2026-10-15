import SwiftUI

/// Ultima barriera. Mostra l'elenco integrale — ogni percorso, ogni comando —
/// e richiede conferme proporzionate al rischio.
struct ConfirmSheet: View {
    let items: [CleanupItem]
    let isDryRun: Bool

    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var didRead = false
    @State private var typedConfirmation = ""
    /// Bundle id delle app richieste chiuse che risultano aperte adesso.
    @State private var runningApps: [String] = []

    private var total: Int64 { items.reduce(0) { $0 + $1.size } }
    private var userDataItems: [CleanupItem] { items.filter { $0.risk == .userData } }
    private var adminItems: [CleanupItem] { items.filter { $0.action.needsAdmin } }
    private var allPaths: [String] { items.flatMap { $0.action.displayPaths } }

    /// Elementi raggruppati per provenienza, nell'ordine in cui compaiono nel
    /// piano: leggere «Xcode: 3 voci, 5 GB» è più utile di un elenco piatto.
    private var groups: [(origin: String, items: [CleanupItem])] {
        var order: [String] = []
        var buckets: [String: [CleanupItem]] = [:]
        for item in items {
            if buckets[item.origin] == nil { order.append(item.origin) }
            buckets[item.origin, default: []].append(item)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    private var requiredStoppedApps: [String] {
        var seen = Set<String>()
        return items.flatMap(\.requiredStoppedApps).filter { seen.insert($0).inserted }
    }

    private func refreshRunningApps() {
        runningApps = requiredStoppedApps.filter { AppRuntime.isRunning(bundleID: $0) }
    }

    /// La parola da digitare quando in gioco ci sono dati non recuperabili.
    private let requiredWord = String(localized: "ELIMINA")

    private var needsTypedConfirmation: Bool {
        !isDryRun && !userDataItems.isEmpty && model.removalMode == .permanent
    }

    private var canProceed: Bool {
        if isDryRun { return true }
        guard didRead else { return false }
        if needsTypedConfirmation { return typedConfirmation == requiredWord }
        return true
    }

    var body: some View {
        VStack(spacing: 0) {

            // Intestazione
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 9) {
                    Image(systemName: isDryRun ? "eyeglasses" : "exclamationmark.triangle.fill")
                        .font(.title2)
                        .foregroundStyle(isDryRun ? .blue : .orange)
                    Text(isDryRun ? String(localized: "Simulazione") : String(localized: "Conferma la pulizia")).font(.title2.bold())
                    Spacer()
                    Text(ByteFormat.string(total))
                        .font(.title3.bold().monospacedDigit())
                        .foregroundStyle(.tint)
                }
                Text(markdown: isDryRun
                     ? String(localized: "Verranno eseguiti tutti i controlli di sicurezza e registrato ciò che accadrebbe. Nessun file verrà modificato.")
                     : String(localized: "\(Plural.of(items.count, "operazione", "operazioni")) su \(Plural.of(allPaths.count, "percorso", "percorsi")). Modalità: **\(model.removalMode.label)** — \(model.removalMode.caveat)"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)

            Divider()

            // Elenco integrale
            ScrollView {
                VStack(alignment: .leading, spacing: 9) {

                    if !userDataItems.isEmpty {
                        WarningPanel(
                            color: .red,
                            icon: "exclamationmark.octagon.fill",
                            title: userDataItems.count == 1
                                ? String(localized: "1 operazione coinvolge dati non recuperabili")
                                : String(localized: "\(userDataItems.count) operazioni coinvolgono dati non recuperabili"),
                            body: userDataItems.map { "• \($0.title)" }.joined(separator: "\n")
                                + String(localized: "\n\nQuesti elementi non si rigenerano da soli. Se non sei sicuro, deselezionali e procedi con il resto.")
                        )
                    }

                    if !adminItems.isEmpty {
                        WarningPanel(
                            color: .blue,
                            icon: "lock.fill",
                            title: adminItems.count == 1
                                ? String(localized: "1 operazione richiede la password di amministratore")
                                : String(localized: "\(adminItems.count) operazioni richiedono la password di amministratore"),
                            body: adminItems.map { "• \($0.title)\n  \($0.action.commandDescription)" }.joined(separator: "\n")
                                + String(localized: "\n\nIl comando esatto è riportato qui sopra: macOS chiederà la password una volta per ciascuno.")
                        )
                    }

                    if !runningApps.isEmpty {
                        RunningAppsPanel(bundleIDs: runningApps,
                                         blockedItems: items.filter { item in
                                             item.requiredStoppedApps.contains(where: runningApps.contains)
                                         })
                    }

                    ForEach(groups, id: \.origin) { group in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(spacing: 7) {
                                Text(group.origin)
                                    .font(.callout.bold())
                                Text(Plural.of(group.items.count, "voce", "voci"))
                                    .font(.caption2)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color(nsColor: .quaternaryLabelColor), in: Capsule())
                                Spacer()
                                Text(ByteFormat.string(group.items.reduce(0) { $0 + $1.size }))
                                    .font(.callout.monospacedDigit())
                                    .foregroundStyle(.tint)
                            }
                            .padding(.top, 4)

                            ForEach(group.items) { item in
                                PlanRow(item: item)
                            }
                        }
                    }
                }
                .padding(20)
            }
            .frame(maxHeight: 400)

            Divider()

            // Conferme
            VStack(alignment: .leading, spacing: 11) {
                if !isDryRun {
                    Toggle(isOn: $didRead) {
                        Text("Ho letto l'elenco completo e voglio procedere")
                            .font(.callout)
                    }

                    if needsTypedConfirmation {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Stai eliminando definitivamente dati non recuperabili. Scrivi **\(requiredWord)** per confermare:")
                                .font(.callout)
                            TextField(requiredWord, text: $typedConfirmation)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 200)
                        }
                        .padding(11)
                        .background(Color.red.opacity(0.09), in: RoundedRectangle(cornerRadius: 7))
                    } else if !userDataItems.isEmpty {
                        Text("Gli elementi con dati non recuperabili verranno spostati nel Cestino, quindi potrai ripristinarli. Passando a «Elimina definitivamente» servirà una conferma scritta.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(spacing: 10) {
                    Button("Esporta l'elenco…") { model.exportPlan(items) }
                    Spacer()
                    Button("Annulla") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button(isDryRun ? String(localized: "Esegui la simulazione") : String(localized: "Procedi")) {
                        model.execute(items: items, dryRun: isDryRun)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canProceed)
                }
            }
            .padding(20)
        }
        .frame(width: 780)
        .onAppear(perform: refreshRunningApps)
        // L'elenco si aggiorna da solo quando l'utente chiude o riapre un'app,
        // dal pannello o altrove.
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.didTerminateApplicationNotification)) { _ in refreshRunningApps() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.didLaunchApplicationNotification)) { _ in refreshRunningApps() }
    }
}

/// App da chiudere prima di procedere. Non blocca l'intero piano: gli altri
/// elementi possono andare avanti, quelli legati alle app aperte vengono
/// saltati dal motore e lo dice il registro.
struct RunningAppsPanel: View {
    let bundleIDs: [String]
    let blockedItems: [CleanupItem]

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "app.badge.checkmark").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(bundleIDs.count == 1
                     ? String(localized: "\(names) è aperta")
                     : String(localized: "\(Plural.of(bundleIDs.count, "app aperta", "app aperte")): \(names)"))
                    .font(.callout.bold())
                Text(String(localized: "Le app aperte riscrivono la propria cache mentre la si elimina. Finché restano aperte, \(Plural.of(blockedItems.count, "questa voce verrà saltata", "queste voci verranno saltate")):")
                     + "\n" + blockedItems.map { "• \($0.title)" }.joined(separator: "\n"))
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Button(Plural.word(bundleIDs.count, "Chiudi l'app", "Chiudi le app")) {
                    AppRuntime.requestQuit(bundleIDs: bundleIDs)
                }
                .help("Chiede la chiusura come dal menu dell'app: se ci sono documenti non salvati, l'app te lo chiederà.")
                .padding(.top, 3)
            }
            Spacer()
        }
        .padding(12)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    private var names: String {
        bundleIDs.map { AppRuntime.displayName(bundleID: $0) }.joined(separator: ", ")
    }
}

extension Text {
    /// Testo già tradotto che contiene Markdown (`**grassetto**`). Passato a
    /// `Text` come `String` verrebbe mostrato con gli asterischi; con una
    /// `LocalizedStringKey` verrebbe cercato di nuovo fra le traduzioni.
    init(markdown string: String) {
        let parsed = (try? AttributedString(markdown: string,
                                            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(string)
        self.init(parsed)
    }
}

struct PlanRow: View {
    let item: CleanupItem
    @EnvironmentObject var model: AppModel
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Circle().fill(item.risk.color).frame(width: 7, height: 7)
                Text(item.title).font(.callout.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Text(ByteFormat.string(item.size))
                    .font(.callout.monospacedDigit())
            }

            Text(item.consequence)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let warning = item.warning {
                Text("⚠︎ " + warning)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Text(item.action.commandDescription)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
                if !item.action.displayPaths.isEmpty {
                    Button {
                        expanded.toggle()
                    } label: {
                        Text(expanded
                             ? String(localized: "nascondi i percorsi")
                             : String(localized: "mostra \(Plural.of(item.action.displayPaths.count, "percorso", "percorsi"))"))
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                }
            }

            if expanded {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(item.action.displayPaths, id: \.self) { path in
                        HStack(spacing: 6) {
                            Text(path)
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            if let size = item.perPathSize[path], size > 0 {
                                Text(ByteFormat.string(size))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Button {
                                model.reveal(path)
                            } label: {
                                Image(systemName: "arrow.up.forward.app").font(.caption2)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(9)
                .background(Color(nsColor: .textBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 8))
    }
}

struct WarningPanel: View {
    let color: Color
    let icon: String
    let title: String
    let body_: String

    init(color: Color, icon: String, title: String, body: String) {
        self.color = color
        self.icon = icon
        self.title = title
        self.body_ = body
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout.bold())
                Text(body_).font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(12)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}
