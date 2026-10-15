import SwiftUI
import AppKit

/// Che cosa parte da solo sul Mac, a chi appartiene, e la possibilità di
/// fermarlo. Disattivare è reversibile: il file resta al suo posto e launchd
/// smette di avviarlo finché non viene riattivato.
struct StartupView: View {
    @EnvironmentObject var model: AppModel
    @State private var pending: (item: StartupItem, enable: Bool)?

    private let sections: [(StartupItem.Domain, String, String)] = [
        (.userAgent, String(localized: "Solo per il tuo utente"), "~/Library/LaunchAgents"),
        (.globalAgent, String(localized: "Per tutti gli utenti"), "/Library/LaunchAgents"),
        (.daemon, String(localized: "Servizi di sistema (richiedono la password)"), "/Library/LaunchDaemons"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Elementi d'avvio").font(.title2.bold())
                    Spacer()
                    if model.isLoadingStartup { ProgressView().controlSize(.small) }
                    Button {
                        model.loadStartupItems()
                    } label: {
                        Label("Aggiorna", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isLoadingStartup)
                }
                Text("Programmi che macOS avvia da solo: all'accesso, all'avvio del Mac o a intervalli. Disattivarne uno è reversibile: il file resta dov'è e launchd smette di avviarlo finché non lo riattivi. Per eliminarlo del tutto usa «Disinstalla app».")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 14) {
                    Text("\(model.appleServiceCount) servizi di macOS non sono elencati: non si modificano.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button("Elementi login nelle Impostazioni…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .controlSize(.small)
                    .help("Le app aggiunte agli elementi login e le attività in background approvate si gestiscono nelle Impostazioni di Sistema.")
                }
                if let message = model.startupMessage {
                    Text(message).font(.caption.bold()).foregroundStyle(.tint)
                }
            }
            .padding(16)
            Divider()
            List {
                ForEach(sections, id: \.0) { domain, title, folder in
                    let items = model.startupItems.filter { $0.domain == domain }
                    if !items.isEmpty {
                        Section {
                            ForEach(items) { item in
                                StartupRow(item: item) { enable in pending = (item, enable) }
                            }
                        } header: {
                            HStack {
                                Text(title)
                                Spacer()
                                Text(folder).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
        .task { if model.startupItems.isEmpty { model.loadStartupItems() } }
        .confirmationDialog(dialogTitle, isPresented: Binding(
            get: { pending != nil }, set: { if !$0 { pending = nil } }
        ), titleVisibility: .visible) {
            if let pending {
                Button(pending.enable ? String(localized: "Riattiva") : String(localized: "Disattiva"), role: pending.enable ? nil : .destructive) {
                    model.setStartup(pending.item, enabled: pending.enable)
                }
                Button("Annulla", role: .cancel) {}
            }
        } message: {
            Text(dialogMessage)
        }
    }

    private var dialogTitle: String {
        guard let pending else { return "" }
        return pending.enable
            ? String(localized: "Riattivare «\(pending.item.displayName)»?")
            : String(localized: "Disattivare «\(pending.item.displayName)»?")
    }

    private var dialogMessage: String {
        guard let pending else { return "" }
        let item = pending.item
        let commands = StartupController.commands(for: item, enable: pending.enable)
            .map { (["launchctl"] + $0).joined(separator: " ") }
            .joined(separator: "\n")
        let effect = pending.enable
            ? String(localized: "Il servizio torna ad avviarsi come prima e viene caricato subito.")
            : String(localized: "Il servizio viene fermato e non si avvierà più finché non lo riattivi. ")
              + String(localized: "\(item.ownerName.map { String(localized: "«\($0)»") } ?? String(localized: "L'app che lo usa")) potrebbe smettere di aggiornarsi, sincronizzare o funzionare del tutto.")
        let admin = item.domain.needsAdmin ? String(localized: "\n\nServe la password di amministratore.") : ""
        return effect + String(localized: "\n\nComandi eseguiti:\n") + commands + admin
    }
}

struct StartupRow: View {
    let item: StartupItem
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.isOrphan ? "exclamationmark.triangle.fill" : "gearshape.2")
                .foregroundStyle(item.isOrphan ? .orange : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.displayName).font(.callout.weight(.medium))
                    ForEach(badges, id: \.self) { badge in
                        Text(badge)
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color(nsColor: .quaternaryLabelColor), in: Capsule())
                    }
                }
                Text(item.label)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if let program = item.program {
                    Text(program)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(item.isOrphan ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                        .lineLimit(1).truncationMode(.middle)
                        .help(program)
                }
                if item.isOrphan {
                    Text("Il programma che dovrebbe avviare non esiste più: è il resto di un'app rimossa. Disattivarlo è sicuro.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Firma: \(item.signer ?? String(localized: "non determinabile"))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { !item.isDisabled }, set: { onToggle($0) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(item.isApple)
                .help(item.isApple ? String(localized: "Servizio di macOS: non modificabile.") : (item.isDisabled ? String(localized: "Riattiva") : String(localized: "Disattiva")))
        }
        .padding(.vertical, 3)
    }

    private var badges: [String] {
        var result: [String] = []
        if item.isDisabled { result.append(String(localized: "disattivato")) }
        if item.isLoaded { result.append(String(localized: "in esecuzione")) }
        if item.runAtLoad { result.append(String(localized: "all'avvio")) }
        if item.keepAlive { result.append(String(localized: "sempre attivo")) }
        if let interval = item.interval { result.append(String(localized: "ogni \(max(1, interval / 60)) min")) }
        return result
    }
}
