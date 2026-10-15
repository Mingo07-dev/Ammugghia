import SwiftUI

/// Mappa del disco: ogni rettangolo è una cartella o un file grande, con area
/// proporzionale allo spazio occupato.
///
/// Solo visualizzazione. Dalla mappa non si elimina nulla: si elimina dagli
/// elementi delle categorie, che sanno spiegare che cosa succede dopo. Qui si
/// può aprire una cartella, mostrarla nel Finder o saltare alla voce di
/// pulizia che la riguarda.
struct DiskMapView: View {
    @EnvironmentObject var model: AppModel

    @State private var path: String?
    @State private var entries: [DiskIndexStore.Entry] = []
    @State private var current: DiskIndexStore.Entry?
    @State private var selected: DiskIndexStore.Entry?
    @State private var hovered: String?
    @State private var loaded = false

    /// Oltre questo numero i rettangoli diventano troppo piccoli per essere
    /// letti: il resto si raccoglie in una voce sola.
    private let maxRectangles = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if model.isIndexing && entries.isEmpty {
                progress
            } else if !loaded {
                Spacer()
            } else if entries.isEmpty {
                empty
            } else {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 8) {
                        breadcrumb
                        TreemapCanvas(entries: displayed, hovered: $hovered,
                                      onSelect: { selected = $0 },
                                      onOpen: open)
                        legend
                    }
                    .padding(14)
                    Divider()
                    DiskMapDetail(entry: selected ?? current, onOpen: open)
                        .frame(width: 270)
                }
            }
        }
        .task(id: "\(path ?? "")|\(model.indexGeneration)") { await load() }
        .task {
            // Aggiornare costa poco se esiste già un indice: lo si fa a ogni
            // apertura, così la mappa non mostra dati vecchi.
            if model.indexStatus == nil { model.refreshIndex() }
        }
    }

    // MARK: Parti

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Mappa del disco").font(.title2.bold())
                Text(model.isIndexing
                     ? model.indexProgress
                     : (model.indexStatus ?? String(localized: "Lettura dell'indice…")))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if model.isIndexing { ProgressView().controlSize(.small) }
            Menu {
                Button("Aggiorna") { model.refreshIndex() }
                Button("Rifai da zero") { model.refreshIndex(forceFull: true) }
            } label: {
                Label("Aggiorna", systemImage: "arrow.clockwise")
            } primaryAction: {
                model.refreshIndex()
            }
            .fixedSize()
            .disabled(model.isIndexing)
            .help("Aggiorna la mappa rileggendo solo le cartelle cambiate. «Rifai da zero» rilegge tutto.")
        }
        .padding(16)
    }

    private var progress: some View {
        VStack(spacing: 10) {
            Spacer()
            ProgressView()
            Text(model.indexProgress.isEmpty ? String(localized: "Lettura del disco…") : model.indexProgress)
                .font(.callout.monospacedDigit())
            Text("La prima lettura richiede qualche decina di secondi. Le successive rileggono solo le cartelle cambiate.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "square.grid.3x3.square").font(.largeTitle).foregroundStyle(.secondary)
            Text(path == nil ? String(localized: "La mappa non è ancora stata creata.") : String(localized: "Cartella vuota o non più presente."))
            if path == nil {
                Button("Crea la mappa") { model.refreshIndex() }
            } else {
                Button("Torna su") { goUp() }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var breadcrumb: some View {
        HStack(spacing: 4) {
            Button("Mac") { path = nil }
                .buttonStyle(.link)
            ForEach(crumbs, id: \.path) { crumb in
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                Button(crumb.name) { path = crumb.path }
                    .buttonStyle(.link)
                    .lineLimit(1)
            }
            Spacer()
            if path != nil {
                Button {
                    goUp()
                } label: {
                    Label("Su", systemImage: "arrow.up")
                }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .controlSize(.small)
            }
        }
        .font(.callout)
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Griglia adattiva: in una riga sola, con le etichette inglesi più
            // lunghe, le parole andavano a capo a metà («Develop-ment»).
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 12, alignment: .leading)],
                      alignment: .leading, spacing: 4) {
                ForEach(MapPalette.Kind.allCases, id: \.self) { kind in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(kind.color).frame(width: 10, height: 10)
                        Text(kind.label).font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1).fixedSize()
                    }
                }
            }
            Text("Doppio clic per entrare · i colori più chiari sono fermi da oltre un anno")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: Dati

    /// Le voci più grandi, più una voce che raccoglie il resto.
    private var displayed: [DiskIndexStore.Entry] {
        let visible = entries.filter { $0.size > 0 }
        guard visible.count > maxRectangles else { return visible }
        let head = Array(visible.prefix(maxRectangles))
        let tail = visible.dropFirst(maxRectangles)
        let rest = DiskIndexStore.Entry(
            path: (path ?? "") + "/…", name: Plural.of(tail.count, "altro elemento", "altri elementi"),
            size: tail.reduce(0) { $0 + $1.size }, files: tail.reduce(0) { $0 + $1.files },
            modified: 0, kind: .group, unreadable: false)
        return head + [rest]
    }

    private var crumbs: [(name: String, path: String)] {
        guard let path else { return [] }
        guard let root = DiskIndexStore.shared.roots.first(where: { path == $0 || path.hasPrefix($0 + "/") }) else {
            return [(path, path)]
        }
        var result = [(root == ScanSupport.home ? String(localized: "Cartella utente") : root, root)]
        var partial = root
        for component in path.dropFirst(root.count).split(separator: "/") {
            partial += "/" + component
            result.append((String(component), partial))
        }
        return result
    }

    private func load() async {
        let target = path
        let result = await Task.detached(priority: .userInitiated) { () -> ([DiskIndexStore.Entry]?, DiskIndexStore.Entry?) in
            let store = DiskIndexStore.shared
            return (store.level(at: target), target.flatMap(store.summary(at:)))
        }.value
        guard target == path else { return }
        entries = result.0 ?? []
        current = result.1
        selected = nil
        loaded = true
    }

    private func open(_ entry: DiskIndexStore.Entry) {
        guard entry.isNavigable else { return }
        path = entry.path
    }

    private func goUp() {
        guard let current = path else { return }
        if DiskIndexStore.shared.roots.contains(current) {
            path = nil
        } else {
            path = (current as NSString).deletingLastPathComponent
        }
    }
}

// MARK: - Disegno

struct TreemapCanvas: View {
    let entries: [DiskIndexStore.Entry]
    @Binding var hovered: String?
    let onSelect: (DiskIndexStore.Entry) -> Void
    let onOpen: (DiskIndexStore.Entry) -> Void

    var body: some View {
        GeometryReader { geometry in
            let rects = Treemap.squarify(entries.map { Double($0.size) },
                                         in: CGRect(origin: .zero, size: geometry.size))
            Canvas { context, _ in
                for (entry, rect) in zip(entries, rects) where rect.width >= 1 && rect.height >= 1 {
                    let inset = rect.insetBy(dx: 1, dy: 1)
                    let shape = Path(roundedRect: inset, cornerRadius: min(4, inset.width / 4, inset.height / 4))
                    var fill = MapPalette.color(for: entry)
                    if hovered == entry.id { fill = fill.opacity(1) }
                    context.fill(shape, with: .color(fill))
                    if hovered == entry.id {
                        context.stroke(shape, with: .color(.primary.opacity(0.6)), lineWidth: 2)
                    }
                    guard inset.width > 70, inset.height > 30 else { continue }
                    // Il ritaglio vale solo per questo rettangolo: fatto sul
                    // contesto principale si sommerebbe a quelli successivi.
                    context.drawLayer { layer in
                        layer.clip(to: Path(inset))
                        let title = layer.resolve(Text(entry.name).font(.caption.bold()).foregroundColor(.white))
                        let size = layer.resolve(Text(ByteFormat.string(entry.size)).font(.caption2)
                            .foregroundColor(.white.opacity(0.85)))
                        layer.draw(title, at: CGPoint(x: inset.minX + 6, y: inset.minY + 5), anchor: .topLeading)
                        layer.draw(size, at: CGPoint(x: inset.minX + 6, y: inset.minY + 20), anchor: .topLeading)
                    }
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    hovered = hit(point, rects)?.id
                case .ended:
                    hovered = nil
                }
            }
            .onTapGesture(count: 2) { point in
                if let entry = hit(point, rects) { onOpen(entry) }
            }
            .onTapGesture(count: 1) { point in
                if let entry = hit(point, rects) { onSelect(entry) }
            }
            .help(hovered.flatMap { id in entries.first { $0.id == id } }
                .map { "\($0.name) — \(ByteFormat.string($0.size))" } ?? "")
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func hit(_ point: CGPoint, _ rects: [CGRect]) -> DiskIndexStore.Entry? {
        for (entry, rect) in zip(entries, rects) where rect.contains(point) { return entry }
        return nil
    }
}

/// Disposizione «squarified» (Bruls, Huizing, van Wijk): rettangoli il più
/// possibile vicini al quadrato, più facili da confrontare a occhio.
enum Treemap {
    static func squarify(_ values: [Double], in bounds: CGRect) -> [CGRect] {
        let total = values.reduce(0, +)
        guard total > 0, bounds.width > 0, bounds.height > 0 else {
            return Array(repeating: .zero, count: values.count)
        }
        let scale = bounds.width * bounds.height / total
        let areas = values.map { max(0, $0 * scale) }
        var result: [CGRect] = []
        result.reserveCapacity(areas.count)
        var remaining = bounds
        var index = 0

        func worst(_ row: [Double], _ side: Double) -> Double {
            let sum = row.reduce(0, +)
            guard sum > 0, side > 0, let maxA = row.max(), let minA = row.min(), minA > 0 else { return .infinity }
            return max(side * side * maxA / (sum * sum), (sum * sum) / (side * side * minA))
        }

        while index < areas.count {
            let side = Double(min(remaining.width, remaining.height))
            var row = [areas[index]]
            var next = index + 1
            while next < areas.count, worst(row + [areas[next]], side) <= worst(row, side) {
                row.append(areas[next])
                next += 1
            }
            let sum = row.reduce(0, +)
            if remaining.width >= remaining.height {
                let width = remaining.height > 0 ? sum / Double(remaining.height) : 0
                var y = Double(remaining.minY)
                for area in row {
                    let height = width > 0 ? area / width : 0
                    result.append(CGRect(x: Double(remaining.minX), y: y, width: width, height: height))
                    y += height
                }
                remaining = CGRect(x: remaining.minX + width, y: remaining.minY,
                                   width: max(0, remaining.width - width), height: remaining.height)
            } else {
                let height = remaining.width > 0 ? sum / Double(remaining.width) : 0
                var x = Double(remaining.minX)
                for area in row {
                    let width = height > 0 ? area / height : 0
                    result.append(CGRect(x: x, y: Double(remaining.minY), width: width, height: height))
                    x += width
                }
                remaining = CGRect(x: remaining.minX, y: remaining.minY + height,
                                   width: remaining.width, height: max(0, remaining.height - height))
            }
            index = next
        }
        return result
    }
}

/// Colori per tipo di contenuto, schiariti per ciò che non cambia da più di
/// un anno: a colpo d'occhio si vede che cosa pesa e che cosa è fermo.
enum MapPalette {
    enum Kind: CaseIterable {
        case development, documents, media, apps, system, other

        var label: String {
            switch self {
            case .development: return String(localized: "Sviluppo")
            case .documents: return String(localized: "Documenti")
            case .media: return String(localized: "Foto, musica, video")
            case .apps: return String(localized: "Applicazioni")
            case .system: return String(localized: "Librerie e sistema")
            case .other: return String(localized: "Altro")
            }
        }

        var color: Color {
            switch self {
            case .development: return .orange
            case .documents: return .blue
            case .media: return .purple
            case .apps: return .green
            case .system: return .gray
            case .other: return .teal
            }
        }
    }

    static let developmentMarkers = [
        "/Library/Developer", "/node_modules", "/.gradle", "/DerivedData", "/.android",
        "/Library/Android", "/.npm", "/.cargo", "/.pub-cache", "/Pods", "/.build",
        "/.m2", "/.rustup", "/.cocoapods", "/opt/homebrew", "/Developer",
        "/flutter", "/fvm", "/.lmstudio", "/.ollama", "/.cache/huggingface",
    ]

    static func kind(for path: String) -> Kind {
        let home = ScanSupport.home
        if developmentMarkers.contains(where: { path.contains($0) }) { return .development }
        if ["/Movies", "/Music", "/Pictures"].contains(where: { path.hasPrefix(home + $0) }) { return .media }
        if ["/Documents", "/Desktop", "/Downloads"].contains(where: { path.hasPrefix(home + $0) }) { return .documents }
        if path.hasPrefix("/Applications") || path.hasPrefix(home + "/Applications") { return .apps }
        if path.contains("/Library") || path.hasPrefix("/System") { return .system }
        return .other
    }

    static func color(for entry: DiskIndexStore.Entry) -> Color {
        switch entry.kind {
        case .group, .otherFiles:
            return Color.gray.opacity(0.45)
        case .directory, .file:
            if entry.unreadable { return Color.gray.opacity(0.3) }
            let age = Date().timeIntervalSince1970 - Double(entry.modified)
            let stale = entry.modified > 0 && age > 365 * 86_400
            return kind(for: entry.path).color.opacity(stale ? 0.5 : 0.82)
        }
    }
}

// MARK: - Pannello

struct DiskMapDetail: View {
    let entry: DiskIndexStore.Entry?
    let onOpen: (DiskIndexStore.Entry) -> Void
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let entry {
                    Text(entry.name).font(.headline).lineLimit(3)
                    Text(entry.path)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text(ByteFormat.string(entry.size)).font(.title2.bold().monospacedDigit())
                    if entry.files > 0 {
                        Text(Plural.files(entry.files)).font(.callout).foregroundStyle(.secondary)
                    }
                    if entry.modified > 0 {
                        Text(DateFormat.relative(Date(timeIntervalSince1970: Double(entry.modified))))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if entry.unreadable {
                        Label("Non accessibile: macOS ne protegge il contenuto. Con «Accesso completo al disco» la mappa può misurarla.",
                              systemImage: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    HStack {
                        if entry.isNavigable {
                            Button("Apri") { onOpen(entry) }
                        }
                        if entry.kind == .directory || entry.kind == .file {
                            Button("Mostra nel Finder") { model.reveal(entry.path) }
                        }
                    }
                    let related = relatedCategories(for: entry.path)
                    if !related.isEmpty {
                        Divider()
                        Text("Voci di pulizia collegate").font(.caption.bold())
                        ForEach(related) { category in
                            Button {
                                model.selection = .category(category.id)
                            } label: {
                                Label("Vai a «\(category.name)»", systemImage: category.symbol)
                            }
                            .buttonStyle(.link)
                        }
                    }
                    Divider()
                    Text("La mappa serve a vedere dove sta lo spazio. Per eliminare usa le categorie: ogni voce spiega che cosa succede dopo.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Seleziona un rettangolo per vederne i dettagli.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Categorie con almeno un elemento dentro, sopra o uguale a questo percorso.
    private func relatedCategories(for path: String) -> [CleanupCategory] {
        model.categories.filter { category in
            category.items.contains { item in
                item.action.displayPaths.contains { p in
                    p == path || p.hasPrefix(path + "/") || path.hasPrefix(p + "/")
                }
            }
        }
    }
}
